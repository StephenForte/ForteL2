"""Unit tests for the pure helpers in pipeline-snapshot.py."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("pipeline-snapshot.py")
SPEC = importlib.util.spec_from_file_location("pipeline_snapshot", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
pipeline_snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pipeline_snapshot)


class RedactRpcUrlTests(unittest.TestCase):
    def test_root_url_keeps_only_origin(self) -> None:
        self.assertEqual(
            pipeline_snapshot.redact_rpc_url("http://127.0.0.1:8545/"),
            "http://127.0.0.1:8545",
        )

    def test_short_and_long_paths_are_redacted(self) -> None:
        for path in ("secret", "a-very-long-provider-api-key"):
            with self.subTest(path=path):
                self.assertEqual(
                    pipeline_snapshot.redact_rpc_url(f"https://rpc.example/{path}"),
                    "https://rpc.example/…",
                )

    def test_userinfo_query_and_fragment_are_removed(self) -> None:
        redacted = pipeline_snapshot.redact_rpc_url(
            "https://user:password@rpc.example/key?api_key=query-secret#fragment-secret"
        )
        self.assertEqual(redacted, "https://rpc.example/…")
        for secret in ("user", "password", "key", "query-secret", "fragment-secret"):
            self.assertNotIn(secret, redacted)


class QuantityTests(unittest.TestCase):
    def test_hexadecimal_quantity(self) -> None:
        self.assertEqual(pipeline_snapshot.hex_to_int("0x2a"), 42)

    def test_invalid_quantities(self) -> None:
        for value in (None, "", "not-a-quantity", "0xzz"):
            with self.subTest(value=value):
                self.assertIsNone(pipeline_snapshot.hex_to_int(value))


class ScanWindowTests(unittest.TestCase):
    def test_window_boundaries_are_inclusive(self) -> None:
        start = pipeline_snapshot.scan_from(tip=10, window=3)
        self.assertEqual(start, 8)
        self.assertEqual(list(range(start, 10 + 1)), [8, 9, 10])

    def test_scan_does_not_start_below_genesis(self) -> None:
        self.assertEqual(pipeline_snapshot.scan_from(tip=2, window=8), 0)


class DeploymentPathTests(unittest.TestCase):
    def test_local_deployment_path(self) -> None:
        root = Path("/repo")
        self.assertEqual(
            pipeline_snapshot.deployments_json_path(root, "901"),
            root / "deployments" / "deployments.json",
        )

    def test_sepolia_deployment_path(self) -> None:
        root = Path("/repo")
        self.assertEqual(
            pipeline_snapshot.deployments_json_path(root, "852"),
            root / "deployments" / "sepolia" / "deployments.json",
        )


if __name__ == "__main__":
    unittest.main()
