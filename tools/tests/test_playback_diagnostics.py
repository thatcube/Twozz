import importlib.util
import json
import tempfile
import unittest
from unittest import mock
import uuid
from pathlib import Path


TOOL_PATH = Path(__file__).parents[1] / "playback-diagnostics.py"
SPEC = importlib.util.spec_from_file_location("playback_diagnostics", TOOL_PATH)
playback_diagnostics = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(playback_diagnostics)


class PlaybackDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.directory = Path(self.temp.name)
        self.session_one = str(uuid.uuid4())
        self.session_two = str(uuid.uuid4())

    def tearDown(self):
        self.temp.cleanup()

    def record(self, session_id, sequence, **changes):
        value = {
            "schemaVersion": 1,
            "timestamp": f"2026-09-04T22:00:{sequence:02d}.123Z",
            "uptimeSeconds": 100.0 + sequence,
            "sessionID": session_id,
            "sequence": sequence,
            "kind": "sample",
            "name": "playback_sample",
            "level": "debug",
            "channel": "public-channel",
            "playbackMode": "live",
            "attributes": {
                "source": "twitch",
                "item_id": "1",
                "access_entry": "0",
                "phase": "playing",
            },
            "metrics": {"buffer_ahead_seconds": 2.0},
            "counters": {},
            "flags": {"playback_active": True},
        }
        value.update(changes)
        return value

    def write_records(self, name, records, final_newline=True):
        payload = "\n".join(json.dumps(record, sort_keys=True) for record in records)
        if final_newline:
            payload += "\n"
        path = self.directory / name
        path.write_text(payload, encoding="utf-8")
        return path

    def write_manifest(self, session_id, ended=False):
        manifest = {
            "schemaVersion": 1,
            "sessionID": session_id,
            "fileName": f"playback-{session_id}-0002.jsonl",
            "channel": "public-channel",
            "playbackMode": "live",
            "startedAt": "2026-09-04T22:00:01.123Z",
        }
        if ended:
            manifest["endedAt"] = "2026-09-04T22:10:00.123Z"
        (self.directory / "latest-session.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def test_parses_all_rotated_parts_for_selected_session(self):
        self.write_records(
            f"playback-{self.session_one}-0001.jsonl",
            [self.record(self.session_one, 1), self.record(self.session_one, 2)],
        )
        self.write_records(
            f"playback-{self.session_one}-0002.jsonl",
            [self.record(self.session_one, 3)],
        )
        report = playback_diagnostics.analyze(
            self.directory, requested_session=self.session_one
        )
        session = report["sessions"][0]
        self.assertEqual(session["counts"]["records"], 3)
        self.assertEqual(session["sequence"], {"first": 1, "last": 3, "gaps": []})

    def test_latest_manifest_selects_one_session_without_combining(self):
        self.write_records(
            f"playback-{self.session_one}-0001.jsonl",
            [self.record(self.session_one, 1)],
        )
        self.write_records(
            f"playback-{self.session_two}-0001.jsonl",
            [self.record(self.session_two, 1)],
        )
        self.write_manifest(self.session_two)
        report = playback_diagnostics.analyze(self.directory)
        self.assertEqual(report["selection"], "latest-session.json")
        self.assertEqual([item["session_id"] for item in report["sessions"]], [self.session_two])

    def test_newest_record_selects_one_session_without_manifest(self):
        older = self.record(self.session_one, 1)
        newer = self.record(self.session_two, 1)
        newer["timestamp"] = "2026-09-04T23:00:01.123Z"
        self.write_records(f"playback-{self.session_one}-0001.jsonl", [older])
        self.write_records(f"playback-{self.session_two}-0001.jsonl", [newer])
        report = playback_diagnostics.analyze(self.directory)
        self.assertEqual(report["selection"], "newest-record")
        self.assertEqual([item["session_id"] for item in report["sessions"]], [self.session_two])

    def test_all_keeps_sessions_separate(self):
        self.write_records(
            f"playback-{self.session_one}-0001.jsonl",
            [self.record(self.session_one, 1)],
        )
        self.write_records(
            f"playback-{self.session_two}-0001.jsonl",
            [self.record(self.session_two, 1)],
        )
        report = playback_diagnostics.analyze(self.directory, all_sessions=True)
        self.assertEqual(len(report["sessions"]), 2)
        self.assertTrue(all(item["counts"]["records"] == 1 for item in report["sessions"]))

    def test_truncated_tail_is_warned_and_ignored(self):
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl",
            [self.record(self.session_one, 1)],
        )
        with path.open("ab") as handle:
            handle.write(b'{"schemaVersion":1,"timestamp":"unfinished')
        report = playback_diagnostics.analyze(path)
        session = report["sessions"][0]
        self.assertEqual(session["counts"]["records"], 1)
        self.assertTrue(any("incomplete final JSON line" in warning for warning in session["warnings"]))

    def test_rejects_corrupt_completed_line(self):
        path = self.directory / f"playback-{self.session_one}-0001.jsonl"
        path.write_text("{not json}\n", encoding="utf-8")
        with self.assertRaisesRegex(
            playback_diagnostics.DiagnosticsError, "malformed completed JSON line"
        ):
            playback_diagnostics.analyze(path)

    def test_rejects_unknown_schema(self):
        record = self.record(self.session_one, 1)
        record["schemaVersion"] = 2
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [record]
        )
        with self.assertRaisesRegex(
            playback_diagnostics.DiagnosticsError, "unsupported schemaVersion"
        ):
            playback_diagnostics.analyze(path)

    def test_cumulative_counters_reset_at_item_and_access_boundaries(self):
        records = []
        for sequence, item, access, value in [
            (1, "1", "0", 10),
            (2, "1", "0", 12),
            (3, "1", "1", 50),
            (4, "1", "1", 52),
            (5, "2", "0", 3),
        ]:
            record = self.record(self.session_one, sequence)
            record["attributes"]["item_id"] = item
            record["attributes"]["access_entry"] = access
            record["counters"] = {"dropped_video_frames": value}
            records.append(record)
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", records
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["counter_deltas"]["dropped_video_frames"], 57)

    def test_proxy_counters_span_item_replacements(self):
        records = []
        for sequence, item, value in [(1, "1", 10), (2, "1", 12), (3, "2", 14), (4, "2", 16)]:
            record = self.record(self.session_one, sequence)
            record["attributes"]["item_id"] = item
            record["counters"] = {"proxy_requests": value}
            records.append(record)
        path = self.write_records(f"playback-{self.session_one}-0001.jsonl", records)
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["counter_deltas"]["proxy_requests"], 6)

    def test_full_session_counts_initial_counters_and_one_recovery(self):
        records = [
            self.record(self.session_one, 1, kind="event", name="session_started"),
            self.record(self.session_one, 2, counters={"proxy_requests": 10}),
            self.record(self.session_one, 3, kind="event", name="recovery_requested"),
            self.record(self.session_one, 4, kind="event", name="recovery_started"),
            self.record(self.session_one, 5, kind="event", name="recovery_completed"),
            self.record(self.session_one, 6, counters={"proxy_requests": 12}),
        ]
        records[5]["attributes"]["item_id"] = "2"
        path = self.write_records(f"playback-{self.session_one}-0001.jsonl", records)
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["counter_deltas"]["proxy_requests"], 12)
        self.assertEqual(session["counts"]["controller_interventions"], 1)

    def test_rates_use_retained_window_and_do_not_double_weight_access_logs(self):
        sample = self.record(self.session_one, 3, counters={"proxy_requests": 100})
        sample["metrics"] = {"observed_bitrate_bps": 1_000}
        access = self.record(self.session_one, 4, kind="access_log")
        access["metrics"] = {"observed_bitrate_bps": 10_000}
        end = self.record(
            self.session_one, 5, kind="summary", name="session_ended",
            metrics={"duration_seconds": 500},
        )
        path = self.write_records(f"playback-{self.session_one}-0001.jsonl", [sample, access, end])
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["duration_seconds"], 500)
        self.assertEqual(session["rate_window_seconds"], 2)
        self.assertEqual(session["metric_distributions"]["observed_bitrate_bps"]["count"], 1)

    def test_pull_requires_device_and_refuses_overwrite(self):
        with self.assertRaisesRegex(playback_diagnostics.DiagnosticsError, "pass --device"):
            playback_diagnostics.pull(None, "com.thatcube.Twozz", self.directory)
        with mock.patch.object(playback_diagnostics.shutil, "which", return_value="/usr/bin/xcrun"):
            with self.assertRaisesRegex(playback_diagnostics.DiagnosticsError, "overwrite"):
                playback_diagnostics.pull("test-device", "com.thatcube.Twozz", self.directory)

    def test_pull_propagates_device_copy_failure(self):
        output = self.directory / "new"
        with mock.patch.object(playback_diagnostics.shutil, "which", return_value="/usr/bin/xcrun"):
            with mock.patch.object(
                playback_diagnostics.subprocess, "run",
                return_value=mock.Mock(returncode=1, stderr="device unavailable", stdout=""),
            ):
                with self.assertRaisesRegex(playback_diagnostics.DiagnosticsError, "device unavailable"):
                    playback_diagnostics.pull("test-device", "com.thatcube.Twozz", output)

    def test_dropped_records_and_sequence_gaps_mark_partial_evidence(self):
        first = self.record(self.session_one, 1)
        admitted_after_drop = self.record(self.session_one, 4)
        admitted_after_drop["counters"] = {"telemetry_records_dropped": 2}
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [first, admitted_after_drop]
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["counter_deltas"]["telemetry_records_dropped"], 2)
        self.assertEqual(session["sequence"]["gaps"][0]["missing"], 2)
        self.assertTrue(session["partial_evidence"])

    def test_skipped_native_log_backlog_marks_partial_evidence(self):
        skipped = self.record(
            self.session_one,
            1,
            kind="event",
            name="log_entries_skipped",
            level="warning",
            metrics={},
            counters={"access_entries": 3, "error_entries": 2},
        )
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [skipped]
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(
            session["skipped_native_log_entries"],
            {"access_entries": 3, "error_entries": 2},
        )
        self.assertTrue(session["partial_evidence"])
        self.assertTrue(
            any("native-log collection skipped" in warning for warning in session["warnings"])
        )

    def test_proxy_last_failure_evidence_is_reported_as_latest_not_delta(self):
        first = self.record(self.session_one, 1)
        first["counters"] = {
            "proxy_last_failure_status": 503,
            "proxy_last_failure_error_code": -1001,
        }
        first["metrics"] = {"proxy_last_failure_uptime_seconds": 95.0}
        later_success = self.record(self.session_one, 2)
        later_success["counters"] = {
            "proxy_last_failure_status": 503,
            "proxy_last_failure_error_code": -1001,
        }
        later_success["metrics"] = {
            "buffer_ahead_seconds": 4.0,
            "proxy_last_failure_uptime_seconds": 95.0,
        }
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [first, later_success]
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["latest_counter_values"]["proxy_last_failure_status"], 503)
        self.assertEqual(
            session["latest_counter_values"]["proxy_last_failure_error_code"], -1001
        )
        self.assertNotIn("proxy_last_failure_status", session["counter_deltas"])
        self.assertEqual(
            session["proxy_last_failure"],
            {"status": 503, "error_code": -1001, "uptime_seconds": 95.0},
        )
        self.assertEqual(
            session["metric_distributions"]["proxy_last_failure_uptime_seconds"]["p50"],
            95.0,
        )

    def test_active_partial_report_and_sequence_gap(self):
        path = self.write_records(
            f"playback-{self.session_one}-0002.jsonl",
            [self.record(self.session_one, 4), self.record(self.session_one, 6)],
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertTrue(session["active"])
        self.assertTrue(session["partial_evidence"])
        self.assertEqual(len(session["sequence"]["gaps"]), 2)
        self.assertTrue(any("sequence gaps" in warning for warning in session["warnings"]))

    def test_closed_session_with_full_boundaries_is_not_partial(self):
        started = self.record(
            self.session_one,
            1,
            kind="event",
            name="session_started",
            level="info",
            metrics={},
            counters={},
            flags={},
        )
        ended = self.record(
            self.session_one,
            2,
            kind="summary",
            name="session_ended",
            level="info",
            metrics={"duration_seconds": 120.0},
            counters={"stall_started": 0},
            flags={},
        )
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [started, ended]
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertFalse(session["active"])
        self.assertFalse(session["partial_evidence"])
        self.assertEqual(session["duration_seconds"], 120.0)

    def test_flags_are_not_conflated_with_explicit_stalls(self):
        record = self.record(self.session_one, 1)
        record["attributes"]["phase"] = "seeking"
        record["flags"].update(
            {
                "loading": True,
                "user_paused": True,
                "scrubbing": True,
                "recovering": True,
                "buffer_empty": True,
                "decode_frozen": True,
            }
        )
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [record]
        )
        session = playback_diagnostics.analyze(path)["sessions"][0]
        self.assertEqual(session["counts"]["stall_episodes"], 0)
        self.assertEqual(session["stalls"], [])

    def test_json_output_shape_separates_stalls_and_errors(self):
        start = self.record(
            self.session_one,
            1,
            kind="event",
            name="stall_started",
            level="warning",
            attributes={"item_id": "1", "stall_kind": "network_or_buffer"},
            metrics={"buffer_ahead_seconds": 0.1},
        )
        error = self.record(
            self.session_one,
            2,
            kind="error_log",
            name="avplayer_error_log",
            level="error",
            attributes={"item_id": "1", "error_domain": "test"},
            metrics={},
        )
        path = self.write_records(
            f"playback-{self.session_one}-0001.jsonl", [start, error]
        )
        report = playback_diagnostics.analyze(path)
        self.assertEqual(report["tool_schema_version"], 1)
        session = report["sessions"][0]
        self.assertEqual(session["stalls"][0]["name"], "stall_started")
        self.assertEqual(session["stream_errors"][0]["name"], "avplayer_error_log")
        self.assertNotIn("stall_started", [entry["name"] for entry in session["timeline"]])
        json.dumps(report, allow_nan=False, sort_keys=True)


if __name__ == "__main__":
    unittest.main()
