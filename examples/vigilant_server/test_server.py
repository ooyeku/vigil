#!/usr/bin/env python3

import argparse
import json
import random
import socket
import statistics
import sys
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence


DEFAULT_ITERATIONS = 10000
DEFAULT_POOL_SIZE = 50
SERVER_HOST = "127.0.0.1"
SERVER_PORT = 9090


class ServerUnavailable(RuntimeError):
    pass


def wait_for_server(host: str, port: int, timeout: float = 2.0, interval: float = 0.1) -> None:
    deadline = time.monotonic() + timeout
    last_error: Optional[OSError] = None

    while time.monotonic() <= deadline:
        try:
            with socket.create_connection((host, port), timeout=interval):
                return
        except OSError as err:
            last_error = err
            time.sleep(interval)

    detail = f": {last_error}" if last_error else ""
    raise ServerUnavailable(f"Could not connect to {host}:{port}{detail}")


@dataclass
class TestStats:
    min_time: float
    max_time: float
    avg_time: float
    count: int
    std_dev: float


@dataclass
class ServerMetrics:
    active_connections: int
    total_connections: int
    requests_handled: int
    uptime_seconds: int

    @classmethod
    def from_response(cls, response: str) -> "ServerMetrics":
        metrics: Dict[str, int] = {}
        for line in response.strip().splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            metrics[key] = int(value)

        missing = {
            "active_connections",
            "total_connections",
            "requests_handled",
            "uptime_seconds",
        } - set(metrics)
        if missing:
            raise ValueError(f"Metrics response missing fields: {sorted(missing)}")

        return cls(
            active_connections=metrics["active_connections"],
            total_connections=metrics["total_connections"],
            requests_handled=metrics["requests_handled"],
            uptime_seconds=metrics["uptime_seconds"],
        )


class ServerTester:
    def __init__(
        self,
        host: str = SERVER_HOST,
        port: int = SERVER_PORT,
        pool_size: int = DEFAULT_POOL_SIZE,
    ):
        self.host = host
        self.port = port
        self.pool_size = pool_size
        self.results: Dict[str, List[float]] = {}
        self.connection_pool: List[socket.socket] = []
        self._initialize_pool()

    def _initialize_pool(self) -> None:
        while len(self.connection_pool) < self.pool_size:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1.0)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.connect((self.host, self.port))
                self.connection_pool.append(sock)
            except (socket.timeout, ConnectionResetError, OSError) as err:
                print(f"Failed to initialize connection: {err}")
                sock.close()
                break

    def _get_connection(self) -> Optional[socket.socket]:
        if not self.connection_pool:
            self._initialize_pool()
        return self.connection_pool.pop() if self.connection_pool else None

    def _return_connection(self, sock: Optional[socket.socket]) -> None:
        if sock and len(self.connection_pool) < self.pool_size:
            self.connection_pool.append(sock)
            return

        if sock:
            sock.close()

    def send_request(self, message: str) -> Optional[float]:
        sock = self._get_connection()
        if sock is None:
            return None

        start = time.perf_counter()
        try:
            sock.sendall((message + "\n").encode())
            _ = sock.recv(1024)
            self._return_connection(sock)
        except (socket.timeout, ConnectionResetError, OSError) as err:
            print(f"Connection error: {err}")
            sock.close()
            time.sleep(0.1)
            return None

        return (time.perf_counter() - start) * 1000

    def collect_metrics(self) -> ServerMetrics:
        sock = self._get_connection()
        if sock is None:
            raise ConnectionError("Could not get connection for metrics collection")

        try:
            sock.sendall(b"METRICS\n")
            response = sock.recv(1024).decode()
            self._return_connection(sock)
            return ServerMetrics.from_response(response)
        except (socket.timeout, ConnectionResetError, OSError) as err:
            sock.close()
            raise ConnectionError(f"Failed to collect metrics: {err}") from err

    def run_test(self, category: str, message: str, iterations: int) -> None:
        self.results.setdefault(category, [])
        print(f"Running {category} test ({iterations} iterations)...")

        progress_interval = max(1, iterations // 10)
        successful = 0
        for i in range(iterations):
            if i % progress_interval == 0:
                print(f"  Progress: {i}/{iterations} ({successful} successful)")

            duration = self.send_request(message)
            if duration is None:
                continue

            self.results[category].append(duration)
            successful += 1

    def get_stats(self, category: str) -> TestStats:
        times = self.results[category]
        return TestStats(
            min_time=min(times),
            max_time=max(times),
            avg_time=statistics.mean(times),
            count=len(times),
            std_dev=statistics.stdev(times) if len(times) > 1 else 0.0,
        )

    def run_all_tests(self, iterations: int = DEFAULT_ITERATIONS) -> None:
        print("\n=== Starting Vigilant Server Tests ===\n")

        try:
            initial_metrics = self.collect_metrics()
            print("Initial Server Metrics:")
            print(f"  Active Connections: {initial_metrics.active_connections}")
            print(f"  Total Connections: {initial_metrics.total_connections}")
            print(f"  Requests Handled: {initial_metrics.requests_handled}\n")
        except ConnectionError as err:
            print(f"Failed to collect initial metrics: {err}\n")

        for command in ["HEALTH", "STATUS", "METRICS"]:
            self.run_test(command, command, iterations)

        self.run_test("VARIABLE_LENGTH", "x" * 1000, iterations)
        self.run_test("JSON", json.dumps({"test": "payload", "number": 123}), iterations)

        words = ["hello", "world", "test", "server", "network"]
        self.results.setdefault("RANDOM_WORDS", [])
        print(f"Running RANDOM_WORDS test ({iterations} iterations)...")
        for i in range(iterations):
            message = " ".join(random.choices(words, k=3))
            duration = self.send_request(message)
            if duration is not None:
                self.results["RANDOM_WORDS"].append(duration)

        try:
            final_metrics = self.collect_metrics()
            print("\nFinal Server Metrics:")
            print(f"  Active Connections: {final_metrics.active_connections}")
            print(f"  Total Connections: {final_metrics.total_connections}")
            print(f"  Requests Handled: {final_metrics.requests_handled}")
            print(f"  Uptime Seconds: {final_metrics.uptime_seconds}\n")
        except ConnectionError as err:
            print(f"Failed to collect final metrics: {err}\n")

    def print_results(self) -> None:
        print("\n=== TEST RESULTS ===")
        for category, samples in self.results.items():
            if not samples:
                print(f"\n{category}: no successful samples")
                continue

            stats = self.get_stats(category)
            print(f"\n{category}:")
            print(f"  Min: {stats.min_time:.2f}ms")
            print(f"  Max: {stats.max_time:.2f}ms")
            print(f"  Avg: {stats.avg_time:.2f}ms")
            print(f"  Std Dev: {stats.std_dev:.2f}ms")
            print(f"  Count: {stats.count}")

    def close(self) -> None:
        for sock in self.connection_pool:
            sock.close()
        self.connection_pool.clear()


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load test the Vigilant Server example.")
    parser.add_argument("--host", default=SERVER_HOST)
    parser.add_argument("--port", type=int, default=SERVER_PORT)
    parser.add_argument("--iterations", type=int, default=DEFAULT_ITERATIONS)
    parser.add_argument("--pool-size", type=int, default=DEFAULT_POOL_SIZE)
    parser.add_argument("--wait-timeout", type=float, default=2.0)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    try:
        wait_for_server(args.host, args.port, args.wait_timeout)
    except ServerUnavailable as err:
        print(err, file=sys.stderr)
        print("Start the example server in another terminal first:", file=sys.stderr)
        print("  zig build run", file=sys.stderr)
        return 2

    tester = ServerTester(args.host, args.port, args.pool_size)
    try:
        tester.run_all_tests(args.iterations)
        tester.print_results()
    finally:
        tester.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
