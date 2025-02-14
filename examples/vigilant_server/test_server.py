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

class ServerTester:
    def __init__(self, host: str = '127.0.0.1', port: int = 8080, pool_size: int = 100):
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
        """Cleanup connections when the tester is destroyed"""
        for sock in self.connection_pool:
            try:
                sock.close()
            except:
                pass

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

    def run_all_tests(self, iterations: int = TEST_ITERATIONS):
        # Standard commands test
        for cmd in ["HEALTHCHECK", "STATUS"]:
            self.run_test(cmd, cmd, iterations)

        # Variable length test
        self.run_test("VARIABLE_LENGTH", "x" * 1000, iterations)
        
        # JSON test
        json_msg = json.dumps({"test": "payload", "number": 123})
        self.run_test("JSON", json_msg, iterations)

        # Random words test with different message for each iteration
        words = ["hello", "world", "test", "server", "network"]
        random_messages = [" ".join(random.choices(words, k=3)) for _ in range(iterations)]
        
        # Create a custom test run for random words to use different message each time
        if "RANDOM_WORDS" not in self.results:
            self.results["RANDOM_WORDS"] = []
        print(f"Running RANDOM_WORDS test ({iterations} iterations)...")
        
        successful = 0
        progress_interval = max(1, iterations // 10)
        
        for i in range(iterations):
            if i % progress_interval == 0:
                print(f"  Progress: {i}/{iterations} (Success rate: {successful}/{i if i > 0 else 1})")
            
            duration = self.send_request(random_messages[i])
            if duration != float('inf'):
                self.results["RANDOM_WORDS"].append(duration)
                successful += 1
            else:
                time.sleep(0.01)  # Back off on failure

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