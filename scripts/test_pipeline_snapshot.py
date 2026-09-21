"""Unit tests for the pure helpers in pipeline-snapshot.py."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
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


def _plist(label: str, hour: int, minute: int) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        f"  <key>Label</key><string>{label}</string>\n"
        "  <key>StartCalendarInterval</key><dict>\n"
        f"    <key>Hour</key><integer>{hour}</integer>\n"
        f"    <key>Minute</key><integer>{minute}</integer>\n"
        "  </dict>\n"
        "</dict></plist>\n"
    )


def _write_window(directory: Path, start_h: int, start_m: int, end_h: int, end_m: int) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "com.steve.fortel2-sleep.plist").write_text(
        _plist("com.steve.fortel2-sleep", start_h, start_m)
    )
    (directory / "com.steve.fortel2-wake.plist").write_text(
        _plist("com.steve.fortel2-wake", end_h, end_m)
    )


class _WindowPin:
    """Point both readers at fixture plists for the duration of a test."""

    def _pin(self, start_h: int, start_m: int, end_h: int, end_m: int) -> None:
        self._agents = Path(tempfile.mkdtemp(prefix="fortel2-sleepwin-"))
        self._prev = os.environ.get("FORTEL2_DEV_SLEEP_AGENTS_DIR")
        _write_window(self._agents, start_h, start_m, end_h, end_m)
        os.environ["FORTEL2_DEV_SLEEP_AGENTS_DIR"] = str(self._agents)

    def _unpin(self) -> None:
        if self._prev is None:
            os.environ.pop("FORTEL2_DEV_SLEEP_AGENTS_DIR", None)
        else:
            os.environ["FORTEL2_DEV_SLEEP_AGENTS_DIR"] = self._prev
        shutil.rmtree(self._agents, ignore_errors=True)


class DevSleepWindowTests(_WindowPin, unittest.TestCase):
    """Re-anchored from the old 23:45–03:00 window to the configured
    23:45–00:15 window (D-0144). 01:30 used to be asleep; it is awake.
    """

    def setUp(self) -> None:
        self._pin(23, 45, 0, 15)

    def tearDown(self) -> None:
        self._unpin()

    def test_wrapping_window_marks_2350_and_0005_asleep(self) -> None:
        self.assertTrue(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 23, 50)))
        self.assertTrue(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 0, 5)))
        self.assertEqual(pipeline_snapshot.dev_sleep_window()["source"], "launchd")
        self.assertEqual(pipeline_snapshot.dev_sleep_window()["duration_sec"], 30 * 60)

    def test_0030_0130_0230_are_awake(self) -> None:
        # These were inside the old 03:00 window. They are the stack-down
        # hours a 30-minute outage must not hide.
        for hour in (0, 1, 2):
            with self.subTest(hour=hour):
                self.assertFalse(
                    pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, hour, 30))
                )

    def test_boundaries_are_inclusive_start_exclusive_end(self) -> None:
        self.assertTrue(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 23, 45)))
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 0, 15)))
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 23, 44)))

    def test_midday_is_awake(self) -> None:
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 18, 12, 0)))


class NonWrappingDevSleepTests(_WindowPin, unittest.TestCase):
    """§7 trap: start < end must not mark the rest of the day asleep."""

    def setUp(self) -> None:
        self._pin(1, 0, 3, 0)

    def tearDown(self) -> None:
        self._unpin()

    def test_0200_asleep_and_1400_awake(self) -> None:
        self.assertTrue(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 2, 0)))
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 14, 0)))
        self.assertFalse(pipeline_snapshot.dev_sleep_window()["wraps"])
        self.assertEqual(pipeline_snapshot.dev_sleep_window()["duration_sec"], 2 * 3600)

    def test_non_wrapping_does_not_swallow_the_evening(self) -> None:
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 23, 50)))
        self.assertFalse(pipeline_snapshot.in_dev_sleep_window(_pt(2026, 9, 19, 0, 30)))


class DevSleepFallbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self._agents = Path(tempfile.mkdtemp(prefix="fortel2-sleepwin-"))
        self._prev = os.environ.get("FORTEL2_DEV_SLEEP_AGENTS_DIR")
        os.environ["FORTEL2_DEV_SLEEP_AGENTS_DIR"] = str(self._agents)

    def tearDown(self) -> None:
        if self._prev is None:
            os.environ.pop("FORTEL2_DEV_SLEEP_AGENTS_DIR", None)
        else:
            os.environ["FORTEL2_DEV_SLEEP_AGENTS_DIR"] = self._prev
        shutil.rmtree(self._agents, ignore_errors=True)

    def test_missing_plists_are_the_documented_default_and_labeled(self) -> None:
        window = pipeline_snapshot.dev_sleep_window()
        report = pipeline_snapshot.dev_sleep_report()
        self.assertEqual(window["source"], "default")
        self.assertIsNone(window["agentsDir"])
        self.assertEqual(window["startLocal"], "23:45")
        self.assertEqual(window["endLocal"], "00:15")
        self.assertEqual(report["source"], "default")
        self.assertIsNone(report["agentsDir"])

    def test_unparseable_plist_is_not_reported_as_measured(self) -> None:
        (self._agents / "com.steve.fortel2-sleep.plist").write_text("not a plist")
        (self._agents / "com.steve.fortel2-wake.plist").write_text("not a plist")
        # Cache key is the directory; contents changed under the same key.
        pipeline_snapshot._DEV_SLEEP_CACHE = None
        window = pipeline_snapshot.dev_sleep_window()
        self.assertEqual(window["source"], "default")
        self.assertEqual(window["endLocal"], "00:15")


class AwakeSecondsBetweenTests(_WindowPin, unittest.TestCase):
    def setUp(self) -> None:
        self._pin(23, 45, 0, 15)

    def tearDown(self) -> None:
        self._unpin()

    def test_zero_or_negative_range(self) -> None:
        self.assertEqual(pipeline_snapshot.awake_seconds_between(100.0, 100.0), 0.0)
        self.assertEqual(pipeline_snapshot.awake_seconds_between(200.0, 100.0), 0.0)

    def test_daytime_only_range_is_unaffected(self) -> None:
        lo = _pt(2026, 9, 18, 9, 0)
        hi = _pt(2026, 9, 18, 17, 0)
        self.assertEqual(pipeline_snapshot.awake_seconds_between(lo, hi), hi - lo)

    def test_range_wholly_inside_one_window(self) -> None:
        # Re-anchored: 00:30–01:30 is awake under a 00:15 wake. A range
        # inside 23:45–00:15 is entirely asleep.
        lo = _pt(2026, 9, 18, 23, 50)
        hi = _pt(2026, 9, 19, 0, 10)
        self.assertEqual(pipeline_snapshot.awake_seconds_between(lo, hi), 0.0)

    def test_thirty_minute_window_removes_thirty_minutes_not_three_hours(self) -> None:
        lo = _pt(2026, 9, 18, 22, 0)
        hi = _pt(2026, 9, 19, 5, 0)
        awake = pipeline_snapshot.awake_seconds_between(lo, hi)
        self.assertAlmostEqual(awake, (hi - lo) - 30 * 60, delta=1.0)
        self.assertGreater(awake, (hi - lo) - (3 * 3600 + 15 * 60) + 60)

    def test_range_spanning_two_full_windows(self) -> None:
        # §7 trap: a dead proposer over ~54h spans two nightly windows; both
        # must be removed, and each is the configured 30 minutes.
        lo = _pt(2026, 9, 17, 12, 0)
        hi = _pt(2026, 9, 19, 18, 0)
        awake = pipeline_snapshot.awake_seconds_between(lo, hi)
        self.assertAlmostEqual(awake, (hi - lo) - 2 * 30 * 60, delta=1.0)


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
        # Re-anchored (D-0144): the subtracted width is the configured window,
        # not a hardcoded 3 h 15 m. Pinned to 23:45–00:15 so the assertion
        # does not follow whatever the host's launchd jobs happen to be.
        self._pin = _WindowPin()
        self._pin._pin(23, 45, 0, 15)
        try:
            interval = 8 * 3600
            threshold = interval + pipeline_snapshot.PROPOSER_OVERDUE_GRACE_SECS
            now = _pt(2026, 9, 19, 5, 0)
            window = pipeline_snapshot.dev_sleep_window()["duration_sec"]
            self.assertEqual(window, 30 * 60)
            # Awake age sits 1 minute under the threshold. Raw age adds the
            # whole 30-minute window, so a naive `age > threshold` fires and
            # the awake-time check must not. (The old 1 h slack only exceeded
            # the threshold when the window was 3 h 15 m.)
            ts = now - (threshold - 60) - window
            latest = {"timestamp": ts}
            raw_age = now - ts
            self.assertGreater(raw_age, threshold)  # a naive check would fire
            self.assertEqual(
                pipeline_snapshot.proposer_verdict(1, latest, interval, now=now),
                self.HEALTHY,
            )
        finally:
            self._pin._unpin()

    def test_two_sleep_windows_judged_on_awake_time_not_one_windows_worth(self) -> None:
        # §7 trap: a gap that spans two nights has both windows removed.
        # Re-anchored (D-0144) to the configured 30-minute window: two nights
        # remove 60 minutes, not 2 × 3 h 15 m.
        self._pin = _WindowPin()
        self._pin._pin(23, 45, 0, 15)
        try:
            interval = 8 * 3600
            threshold = interval + pipeline_snapshot.PROPOSER_OVERDUE_GRACE_SECS
            now = _pt(2026, 9, 19, 18, 0)
            lo = _pt(2026, 9, 17, 12, 0)
            awake = pipeline_snapshot.awake_seconds_between(lo, now)
            self.assertAlmostEqual(awake, (now - lo) - 2 * 30 * 60, delta=1.0)
            self.assertGreater(awake, threshold)
            latest = {"timestamp": lo}
            self.assertEqual(
                pipeline_snapshot.proposer_verdict(1, latest, interval, now=now),
                self.OVERDUE,
            )
        finally:
            self._pin._unpin()

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

    # Env keys main() reads via env_get() (os.environ takes priority over the
    # loaded file) — cleared for the duration of the drive-through test below
    # so the checked-in .env.example fixture values are what actually govern,
    # regardless of what the ambient test-runner shell happens to export.
    _MAIN_ENV_KEYS = (
        "FORTEL2_ENV",
        "FORTEL2_ROOT",
        "L1_CHAIN_ID",
        "L2_CHAIN_ID",
        "L1_RPC_URL",
        "L2_RPC_URL",
        "L2_NODE_RPC_URL",
        "BATCHER_ADDRESS",
        "DEPLOY_DIR",
        "SEPOLIA_PROPOSER_INTERVAL",
    )

    def test_main_emits_unknown_proposer_never_null_when_rpc_layer_raises(
        self,
    ) -> None:
        """Drives the real main() end to end (D-0143 regression).

        Deleting main()'s `except` fallback assignment (leaving
        `result["proposer"]` at its `None` initializer) must turn this test
        red — mocking only `snapshot_proposer` and asserting against
        `unknown_proposer_panel()` directly, as an earlier version of this
        test did, cannot detect that regression because it never calls
        main() at all.

        The shared `rpc()` transport is made to raise, the same externally
        observable failure as an L1 timeout or JSON-RPC error — offline
        fixture only, no live RPC. `deployments/deployments.json`'s checked-in
        `DisputeGameFactoryProxy` (a real address, not live-queried) is what
        lets main() reach the `snapshot_proposer()` call site at all.
        """

        def boom(*_args: object, **_kwargs: object) -> None:
            raise RuntimeError("offline fixture: simulated L1 timeout")

        env_backup = {k: os.environ.get(k) for k in self._MAIN_ENV_KEYS}
        original_rpc = pipeline_snapshot.rpc
        original_argv = sys.argv
        try:
            for key in self._MAIN_ENV_KEYS:
                os.environ.pop(key, None)
            os.environ["FORTEL2_ENV"] = str(
                SCRIPT_PATH.parents[1] / ".env.example"
            )
            pipeline_snapshot.rpc = boom
            with tempfile.TemporaryDirectory() as tmp:
                out_path = Path(tmp) / "pipeline-health.json"
                sys.argv = ["pipeline-snapshot.py", "-o", str(out_path)]
                pipeline_snapshot.main()
                result = json.loads(out_path.read_text())
        finally:
            pipeline_snapshot.rpc = original_rpc
            sys.argv = original_argv
            for key, val in env_backup.items():
                if val is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = val

        self.assertIn(result["devSleep"]["source"], ("launchd", "default"))
        self.assertRegex(result["devSleep"]["startLocal"], r"^\d{2}:\d{2}$")
        self.assertRegex(result["devSleep"]["endLocal"], r"^\d{2}:\d{2}$")
        proposer = result["proposer"]
        self.assertIsNotNone(proposer)
        self.assertEqual(proposer["verdict"], pipeline_snapshot.PROPOSER_VERDICT_UNKNOWN)
        self.assertNotEqual(proposer["verdict"], pipeline_snapshot.PROPOSER_VERDICT_HEALTHY)
        self.assertTrue(
            any(e.get("panel") == "proposer" for e in result["errors"]),
            "expected the raised eth_call recorded in errors alongside the unknown verdict",
        )


def _alert_watch_namespace() -> dict:
    text = Path(__file__).with_name("alert-watch.sh").read_text()

    def grab(start_mark: str, end_mark: str) -> str:
        start = text.find(start_mark)
        end = text.find(end_mark)
        if start < 0 or end < 0 or end <= start:
            raise AssertionError(f"missing {start_mark}")
        return text[start + len(start_mark) : end]

    ns: dict = {"__name__": "alert_watch_dev_sleep"}
    exec(grab("# <<<DEV_SLEEP_READER\n", "# >>>DEV_SLEEP_READER\n"), ns)
    exec(grab("# <<<AWAKE_SECONDS\n", "# >>>AWAKE_SECONDS\n"), ns)
    return ns


class TwoReaderParityTests(_WindowPin, unittest.TestCase):
    """pipeline-snapshot.py and alert-watch.sh must agree (D-0142 / D-0144)."""

    def _assert_parity(self, start_h, start_m, end_h, end_m) -> None:
        self._pin(start_h, start_m, end_h, end_m)
        try:
            watch = _alert_watch_namespace()
            py_window = pipeline_snapshot.dev_sleep_window()
            sh_window = watch["dev_sleep_window"]()
            self.assertEqual(py_window["start_min"], sh_window["start_min"])
            self.assertEqual(py_window["end_min"], sh_window["end_min"])
            self.assertEqual(py_window["source"], sh_window["source"])
            self.assertEqual(py_window["duration_sec"], sh_window["duration_sec"])
            tz = ZoneInfo("America/Los_Angeles")
            # Hourly samples across 2026, dense on both DST transitions.
            # Minute-aligned so the 60 s walk and the boundary overlap match.
            cursor = datetime(2026, 1, 1, 0, 0, tzinfo=tz)
            stop = datetime(2027, 1, 1, 0, 0, tzinfo=tz)
            spans = (12 * 3600, 30 * 3600, 54 * 3600)
            while cursor < stop:
                ts = cursor.timestamp()
                self.assertEqual(
                    pipeline_snapshot.in_dev_sleep_window(ts),
                    watch["in_dev_sleep_window"](ts),
                    cursor.isoformat(),
                )
                month_day = (cursor.month, cursor.day)
                dense = month_day in ((3, 8), (3, 9), (11, 1), (11, 2))
                step_hours = 1 if dense else 6
                if cursor.hour % step_hours == 0:
                    for span in spans:
                        hi = ts + span
                        left = pipeline_snapshot.awake_seconds_between(ts, hi)
                        right = watch["awake_seconds"](ts, hi)
                        self.assertEqual(left, right, f"{cursor.isoformat()} +{span}")
                cursor += timedelta(hours=1)
        finally:
            self._unpin()

    def test_wrapping_window_agrees_across_2026_including_dst(self) -> None:
        self._assert_parity(23, 45, 0, 15)

    def test_non_wrapping_window_agrees_across_2026_including_dst(self) -> None:
        self._assert_parity(1, 0, 3, 0)


if __name__ == "__main__":
    unittest.main()
