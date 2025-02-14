#!/usr/bin/env python3

import socket
import time
import statistics
import json
from dataclasses import dataclass, asdict
from typing import Dict, List
import random
import resource

# Increase system limits
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))

TEST_ITERATIONS = 100000


@dataclass
class TestStats:
    min_time: float
    max_time: float
    avg_time: float
    count: int
    std_dev: float

@dataclass
class ServerMetrics:
    uptime_seconds: int
    total_connections: int
    active_connections: int
    peak_connections: int
    bytes_received: int
    bytes_sent: int

    @classmethod
    def from_response(cls, response: str) -> 'ServerMetrics':
        lines = response.strip().split('\n')
        if lines[0] != "OK":
            raise ValueError("Invalid metrics response")
            
        metrics = {}
        for line in lines[1:]:
            key, value = line.split('=')
            metrics[key] = int(value)
            
        return cls(
            uptime_seconds=metrics['uptime_seconds'],
            total_connections=metrics['total_connections'],
            active_connections=metrics['active_connections'],
            peak_connections=metrics['peak_connections'],
            bytes_received=metrics['bytes_received'],
            bytes_sent=metrics['bytes_sent']
        )

class ServerTester:
    def __init__(self, host: str = '127.0.0.1', port: int = 8080, pool_size: int = 1000):
        self.host = host
        self.port = port
        self.results: Dict[str, List[float]] = {}
        self.connection_pool: List[socket.socket] = []
        self.pool_size = pool_size
        self._initialize_pool()
        
    def _initialize_pool(self):
        """Initialize the connection pool"""
        for _ in range(self.pool_size):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1.0)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.connect((self.host, self.port))
                self.connection_pool.append(sock)
            except (socket.timeout, ConnectionResetError, OSError) as e:
                print(f"Failed to initialize connection: {e}")

    def _get_connection(self) -> socket.socket:
        """Get an available connection from the pool"""
        if not self.connection_pool:
            self._initialize_pool()
        return self.connection_pool.pop() if self.connection_pool else None

    def _return_connection(self, sock: socket.socket):
        """Return a connection to the pool"""
        if sock and len(self.connection_pool) < self.pool_size:
            self.connection_pool.append(sock)
        else:
            try:
                sock.close()
            except:
                pass

    def send_request(self, message: str) -> float:
        start = time.perf_counter()
        sock = self._get_connection()
        
        if not sock:
            return float('inf')
            
        try:
            sock.sendall((message + '\n').encode())
            response = sock.recv(1024)
            self._return_connection(sock)
        except (socket.timeout, ConnectionResetError, OSError) as e:
            print(f"Connection error: {e}")
            try:
                sock.close()
            except:
                pass
            time.sleep(0.1)  # Add small delay before retry
            return float('inf')
            
        end = time.perf_counter()
        return (end - start) * 1000

    def __del__(self):
        # Close all connections when tester is destroyed
        for sock in self.connection_pool:
            try:
                sock.close()
            except:
                pass
        self.connection_pool.clear()

    def run_test(self, category: str, message: str, iterations: int = TEST_ITERATIONS):
        if category not in self.results:
            self.results[category] = []
        print(f"Running {category} test ({iterations} iterations)...")
        
        successful = 0
        progress_interval = max(1, iterations // 10)  # Ensure we don't divide by zero
        
        for i in range(iterations):
            if i % progress_interval == 0:
                print(f"  Progress: {i}/{iterations} (Success rate: {successful}/{i if i > 0 else 1})")
            
            duration = self.send_request(message)
            if duration != float('inf'):
                self.results[category].append(duration)
                successful += 1
            else:
                time.sleep(0.01)  # Back off on failure

    def get_stats(self, category: str) -> TestStats:
        times = self.results[category]
        return TestStats(
            min_time=min(times),
            max_time=max(times),
            avg_time=statistics.mean(times),
            count=len(times),
            std_dev=statistics.stdev(times) if len(times) > 1 else 0
        )

    def collect_metrics(self) -> ServerMetrics:
        sock = self._get_connection()
        if not sock:
            raise ConnectionError("Could not get connection for metrics collection")
            
        try:
            sock.sendall(b"HEALTHCHECK\n")
            response = sock.recv(1024).decode()
            self._return_connection(sock)
            return ServerMetrics.from_response(response)
        except (socket.timeout, ConnectionResetError, OSError) as e:
            try:
                sock.close()
            except:
                pass
            raise ConnectionError(f"Failed to collect metrics: {e}")

    def run_all_tests(self, iterations: int = TEST_ITERATIONS):
        print("\n=== Starting Server Tests ===\n")
        
        # Initial metrics
        try:
            initial_metrics = self.collect_metrics()
            print("\nInitial Server Metrics:")
            print(f"Active Connections: {initial_metrics.active_connections}")
            print(f"Total Connections: {initial_metrics.total_connections}")
            print(f"Peak Connections: {initial_metrics.peak_connections}\n")
        except ConnectionError as e:
            print(f"Failed to collect initial metrics: {e}\n")

        # Standard commands test
        for cmd in ["HEALTHCHECK", "STATUS"]:
            self.run_test(cmd, cmd, iterations)
            
            # Collect metrics after each major test
            try:
                metrics = self.collect_metrics()
                print(f"\nMetrics after {cmd} test:")
                print(f"Active Connections: {metrics.active_connections}")
                print(f"Total Connections: {metrics.total_connections}")
                print(f"Bytes Received: {metrics.bytes_received}")
                print(f"Bytes Sent: {metrics.bytes_sent}\n")
            except ConnectionError as e:
                print(f"Failed to collect metrics after {cmd}: {e}\n")

        # Variable length test
        self.run_test("VARIABLE_LENGTH", "x" * 1000, iterations)
        
        # JSON test
        json_msg = json.dumps({"test": "payload", "number": 123})
        self.run_test("JSON", json_msg, iterations)

        # Random words test
        words = ["hello", "world", "test", "server", "network"]
        random_messages = [" ".join(random.choices(words, k=3)) for _ in range(iterations)]
        
        if "RANDOM_WORDS" not in self.results:
            self.results["RANDOM_WORDS"] = []
        print(f"Running RANDOM_WORDS test ({iterations} iterations)...")
        
        successful = 0
        progress_interval = max(1, iterations // 10)
        
        for i in range(iterations):
            if i % progress_interval == 0:
                print(f"  Progress: {i}/{iterations} (Success rate: {successful}/{i if i > 0 else 1})")
                # Collect metrics every 10% of the test
                try:
                    metrics = self.collect_metrics()
                    print(f"\n  Current Metrics:")
                    print(f"  Active Connections: {metrics.active_connections}")
                    print(f"  Total Connections: {metrics.total_connections}")
                    print(f"  Peak Connections: {metrics.peak_connections}\n")
                except ConnectionError as e:
                    print(f"  Failed to collect metrics: {e}\n")
            
            duration = self.send_request(random_messages[i])
            if duration != float('inf'):
                self.results["RANDOM_WORDS"].append(duration)
                successful += 1
            else:
                time.sleep(0.01)  # Back off on failure

        # Final metrics
        try:
            final_metrics = self.collect_metrics()
            print("\nFinal Server Metrics:")
            print(f"Total Connections: {final_metrics.total_connections}")
            print(f"Peak Connections: {final_metrics.peak_connections}")
            print(f"Total Bytes Received: {final_metrics.bytes_received}")
            print(f"Total Bytes Sent: {final_metrics.bytes_sent}\n")
        except ConnectionError as e:
            print(f"Failed to collect final metrics: {e}\n")

    def print_results(self):
        print("\n=== TEST RESULTS ===")
        for category in self.results:
            stats = self.get_stats(category)
            print(f"\n{category}:")
            print(f"  Min: {stats.min_time:.2f}ms")
            print(f"  Max: {stats.max_time:.2f}ms")
            print(f"  Avg: {stats.avg_time:.2f}ms")
            print(f"  Std Dev: {stats.std_dev:.2f}ms")
            print(f"  Count: {stats.count}")

if __name__ == "__main__":
    tester = ServerTester()
    tester.run_all_tests()
    tester.print_results()