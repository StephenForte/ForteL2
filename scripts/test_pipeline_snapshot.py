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


class RequireHttpRpcUrlTests(unittest.TestCase):
    def test_allows_http_and_https(self) -> None:
        for url in (
            "http://127.0.0.1:8545",
            "https://rpc.example/path",
            "HTTP://localhost:9545",
        ):
            with self.subTest(url=url):
                self.assertEqual(pipeline_snapshot.require_http_rpc_url(url), url)

    def test_rejects_file_and_other_schemes(self) -> None:
        for url in (
            "file:///etc/passwd",
            "ftp://example.com/x",
            "gopher://example.com",
            "data:text/plain,hi",
            "javascript:alert(1)",
            "/etc/passwd",
            "",
        ):
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    pipeline_snapshot.require_http_rpc_url(url)

    def test_rpc_rejects_file_url_before_urlopen(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            pipeline_snapshot.rpc("file:///etc/passwd", "eth_blockNumber")
        self.assertIn("http(s)", str(ctx.exception))


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


# Frozen pipeline-health.json batcher keys (D-0141): types must not change.
_BATCHER_FROZEN_KEYS = {
    "scan_from": int,
    "scan_to": int,
    "post_count": int,
    "last_hash": (str, type(None)),
    "last_age_sec": (int, type(None)),
    "cadence_sec": (int, type(None)),
    "batcher": str,
    "inbox": str,
}


class BatcherSnapshotTests(unittest.TestCase):
    def test_l1_scan_blocks_is_sixty(self) -> None:
        self.assertEqual(pipeline_snapshot.L1_SCAN_BLOCKS, 60)
        start = pipeline_snapshot.scan_from(tip=100, window=pipeline_snapshot.L1_SCAN_BLOCKS)
        self.assertEqual(start, 41)
        self.assertEqual(len(list(range(start, 100 + 1))), 60)

    def test_one_post_in_sixty_block_window_is_healthy(self) -> None:
        tip = 100
        start = pipeline_snapshot.scan_from(tip, 60)
        posts = [
            {
                "hash": "0xabc123",
                "block_number": 70,
                "block_timestamp": 1_000_000,
                "age_sec": 360,
            }
        ]
        panel = pipeline_snapshot.summarize_batcher(
            start, tip, posts, "0x" + "11" * 20, "0x" + "22" * 20
        )
        self.assertEqual(panel["verdict"], "healthy")
        self.assertEqual(panel["last_hash"], "0xabc123")
        self.assertEqual(panel["post_count"], 1)
        self.assertIsInstance(panel["last_hash"], str)
        self.assertIsInstance(panel["last_age_sec"], int)

    def test_zero_posts_in_sixty_block_window_is_not_healthy(self) -> None:
        tip = 100
        start = pipeline_snapshot.scan_from(tip, 60)
        panel = pipeline_snapshot.summarize_batcher(
            start, tip, [], "0x" + "11" * 20, "0x" + "22" * 20
        )
        self.assertEqual(panel["verdict"], "no-posts")
        self.assertEqual(panel["post_count"], 0)
        self.assertIsNone(panel["last_hash"])
        self.assertIsNone(panel["last_age_sec"])
        self.assertIsNone(panel["cadence_sec"])

    def test_existing_batcher_keys_keep_names_and_types(self) -> None:
        tip = 100
        start = pipeline_snapshot.scan_from(tip, 60)
        with_post = pipeline_snapshot.summarize_batcher(
            start,
            tip,
            [
                {
                    "hash": "0xdead",
                    "block_number": 90,
                    "block_timestamp": 50,
                    "age_sec": 10,
                },
                {
                    "hash": "0xbeef",
                    "block_number": 60,
                    "block_timestamp": 10,
                    "age_sec": 50,
                },
            ],
            "0x" + "aa" * 20,
            "0x" + "bb" * 20,
        )
        empty = pipeline_snapshot.summarize_batcher(
            start, tip, [], "0x" + "aa" * 20, "0x" + "bb" * 20
        )
        for panel in (with_post, empty):
            for key, typ in _BATCHER_FROZEN_KEYS.items():
                self.assertIn(key, panel)
                self.assertIsInstance(panel[key], typ)
        self.assertIsInstance(with_post["verdict"], str)
        self.assertIsInstance(empty["verdict"], str)
        self.assertEqual(with_post["cadence_sec"], 40)


if __name__ == "__main__":
    unittest.main()
