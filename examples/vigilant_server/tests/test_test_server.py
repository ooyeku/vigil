import socket
import unittest

import test_server


def unused_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class ServerAvailabilityTests(unittest.TestCase):
    def test_wait_for_server_reports_unavailable_endpoint(self) -> None:
        self.assertTrue(hasattr(test_server, "ServerUnavailable"))
        port = unused_local_port()

        with self.assertRaises(test_server.ServerUnavailable) as ctx:
            test_server.wait_for_server("127.0.0.1", port, timeout=0.01, interval=0.001)

        self.assertIn(f"127.0.0.1:{port}", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
