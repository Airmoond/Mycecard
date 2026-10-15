"""Local, dependency-free Mycecard import/check/release and isolated experiment entrypoint."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import uuid
from urllib.parse import unquote

PROJECT = Path(__file__).resolve().parents[1]
OMIT = {".godot", ".git", "release", "__pycache__", ".venv", ".agents", ".codex", ".matplotlib-cache"}
GROUP_TIMEOUTS = {"unit": 90, "flow": 180, "presentation": 180, "audio": 180, "heavy": 360, "playtest": 360}
ORDERLY_SHUTDOWN_MARKER = "Mycecard orderly shutdown complete"


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:12]


def local_environment(root: Path, state: Path) -> dict:
    environment = os.environ.copy()
    for name, directory in {"APPDATA": "appdata", "LOCALAPPDATA": "local-appdata", "TEMP": "temp", "TMP": "temp"}.items():
        location = state / directory
        location.mkdir(parents=True, exist_ok=True)
        environment[name] = str(location)
    environment["PYTHONUTF8"] = "1"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["MYCECARD_PROJECT_ROOT"] = str(root)
    return environment


def command(argv: list[str], root: Path, state: Path, log: Path, timeout: float = 120, extra_env: dict | None = None) -> dict:
    environment = local_environment(root, state)
    environment.update(extra_env or {})
    windows = {}
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        windows = {"startupinfo": startup, "creationflags": subprocess.CREATE_NO_WINDOW}
    started = time.monotonic()
    try:
        result = subprocess.run(argv, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                encoding="utf-8", errors="replace", timeout=timeout, **windows)
        output, code, timed_out = result.stdout, result.returncode, False
    except subprocess.TimeoutExpired as failure:
        output = failure.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        output += f"\nTOOL TIMEOUT: exceeded {timeout}s\n"
        code, timed_out = -1, True
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(output, encoding="utf-8")
    return {"exit_code": code, "timed_out": timed_out, "seconds": round(time.monotonic() - started, 3),
            "log": str(log), "output": output, "command": argv}


def public_result(result: dict) -> dict:
    return {key: value for key, value in result.items() if key != "output"}


def diagnose(output: str, rule: dict, exit_code: int, timed_out: bool = False) -> dict:
    """Accept exact scoped negative diagnostics; every other diagnostic is a failure."""
    marker = rule.get("completion", r"[^\n]*检查完成，失败数：0")
    completion = re.search(r"(?m)^" + marker + r"\s*$", output)
    reasons = []
    if timed_out:
        reasons.append("timeout")
    if exit_code != 0:
        reasons.append(f"exit code {exit_code}")
    if not completion:
        reasons.append("missing successful completion marker")
    allowed = rule.get("expected_errors", {})
    seen = {message: 0 for message in allowed}
    debt, unexpected = [], []
    shutdown_counts = {"object": 0, "resource": 0}
    for match in re.finditer(r"(?m)^(SCRIPT ERROR|ERROR|WARNING):\s*(.*)$", output):
        severity, message = match.group(1), match.group(2).strip()
        if severity == "ERROR" and message in allowed:
            seen[message] += 1
            if seen[message] <= allowed[message]:
                continue
        after_completion = completion is not None and match.start() > completion.end()
        maximum = rule.get("known_shutdown_max_resources", 0)
        if maximum and after_completion:
            if severity == "WARNING" and message == "ObjectDB instances leaked at exit (run with --verbose for details).":
                shutdown_counts["object"] += 1
                if shutdown_counts["object"] == 1:
                    debt.append(message)
                    continue
            resources = re.fullmatch(r"(\d+) resources still in use at exit \(run with --verbose for details\)\.", message)
            if severity == "ERROR" and resources and 0 < int(resources.group(1)) <= maximum:
                shutdown_counts["resource"] += 1
                if shutdown_counts["resource"] == 1:
                    debt.append(message)
                    continue
        unexpected.append(f"{severity}: {message}")
    for message, count in allowed.items():
        if seen[message] != count:
            reasons.append(f"expected diagnostic count {count}, got {seen[message]}: {message}")
    if unexpected:
        reasons.append("unexpected diagnostics")
    return {"passed": not reasons, "reasons": reasons, "unexpected": unexpected,
            "expected_diagnostics": seen, "known_shutdown_debt": debt}


def engine_path(args) -> Path:
    value = args.godot or os.environ.get("GODOT_BIN")
    if not value:
        raise ValueError("Specify --godot <console executable> or GODOT_BIN.")
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"Godot executable not found: {path}")
    return path


def doctor(root: Path, engine: Path, state: Path, optional: str | None = None) -> dict:
    versions = read_json(root / "tools/environment.json")
    result = command([str(engine), "--version"], root, state, state / "version.log", 30)
    version = result["output"].strip().splitlines()[-1] if result["output"].strip() else ""
    python_version = platform.python_version()
    passed = result["exit_code"] == 0 and version.startswith(versions["godot"] + ".") and python_version == versions["python"]
    details = {"godot": version, "python": python_version, "required_godot": versions["godot"], "required_python": versions["python"]}
    if optional:
        packages = versions["optional_audio" if optional == "audio" else "optional_plots"]
        installed = {}
        for name, expected in packages.items():
            if name == "ffmpeg":
                executable = os.environ.get("PHASE6_FFMPEG") or shutil.which("ffmpeg")
                valid = bool(executable and Path(executable).is_file())
                installed[name] = {"path": executable, "available": valid}
                if valid:
                    ffmpeg = command([str(executable), "-version"], root, state, state / "ffmpeg-version.log", 30)
                    installed[name]["version"] = ffmpeg["output"].splitlines()[0]
                    installed[name]["reference_version"] = versions.get("ffmpeg_reference_version")
                    valid = ffmpeg["exit_code"] == 0
                passed = passed and valid
            else:
                try:
                    actual = importlib.metadata.version(name)
                except importlib.metadata.PackageNotFoundError:
                    actual = "missing"
                installed[name] = {"actual": actual, "required": expected}
                passed = passed and actual == expected
        details["optional"] = installed
    details["passed"] = passed
    write_json(state / "environment.json", details)
    return details


def import_resources(root: Path, engine: Path, state: Path) -> dict:
    result = command([str(engine), "--headless", "--path", str(root), "--editor", "--import",
                      "--log-file", str(state / "import-engine.log")], root, state, state / "import.log", 240)
    diagnostics = re.findall(r"(?m)^(?:SCRIPT ERROR|ERROR|WARNING):.*$", result["output"])
    passed = result["exit_code"] == 0 and not result["timed_out"] and not diagnostics
    record = {**public_result(result), "passed": passed, "diagnostics": diagnostics}
    write_json(state / "import.json", record)
    return record


def tool_contracts(root: Path, state: Path) -> dict:
    result = command([sys.executable, "-m", "unittest", "tools.test_project_tools"], root, state, state / "tool-contracts.log", 60)
    count = re.search(r"Ran ([1-9]\d*) tests?", result["output"])
    passed = result["exit_code"] == 0 and not result["timed_out"] and count is not None and re.search(r"(?m)^OK\s*$", result["output"]) is not None
    record = {"passed": passed, "total": int(count.group(1)) if count else 0, **public_result(result)}
    write_json(state / "tool-contracts.json", record)
    return record


def docs_check(root: Path) -> dict:
    files = [root / "README.md", *(root / "docs").rglob("*.md")]
    broken = []
    for path in files:
        text = re.sub(r"```[\s\S]*?```", "", path.read_text(encoding="utf-8"))
        for match in re.finditer(r"!?\[[^\]\n]+\]\(([^\)\n]+)\)", text):
            target = match.group(1).strip().strip("<>")
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("#"):
                continue
            target = unquote(target.split("#", 1)[0])
            if not (path.parent / target).exists():
                broken.append({"file": path.relative_to(root).as_posix(), "target": target})
    return {"passed": not broken, "checked_files": len(files), "broken_links": broken}


def select_checks(root: Path, group: str, pattern: str | None) -> list[tuple[Path, dict]]:
    configuration = read_json(root / "tools/checks.json")
    rules = configuration["checks"]
    selected = []
    unknown = []
    for script in sorted((root / "tests").glob("*test.gd")):
        rule = rules.get(script.name)
        if rule is None:
            unknown.append(script.name)
            continue
        if group != "all" and rule["group"] != group:
            continue
        if pattern and not re.search(pattern, script.name):
            continue
        selected.append((script, rule))
    if unknown:
        raise ValueError("Unregistered checks (declare group/completion/diagnostics): " + ", ".join(unknown))
    if not selected:
        raise ValueError("Zero checks selected; refusing to report success.")
    missing = [name for name in rules if not (root / "tests" / name).is_file()]
    if missing:
        raise ValueError("Registered checks missing: " + ", ".join(missing))
    return selected


def checks(root: Path, engine: Path, state: Path, group: str = "all", pattern: str | None = None, jobs: int = 2, timeout: float | None = None) -> dict:
    selected = select_checks(root, group, pattern)
    # Windows can refuse concurrent creation below the same new parent. Prepare
    # every isolated environment serially before any engine process is started.
    # Permission failures remain fatal; none are swallowed or retried as success.
    for script, _ in selected:
        local_environment(root, state / "checks" / script.stem)
    def run(item):
        script, rule = item
        target = state / "checks" / script.stem
        seconds = timeout or rule.get("timeout", GROUP_TIMEOUTS[rule["group"]])
        result = command([str(engine), "--headless", "--path", str(root), "--script", str(script),
                          "--log-file", str(target / "engine.log")], root, target, target / "output.log", seconds)
        record = {"script": script.name, "group": rule["group"], **public_result(result),
                  **diagnose(result["output"], rule, result["exit_code"], result["timed_out"])}
        print(f"{'PASS' if record['passed'] else 'FAIL'} {script.name}" + (" (known shutdown debt)" if record["known_shutdown_debt"] else ""), flush=True)
        if not record["passed"]:
            print("\n".join(record["reasons"] + record["unexpected"]), flush=True)
        return record
    with ThreadPoolExecutor(max_workers=max(1, min(jobs, 4))) as pool:
        results = list(pool.map(run, selected))
    report = {"passed": sum(item["passed"] for item in results), "total": len(results),
              "known_shutdown_debt_checks": sum(bool(item["known_shutdown_debt"]) for item in results), "results": results}
    write_json(state / "checks.json", report)
    print(f"{report['passed']}/{report['total']} checks passed", flush=True)
    return report


def source_files(root: Path):
    resolved = root.resolve()
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(folder for folder in folders if folder not in OMIT
                            and not (Path(directory) / folder).is_symlink()
                            and not (Path(directory) / folder).is_junction()
                            and (Path(directory) / folder).resolve().is_relative_to(resolved))
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink() or not path.resolve().is_relative_to(resolved) or name.endswith((".pyc", ".tmp")) or name == ".experiment-context.json":
                continue
            yield path


def source_manifest(root: Path) -> dict:
    return {path.relative_to(root).as_posix(): {"sha256": digest(path), "bytes": path.stat().st_size} for path in source_files(root)}


def manifest_drift(before: dict, after: dict) -> list[str]:
    return sorted(name for name in set(before) | set(after) if before.get(name) != after.get(name))


def copy_source(root: Path, target: Path) -> dict:
    if target.exists():
        raise ValueError("Source copy target must be new; existing baseline is never removed.")
    target.mkdir(parents=True)
    manifest = {}
    for path in source_files(root):
        relative = path.relative_to(root)
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        if digest(path) != digest(destination):
            raise RuntimeError(f"Copy changed source bytes: {relative}")
        manifest[relative.as_posix()] = {"sha256": digest(destination), "bytes": destination.stat().st_size}
    return manifest


def history_check(root: Path) -> dict:
    frozen = read_json(root / "tools/historical_baseline.json")
    mismatches = [name for name, expected in frozen["files"].items() if not (root / name).is_file() or digest(root / name) != expected["sha256"]]
    return {"passed": not mismatches, "protected_files": len(frozen["files"]), "mismatches": mismatches,
            "historical_source_status": frozen["source_status"], "note": "Historical source SHA values are preserved, not rewritten to current code."}


def clean_check(root: Path, engine: Path, state: Path, args) -> dict:
    target = root / ".godot" / "clean-checks" / run_id()
    copied = target / "source"
    manifest = copy_source(root, copied)
    write_json(target / "source-manifest.json", {"source": str(root), "copy": str(copied), "files": manifest, "cache_present_before_import": (copied / ".godot").exists()})
    prepared = import_resources(copied, engine, target / "validation")
    report = checks(copied, engine, target / "validation", args.group, args.match, args.jobs, args.timeout) if prepared["passed"] else None
    history = history_check(root)
    # Concurrent teammates may intentionally edit the main tree. Report drift explicitly.
    changed = manifest_drift(manifest, source_manifest(root))
    result = {"passed": prepared["passed"] and report is not None and report["passed"] == report["total"] and history["passed"] and not changed,
              "copy": str(copied), "source_manifest": str(target / "source-manifest.json"), "import": prepared, "checks": report,
              "historical_integrity": history, "source_drift_during_validation": changed}
    write_json(target / "result.json", result)
    write_json(state / "clean-check.json", result)
    return result


def prepare_export_template(root: Path, state: Path, configured: str | None) -> dict:
    version = read_json(root / "tools/environment.json")["godot"] + ".stable"
    value = configured or os.environ.get("GODOT_EXPORT_TEMPLATES")
    if value:
        base = Path(value).expanduser().resolve()
    else:
        appdata = os.environ.get("APPDATA")
        if not appdata:
            raise ValueError("Specify --templates or GODOT_EXPORT_TEMPLATES for Windows export templates.")
        base = Path(appdata) / "Godot" / "export_templates"
    if base.name != version:
        base = base / version
    source = base / "windows_release_x86_64.exe"
    if not source.is_file():
        raise ValueError(f"Matching export template missing: {source}. Supply --templates <directory>.")
    destination = state / "appdata" / "Godot" / "export_templates" / version / source.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return {"source": str(source), "copy": str(destination), "sha256": digest(source), "bytes": source.stat().st_size}


def standalone_command(executable: Path, log: Path, headless: bool, gpu_backend: str = "default") -> list[str]:
    argv = [str(executable)]
    if headless:
        argv.append("--headless")
    argv += ["--log-file", str(log)]
    if not headless and gpu_backend == "gl_compatibility":
        argv += ["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"]
    # The application owns shutdown and drains its asynchronous audio work.
    # Engine --quit-after bypasses that lifecycle and is deliberately absent.
    return argv + ["--", "--smoke-quit-after-frames=120"]


def release(root: Path, engine: Path, state: Path, args, environment: dict) -> dict:
    contracts = tool_contracts(root, state)
    if not contracts["passed"]:
        raise RuntimeError("Tool failure-path checks failed; release stopped.")
    documentation = docs_check(root)
    if not documentation["passed"]:
        write_json(state / "docs-check.json", documentation)
        raise RuntimeError("Documentation links broken; release stopped.")
    prepared = import_resources(root, engine, state)
    if not prepared["passed"]:
        raise RuntimeError("Resource import failed; release stopped.")
    tested_sources = source_manifest(root)
    report = checks(root, engine, state, jobs=args.jobs)
    if report["passed"] != report["total"]:
        raise RuntimeError("Checks failed; release stopped.")
    drift = manifest_drift(tested_sources, source_manifest(root))
    if drift:
        write_json(state / "source-drift.json", {"phase": "checks", "changed_files": drift})
        raise RuntimeError("Source changed during checks; release stopped. See source-drift.json.")
    historical = history_check(root)
    if not historical["passed"]:
        raise RuntimeError("Frozen historical files changed; release stopped.")
    template = prepare_export_template(root, state, args.templates)
    output = root / "release" / "refactor" / run_id()
    output.mkdir(parents=True)
    executable = output / "Mycecard.exe"
    result = command([str(engine), "--headless", "--path", str(root), "--export-release", "Windows Desktop", str(executable),
                      "--log-file", str(state / "export-engine.log")], root, state, state / "export.log", 300)
    problems = re.findall(r"(?m)^(?:SCRIPT ERROR|ERROR|WARNING):.*$", result["output"])
    if result["exit_code"] or result["timed_out"] or problems or not executable.is_file():
        raise RuntimeError("Export failed: " + str(problems) + "; see " + result["log"])
    drift = manifest_drift(tested_sources, source_manifest(root))
    if drift:
        write_json(state / "source-drift.json", {"phase": "export", "changed_files": drift})
        raise RuntimeError("Source changed between checks and export; release stopped.")
    # Run from its own release directory, with no --path or source project argument.
    started = command(standalone_command(executable, output / "startup-engine.log", True),
                      output, state / "standalone", output / "startup.log", 60)
    startup_validation = diagnose(started["output"], {"completion": ORDERLY_SHUTDOWN_MARKER}, started["exit_code"], started["timed_out"])
    success = startup_validation["passed"]
    gpu_args = standalone_command(executable, output / "gpu-engine.log", False, args.gpu_backend)
    graphical = command(gpu_args, output, state / "gpu-standalone", output / "gpu-startup.log", 90)
    engine_log = output / "gpu-engine.log"
    gpu_text = graphical["output"] + ("\n" + engine_log.read_text(encoding="utf-8", errors="replace") if engine_log.exists() else "")
    gpu_problems = sorted(set(re.findall(r"(?m)^(?:SCRIPT ERROR|ERROR|WARNING):.*$", gpu_text)))
    renderer_lines = sorted(set(re.findall(r"(?m)^(?:OpenGL API|Vulkan |D3D12 |Direct3D |Metal ).*$", gpu_text)))
    gpu_validation = diagnose(gpu_text, {"completion": ORDERLY_SHUTDOWN_MARKER}, graphical["exit_code"], graphical["timed_out"])
    gpu_success = gpu_validation["passed"] and bool(renderer_lines)
    success = success and gpu_success
    drift = manifest_drift(tested_sources, source_manifest(root))
    success = success and not drift
    manifest = {"product": "Mycecard", "track": "architecture-refactor", "created_utc": datetime.now(timezone.utc).isoformat(),
                "passed": success, "environment": environment, "source_files": tested_sources, "source_drift_after_startup": drift, "checks": report, "tool_contracts": contracts, "documentation": documentation,
                "historical_integrity": historical, "export_template": template, "export": public_result(result), "standalone": {**public_result(started), **startup_validation},
                "gpu_standalone": {**public_result(graphical), "passed": gpu_success, "backend": args.gpu_backend, "renderer_lines": renderer_lines, "diagnostics": gpu_problems, "validation": gpu_validation},
                "standalone_diagnostics": startup_validation["unexpected"], "artifacts": {p.name: {"bytes": p.stat().st_size, "sha256": digest(p)} for p in output.iterdir() if p.suffix == ".exe"}}
    version_match = re.search(r'(?m)^config/version="([^"]+)"', (root / "project.godot").read_text(encoding="utf-8"))
    manifest["game_version"] = version_match.group(1) if version_match else None
    write_json(output / "manifest.json", manifest)
    write_json(state / "release.json", {"passed": success, "path": str(output), "manifest": str(output / "manifest.json")})
    return {"passed": success, "path": str(output), "manifest": str(output / "manifest.json")}


def experiment(root: Path, engine: Path, state: Path, args) -> dict:
    before = history_check(root)
    if not before["passed"]:
        raise RuntimeError("Frozen historical data failed integrity check.")
    target = root / ".godot" / "experiments" / run_id()
    copied = target / "source"
    manifest = copy_source(root, copied)
    write_json(target / "source-manifest.json", {"files": manifest})
    write_json(copied / ".experiment-context.json", {"kind": "isolated-experiment", "source": str(copied), "baseline": "phase5-conditions-current-code"})
    extra = {"MYCECARD_EXPERIMENT_SANDBOX": str(copied)}
    scenarios = {
        "models": [("python", "卡牌标准模型/重新评估.py"), ("python", "敌人标准模型/重新评估.py")],
        "combined": [("python", "卡牌标准模型/重新评估.py"), ("python", "敌人标准模型/重新评估.py"),
                     ("godot", "综合数值模型/运行战斗评估.gd"), ("python", "综合数值模型/生成综合评估.py")],
        "collections": [("python", "卡牌标准模型/重新评估.py"), ("python", "敌人标准模型/重新评估.py"),
                        ("godot", "综合数值模型/藏品实验/评估藏品.gd"), ("python", "综合数值模型/藏品实验/生成藏品评估.py")],
        "enemy-validation": [("python", "敌人标准模型/重新评估.py"), ("godot", "综合数值模型/新敌人实验/验证新敌人.gd"),
                             ("python", "综合数值模型/新敌人实验/生成新敌人评估.py")],
        "enemy-calibration": [("godot", "综合数值模型/新敌人实验/校准敌人.gd")],
        "boss-validation": [("python", "卡牌标准模型/重新评估.py"), ("python", "敌人标准模型/重新评估.py"),
                            ("godot", "综合数值模型/Boss实验/评估Boss.gd"), ("godot-validate", "综合数值模型/Boss实验/评估Boss.gd"),
                            ("python", "综合数值模型/Boss实验/生成Boss评估.py")],
    }
    results = []
    for index, (kind, script) in enumerate(scenarios[args.scenario]):
        argv = [sys.executable, str(copied / script)] if kind == "python" else [str(engine), "--headless", "--path", str(copied), "--script", "res://" + script]
        if kind == "godot-validate":
            argv += ["--", "validate"]
        if kind != "python" and not results:
            imported = import_resources(copied, engine, target / "validation")
            if not imported["passed"]:
                raise RuntimeError("Experiment resource import failed.")
        if kind != "python" and not (copied / ".godot").exists():
            imported = import_resources(copied, engine, target / "validation")
            if not imported["passed"]:
                raise RuntimeError("Experiment resource import failed.")
        executed = command(argv, copied, target / "validation", target / f"{index:02d}.log", 900, extra)
        problems = re.findall(r"(?m)^(?:SCRIPT ERROR|ERROR|WARNING):.*$", executed["output"])
        passed = executed["exit_code"] == 0 and not executed["timed_out"] and not problems
        results.append({"script": script, "passed": passed, **public_result(executed), "diagnostics": problems})
        print(f"{'PASS' if passed else 'FAIL'} experiment {script}", flush=True)
        if not passed:
            break
    after = history_check(root)
    generated = {}
    for folder in ["卡牌标准模型", "敌人标准模型", "综合数值模型"]:
        for path in (copied / folder).rglob("*"):
            if path.is_file() and path.suffix in {".json", ".md", ".png"}:
                relative = path.relative_to(copied).as_posix()
                sha = digest(path)
                if relative not in manifest or manifest[relative]["sha256"] != sha:
                    generated[relative] = {"sha256": sha, "bytes": path.stat().st_size}
    result = {"passed": all(row["passed"] for row in results) and after["passed"], "scenario": args.scenario,
              "source": str(copied), "historical_integrity": after, "conditions": "phase5-conditions-current-code",
              "created_utc": datetime.now(timezone.utc).isoformat(),
              "note": "New isolated outputs use current code; they do not reproduce missing historical source bytes. Enemy validation retains historical selected training parameters; calibration is a separate command and never applies values to formal resources.", "results": results, "generated_outputs": generated}
    write_json(target / "experiment-manifest.json", result)
    write_json(state / "experiment.json", result)
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["doctor", "import", "test", "tool-test", "docs-check", "release", "clean-check", "history-check", "experiment"])
    parser.add_argument("--godot")
    parser.add_argument("--templates", help="Godot export_templates directory or its 4.6.1.stable child; copied into isolated APPDATA")
    parser.add_argument("--gpu-backend", choices=["default", "gl_compatibility"], default="default", help="Independent graphical release smoke-test backend; recorded in manifest")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--group", choices=["all", *GROUP_TIMEOUTS], default="all")
    parser.add_argument("--match", help="Regex selecting registered filenames; zero matches is an error")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--no-import", action="store_true", help="Only for an already imported working tree")
    parser.add_argument("--optional", choices=["audio", "plots"])
    parser.add_argument("--scenario", choices=["models", "combined", "collections", "enemy-validation", "enemy-calibration", "boss-validation"], default="models")
    args = parser.parse_args(argv)
    state = PROJECT / ".godot" / "tools" / run_id()
    state.mkdir(parents=True)
    try:
        if args.timeout is not None and args.timeout <= 0:
            raise ValueError("Timeout must be positive.")
        if args.action == "history-check":
            result = history_check(PROJECT)
        elif args.action == "tool-test":
            result = tool_contracts(PROJECT, state)
        elif args.action == "docs-check":
            result = docs_check(PROJECT)
        else:
            engine = engine_path(args)
            environment = doctor(PROJECT, engine, state, args.optional)
            if not environment["passed"]:
                raise RuntimeError("Environment differs from the fixed toolchain; see environment.json.")
            if args.action == "doctor":
                result = environment
            elif args.action == "import":
                result = import_resources(PROJECT, engine, state)
            elif args.action == "test":
                if not tool_contracts(PROJECT, state)["passed"]:
                    raise RuntimeError("Tool failure-path checks failed; checks stopped.")
                if not args.no_import and not import_resources(PROJECT, engine, state)["passed"]:
                    raise RuntimeError("Resource import failed; checks stopped.")
                report = checks(PROJECT, engine, state, args.group, args.match, args.jobs, args.timeout)
                result = {"passed": report["passed"] == report["total"], **{"checks": report}}
            elif args.action == "clean-check":
                result = clean_check(PROJECT, engine, state, args)
            elif args.action == "release":
                result = release(PROJECT, engine, state, args, environment)
            else:
                result = experiment(PROJECT, engine, state, args)
        write_json(state / "result.json", result)
        print(json.dumps({"passed": result["passed"], "report": str(state / "result.json")}, ensure_ascii=False), flush=True)
        return 0 if result["passed"] else 1
    except (OSError, RuntimeError, ValueError, KeyError, re.error) as error:
        write_json(state / "result.json", {"passed": False, "error": str(error)})
        print(f"FAIL: {error}\nReport: {state / 'result.json'}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
