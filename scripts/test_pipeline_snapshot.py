"""Unit tests for the pure helpers in pipeline-snapshot.py."""

from __future__ import annotations

import importlib.util
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


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


def _pt(year, month, day, hour, minute, second=0) -> float:
    return datetime(
        year, month, day, hour, minute, second, tzinfo=ZoneInfo("America/Los_Angeles")
    ).timestamp()


class ParseDurationSecondsTests(unittest.TestCase):
    def test_hours_minutes_seconds(self) -> None:
        self.assertEqual(pipeline_snapshot.parse_duration_seconds("8h"), 8 * 3600)
        self.assertEqual(pipeline_snapshot.parse_duration_seconds("30m"), 30 * 60)
        self.assertEqual(pipeline_snapshot.parse_duration_seconds("12s"), 12)

    def test_unparseable_forms_return_none(self) -> None:
        # An unparseable interval must yield the "cannot tell" verdict, never
        # a default that silently disagrees with the configured value (D-0142).
        for raw in (None, "", "8", "8x", "-1h", "8 h", "8H", "abc", "1h2m"):
            with self.subTest(raw=raw):
                self.assertIsNone(pipeline_snapshot.parse_duration_seconds(raw))


class DevSleepWindowTests(unittest.TestCase):
    def test_inside_window_after_2345(self) -> None:
        self.assertTrue(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 23, 50)))

    def test_inside_window_before_0300(self) -> None:
        self.assertTrue(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 1, 30)))

    def test_outside_window_at_boundaries(self) -> None:
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 3, 0)))
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 23, 44)))

    def test_midday_is_awake(self) -> None:
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 12, 0)))


class AwakeSecondsBetweenTests(unittest.TestCase):
    def test_zero_or_negative_range(self) -> None:
        self.assertEqual(pipeline_snapshot.awake_seconds_between(100.0, 100.0), 0.0)
        self.assertEqual(pipeline_snapshot.awake_seconds_between(200.0, 100.0), 0.0)

    def test_daytime_only_range_is_unaffected(self) -> None:
        lo = _pt(2026, 9, 18, 9, 0)
        hi = _pt(2026, 9, 18, 17, 0)
        self.assertEqual(pipeline_snapshot.awake_seconds_between(lo, hi), hi - lo)

    def test_range_wholly_inside_one_window(self) -> None:
        lo = _pt(2026, 9, 19, 0, 30)
        hi = _pt(2026, 9, 19, 1, 30)
        self.assertEqual(pipeline_snapshot.awake_seconds_between(lo, hi), 0.0)

    def test_range_spanning_one_full_window(self) -> None:
        # 22:00 the night before through 05:00 next day: raw span 7h, minus
        # the 3h15m window = 3h45m awake (the §7 property: single-window
        # spans are judged on awake time, not raw age).
        lo = _pt(2026, 9, 18, 22, 0)
        hi = _pt(2026, 9, 19, 5, 0)
        awake = pipeline_snapshot.awake_seconds_between(lo, hi)
        self.assertAlmostEqual(awake, (hi - lo) - (3 * 3600 + 15 * 60), delta=1.0)

    def test_range_spanning_two_full_windows(self) -> None:
        # §7 trap: a dead proposer over ~54h spans two nightly windows; both
        # must be removed, not one.
        lo = _pt(2026, 9, 17, 12, 0)
        hi = _pt(2026, 9, 19, 18, 0)
        awake = pipeline_snapshot.awake_seconds_between(lo, hi)
        self.assertAlmostEqual(
            awake, (hi - lo) - 2 * (3 * 3600 + 15 * 60), delta=1.0
        )


class ProposerVerdictTests(unittest.TestCase):
    HEALTHY = pipeline_snapshot.PROPOSER_VERDICT_HEALTHY
    OVERDUE = pipeline_snapshot.PROPOSER_VERDICT_OVERDUE
    UNKNOWN = pipeline_snapshot.PROPOSER_VERDICT_UNKNOWN

    def test_unknown_when_game_count_zero(self) -> None:
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(0, None, 8 * 3600, now=1000.0),
            self.UNKNOWN,
        )

    def test_unknown_when_latest_missing(self) -> None:
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(3, None, 8 * 3600, now=1000.0),
            self.UNKNOWN,
        )

    def test_unknown_when_interval_unparseable(self) -> None:
        latest = {"timestamp": 500.0}
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(3, latest, None, now=1000.0),
            self.UNKNOWN,
        )

    def test_measured_8h02m_cadence_is_not_overdue(self) -> None:
        # §9: the measured real cadence (8h 02m) must not be overdue against
        # an 8h configured interval (threshold 10h), with no sleep window in
        # play (noon PT origin).
        now = _pt(2026, 9, 18, 12, 0)
        ts = now - (8 * 3600 + 2 * 60)
        latest = {"timestamp": ts}
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, latest, 8 * 3600, now=now),
            self.HEALTHY,
        )

    def test_exact_threshold_is_healthy_one_second_past_is_overdue(self) -> None:
        # Daytime range (no sleep window) so raw age == awake age exactly.
        now = _pt(2026, 9, 18, 20, 0)
        interval = 8 * 3600
        threshold = interval + pipeline_snapshot.PROPOSER_OVERDUE_GRACE_SECS
        at_threshold = {"timestamp": now - threshold}
        past_threshold = {"timestamp": now - threshold - 1}
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, at_threshold, interval, now=now),
            self.HEALTHY,
        )
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, past_threshold, interval, now=now),
            self.OVERDUE,
        )

    def test_one_sleep_window_under_threshold_on_awake_time_is_not_overdue(self) -> None:
        # Raw age exceeds the 10h threshold, but awake age (minus one window)
        # does not — the case a naive `age >` check gets wrong.
        interval = 8 * 3600
        threshold = interval + pipeline_snapshot.PROPOSER_OVERDUE_GRACE_SECS
        now = _pt(2026, 9, 19, 5, 0)
        ts = now - (threshold - 3600)  # awake age = threshold - 1h (under)
        ts -= 3 * 3600 + 15 * 60  # raw age grows by exactly one window's width
        latest = {"timestamp": ts}
        raw_age = now - ts
        self.assertGreater(raw_age, threshold)  # a naive check would fire
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, latest, interval, now=now),
            self.HEALTHY,
        )

    def test_two_sleep_windows_judged_on_awake_time_not_one_windows_worth(self) -> None:
        # §7 trap: subtracting only one window's width for a two-window gap
        # would read this as healthy. The correct awake-time calc must not.
        interval = 8 * 3600
        threshold = interval + pipeline_snapshot.PROPOSER_OVERDUE_GRACE_SECS
        now = _pt(2026, 9, 19, 18, 0)
        lo = _pt(2026, 9, 17, 12, 0)
        awake = pipeline_snapshot.awake_seconds_between(lo, now)
        self.assertGreater(awake, threshold)
        latest = {"timestamp": lo}
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, latest, interval, now=now),
            self.OVERDUE,
        )

    def test_well_past_threshold_on_awake_time_is_overdue(self) -> None:
        now = _pt(2026, 9, 18, 20, 0)
        interval = 8 * 3600
        latest = {"timestamp": now - 100 * 3600}
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, latest, interval, now=now),
            self.OVERDUE,
        )

    def test_verdict_judged_against_configured_interval(self) -> None:
        # Same age, different configured interval, different verdict.
        now = _pt(2026, 9, 18, 20, 0)
        age = 5 * 3600
        latest = {"timestamp": now - age}
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, latest, 8 * 3600, now=now),
            self.HEALTHY,
        )
        self.assertEqual(
            pipeline_snapshot.proposer_verdict(1, latest, 1 * 3600, now=now),
            self.OVERDUE,
        )


# Frozen pipeline-health.json proposer keys (D-0142): types must not change.
_PROPOSER_FROZEN_KEYS = {
    "factory": str,
    "game_count": int,
    "latest": (dict, type(None)),
}
_PROPOSER_LATEST_FROZEN_KEYS = {
    "index": int,
    "game_type": int,
    "timestamp": int,
    "age_sec": (int, type(None)),
    "proxy": str,
}


class ProposerSnapshotAdditiveKeysTests(unittest.TestCase):
    def test_zero_games_is_unknown_and_keeps_frozen_keys(self) -> None:
        factory = "0x" + "11" * 20
        for key, typ in _PROPOSER_FROZEN_KEYS.items():
            panel = {
                "factory": factory,
                "game_count": 0,
                "latest": None,
                "interval_sec": 8 * 3600,
            }
            panel["verdict"] = pipeline_snapshot.proposer_verdict(
                panel["game_count"], panel["latest"], panel["interval_sec"]
            )
            self.assertIn(key, panel)
            self.assertIsInstance(panel[key], typ)
        self.assertEqual(panel["verdict"], pipeline_snapshot.PROPOSER_VERDICT_UNKNOWN)
        self.assertIsInstance(panel["interval_sec"], int)

    def test_populated_latest_keeps_names_and_types(self) -> None:
        now = _pt(2026, 9, 18, 20, 0)
        latest = {
            "index": 485,
            "game_type": 8,
            "timestamp": int(now - 3600),
            "age_sec": 3600,
            "proxy": "0x" + "22" * 20,
        }
        for key, typ in _PROPOSER_LATEST_FROZEN_KEYS.items():
            self.assertIn(key, latest)
            self.assertIsInstance(latest[key], typ)
        verdict = pipeline_snapshot.proposer_verdict(1, latest, 8 * 3600, now=now)
        self.assertEqual(verdict, pipeline_snapshot.PROPOSER_VERDICT_HEALTHY)


class UnknownProposerPanelTests(unittest.TestCase):
    """D-0143: a raised snapshot_proposer() (L1 timeout, JSON-RPC error,
    malformed gameAtIndex) must land on the same three-state contract as a
    clean call that couldn't tell (D-0142) — never a bare `null` panel, and
    never silently collapsed into `healthy`.
    """

    def test_failed_call_yields_unknown_never_null_never_healthy(self) -> None:
        factory = "0x" + "33" * 20
        panel = pipeline_snapshot.unknown_proposer_panel(factory, "8h")
        self.assertIsNotNone(panel)
        self.assertEqual(panel["verdict"], pipeline_snapshot.PROPOSER_VERDICT_UNKNOWN)
        self.assertNotEqual(panel["verdict"], pipeline_snapshot.PROPOSER_VERDICT_HEALTHY)

    def test_failed_call_keeps_frozen_key_names_and_types(self) -> None:
        factory = "0x" + "33" * 20
        panel = pipeline_snapshot.unknown_proposer_panel(factory, "8h")
        for key, typ in _PROPOSER_FROZEN_KEYS.items():
            self.assertIn(key, panel)
            self.assertIsInstance(panel[key], typ)
        self.assertEqual(panel["factory"], factory)
        self.assertIsNone(panel["latest"])
        self.assertIsInstance(panel["interval_sec"], int)
        self.assertEqual(panel["interval_sec"], 8 * 3600)

    def test_unparseable_configured_interval_still_unknown_with_null_interval_sec(
        self,
    ) -> None:
        panel = pipeline_snapshot.unknown_proposer_panel("0x" + "44" * 20, "garbage")
        self.assertEqual(panel["verdict"], pipeline_snapshot.PROPOSER_VERDICT_UNKNOWN)
        self.assertIsNone(panel["interval_sec"])

    def test_main_falls_back_to_unknown_panel_when_snapshot_proposer_raises(
        self,
    ) -> None:
        # Exercises the exact call site main() uses on a raised eth_call,
        # without needing a live RPC endpoint (offline fixture only).
        factory = "0x" + "55" * 20

        def boom(*_args: object, **_kwargs: object) -> dict[str, object]:
            raise RuntimeError("eth_call failed: L1 timeout")

        original = pipeline_snapshot.snapshot_proposer
        pipeline_snapshot.snapshot_proposer = boom
        try:
            try:
                panel = pipeline_snapshot.snapshot_proposer(
                    "http://127.0.0.1:1", factory, "8h"
                )
            except Exception:  # noqa: BLE001 — mirrors main()'s except block
                panel = pipeline_snapshot.unknown_proposer_panel(factory, "8h")
        finally:
            pipeline_snapshot.snapshot_proposer = original

        self.assertIsNotNone(panel)
        self.assertEqual(panel["verdict"], pipeline_snapshot.PROPOSER_VERDICT_UNKNOWN)
        self.assertNotEqual(panel["verdict"], pipeline_snapshot.PROPOSER_VERDICT_HEALTHY)


if __name__ == "__main__":
    unittest.main()
