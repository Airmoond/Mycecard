## Historical numeric outputs may only be written in an explicit isolated source copy.
extends RefCounted

static func require_sandbox() -> bool:
	var project: String = ProjectSettings.globalize_path("res://").trim_suffix("/").replace("\\", "/")
	var configured: String = OS.get_environment("MYCECARD_EXPERIMENT_SANDBOX").replace("\\", "/").trim_suffix("/")
	var marker: String = "res://.experiment-context.json"
	if configured.is_empty() or configured.to_lower() != project.to_lower() or not FileAccess.file_exists(marker):
		printerr("历史结果已冻结。请使用 python tools/project.py experiment --scenario ... 在独立副本复算。")
		return false
	var context: Variant = JSON.parse_string(FileAccess.get_file_as_string(marker))
	if not context is Dictionary or context.get("kind", "") != "isolated-experiment":
		printerr("实验副本标记无效；拒绝写入历史结果。")
		return false
	if str(context.get("source", "")).replace("\\", "/").to_lower() != project.to_lower():
		return false
	if project.get_file() != "source" or project.get_base_dir().get_base_dir().get_file() != "experiments" or project.get_base_dir().get_base_dir().get_base_dir().get_file() != ".godot":
		printerr("实验仅允许在工具创建的 .godot/experiments/<run>/source 目录运行。")
		return false
	return true
