"""Prevent legacy evaluation commands from overwriting retained historical results."""
from pathlib import Path
import json
import os


def require_sandbox(project: Path) -> None:
    project = project.resolve()
    configured = os.environ.get("MYCECARD_EXPERIMENT_SANDBOX", "")
    marker = project / ".experiment-context.json"
    if not configured or Path(configured).resolve() != project or not marker.is_file():
        raise RuntimeError("历史结果已冻结。请使用 python tools/project.py experiment --scenario ... 在独立副本复算。")
    context = json.loads(marker.read_text(encoding="utf-8"))
    if context.get("kind") != "isolated-experiment" or Path(context.get("source", "")).resolve() != project:
        raise RuntimeError("实验副本标记无效；拒绝写入历史结果。")
    if project.name != "source" or project.parent.parent.name != "experiments" or project.parent.parent.parent.name != ".godot":
        raise RuntimeError("实验仅允许在工具创建的 .godot/experiments/<run>/source 目录运行。")
