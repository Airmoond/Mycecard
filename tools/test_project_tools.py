"""Failure-path contracts for the runner, independent of Godot/gameplay."""
import json
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch
from tools.project import ORDERLY_SHUTDOWN_MARKER, checks, command, diagnose, manifest_drift, run_id, select_checks, standalone_command
from tools.history_guard import require_sandbox


class RunnerContracts(unittest.TestCase):
    marker = "检查完成，失败数：0"

    def test_success_requires_completion_and_exit(self):
        self.assertTrue(diagnose(self.marker, {}, 0)["passed"])
        self.assertFalse(diagnose("", {}, 0)["passed"])
        self.assertFalse(diagnose(self.marker, {}, 1)["passed"])
        self.assertFalse(diagnose("检查完成，失败数：1", {}, 0)["passed"])

    def test_timeout_never_becomes_success(self):
        self.assertFalse(diagnose(self.marker, {}, 0, True)["passed"])

    def test_unexpected_error_and_warning_fail(self):
        for diagnostic in ["ERROR: unexpected", "SCRIPT ERROR: unexpected", "WARNING: unexpected"]:
            self.assertFalse(diagnose(diagnostic + "\n" + self.marker, {}, 0)["passed"])

    def test_negative_diagnostic_is_exact_and_counted(self):
        rule = {"expected_errors": {"expected": 1}}
        self.assertTrue(diagnose("ERROR: expected\n" + self.marker, rule, 0)["passed"])
        for output in [self.marker, "ERROR: expected\nERROR: expected\n" + self.marker,
                       "ERROR: expected suffix\n" + self.marker, "SCRIPT ERROR: expected\n" + self.marker]:
            self.assertFalse(diagnose(output, rule, 0)["passed"])

    def test_shutdown_debt_is_scoped_bounded_and_after_success(self):
        debt = "ERROR: 3 resources still in use at exit (run with --verbose for details)."
        rule = {"known_shutdown_max_resources": 3}
        result = diagnose(self.marker + "\n" + debt, rule, 0)
        self.assertTrue(result["passed"])
        self.assertEqual(len(result["known_shutdown_debt"]), 1)
        self.assertFalse(diagnose(self.marker + "\n" + debt, {}, 0)["passed"])
        self.assertFalse(diagnose(debt + "\n" + self.marker, rule, 0)["passed"])
        self.assertFalse(diagnose(self.marker + "\n" + debt.replace("3 resources", "4 resources"), rule, 0)["passed"])

    def test_selection_rejects_empty_and_unregistered_checks(self):
        location = Path(__file__).resolve().parents[1] / ".godot" / "tool-contracts"
        location.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as temporary:
            root = Path(temporary)
            (root / "tools").mkdir()
            (root / "tests").mkdir()
            (root / "tools/checks.json").write_text(json.dumps({"checks": {}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Zero checks"):
                select_checks(root, "all", None)
            (root / "tests/new_test.gd").write_text("", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Unregistered"):
                select_checks(root, "all", None)

    def test_main_tree_cannot_opt_into_experiment_writes(self):
        root = Path(__file__).resolve().parents[1]
        with patch.dict("os.environ", {"MYCECARD_EXPERIMENT_SANDBOX": str(root)}):
            with self.assertRaises(RuntimeError):
                require_sandbox(root)

    def test_source_gate_detects_add_change_and_remove(self):
        self.assertEqual(manifest_drift({"same": 1, "changed": 2, "gone": 3}, {"same": 1, "changed": 4, "new": 5}), ["changed", "gone", "new"])

    def test_parallel_ids_do_not_depend_on_clock_resolution(self):
        with patch("tools.project.datetime") as clock:
            clock.now.return_value.strftime.return_value = "same-second"
            self.assertEqual(len({run_id() for _ in range(256)}), 256)

    def test_actual_process_timeout_is_recorded(self):
        root = Path(__file__).resolve().parents[1]
        location = root / ".godot" / "tool-contracts"
        location.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as temporary:
            state = Path(temporary)
            result = command([sys.executable, "-c", "import time; print('started',flush=True); time.sleep(3)"], root, state, state / "timeout.log", 0.3)
            self.assertTrue(result["timed_out"])
            self.assertEqual(result["exit_code"], -1)
            self.assertIn("TOOL TIMEOUT", result["output"])
            self.assertTrue((state / "timeout.log").is_file())

    def test_child_environment_is_isolated(self):
        root = Path(__file__).resolve().parents[1]
        location = root / ".godot" / "tool-contracts"
        location.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as temporary:
            state = Path(temporary)
            result = command([sys.executable, "-c", "import os,json; print(json.dumps({n:os.environ[n] for n in ['APPDATA','LOCALAPPDATA','TEMP','TMP']}))"], root, state, state / "environment.log", 10)
            self.assertEqual(result["exit_code"], 0)
            self.assertTrue(all(Path(p).is_relative_to(state) for p in json.loads(result["output"]).values()))

    def test_all_check_environments_exist_before_first_worker(self):
        root = Path(__file__).resolve().parents[1]
        location = root / ".godot" / "tool-contracts"
        location.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as temporary:
            state = Path(temporary)
            selected = [(root / "tests" / f"synthetic_{index}_test.gd", {"group": "unit", "completion": self.marker}) for index in range(4)]
            def assert_prepared(argv, project, target, log, timeout):
                for script, _ in selected:
                    for folder in ["appdata", "local-appdata", "temp"]:
                        self.assertTrue((state / "checks" / script.stem / folder).is_dir())
                return {"exit_code": 0, "timed_out": False, "seconds": 0, "log": str(log), "output": self.marker, "command": argv}
            with patch("tools.project.select_checks", return_value=selected), patch("tools.project.command", side_effect=assert_prepared):
                report = checks(root, Path("unused-engine"), state, jobs=2)
            self.assertEqual((report["passed"], report["total"]), (4, 4))

    def test_standalone_uses_application_shutdown_without_source_path(self):
        for headless, backend in [(True, "default"), (False, "default"), (False, "gl_compatibility")]:
            argv = standalone_command(Path("product/Mycecard.exe"), Path("startup.log"), headless, backend)
            self.assertNotIn("--path", argv)
            self.assertNotIn("--script", argv)
            self.assertNotIn("--quit-after", argv)
            self.assertEqual(argv[-2:], ["--", "--smoke-quit-after-frames=120"])
            self.assertEqual("--headless" in argv, headless)
            self.assertEqual("--rendering-method" in argv, not headless and backend == "gl_compatibility")

    def test_standalone_requires_orderly_completion_and_clean_exit(self):
        rule = {"completion": ORDERLY_SHUTDOWN_MARKER}
        self.assertTrue(diagnose(ORDERLY_SHUTDOWN_MARKER, rule, 0)["passed"])
        for output, code, timeout in [("", 0, False), (ORDERLY_SHUTDOWN_MARKER, 1, False),
                                      (ORDERLY_SHUTDOWN_MARKER, 0, True),
                                      (ORDERLY_SHUTDOWN_MARKER + "\nERROR: 1 resources still in use at exit (run with --verbose for details).", 0, False)]:
            self.assertFalse(diagnose(output, rule, code, timeout)["passed"])


if __name__ == "__main__":
    unittest.main()
