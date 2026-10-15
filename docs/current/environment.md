# 开发环境

| 用途 | 版本 |
| --- | --- |
| 编辑器、测试与 Windows 导出 | Godot 4.6.1 官方稳定版，Windows x86_64 控制台程序 |
| 工程工具 | Python 3.12.7 |
| Windows 导出模板 | Godot 4.6.1 对应的官方模板 |

版本配置见 [environment.json](../../tools/environment.json)。工程工具使用 Python 标准库，并在运行前核对版本。

## 配置 Godot

将 Godot 控制台程序所在目录加入 PATH。在包含 `project.godot` 的项目根目录运行：

```powershell
$env:GODOT_BIN = (Get-Command Godot_v4.6.1-stable_win64_console.exe).Source
python tools/project.py doctor
```

也可使用 `--godot` 指定控制台程序路径。Windows 构建默认从 APPDATA 下的 Godot 目录查找导出模板；通过 `--templates` 或 `GODOT_EXPORT_TEMPLATES` 可指定模板目录。工具将选中的发布模板复制到本次进程的独立环境，并记录模板指纹。

## 可选制作依赖

游戏运行和常规开发使用仓库中的现成媒体。重新制作音频时安装 [requirements-audio.txt](../../tools/requirements-audio.txt)，并将 FFmpeg 加入 PATH，或通过 `PHASE6_FFMPEG` 指定程序：

```powershell
python -m pip install -r tools/requirements-audio.txt
python tools/project.py doctor --optional audio
```

音频依赖为 NumPy 1.26.4、SciPy 1.13.1；现有编码器参考版本为 FFmpeg 3.0.1。更换编码器后需重新检查波形、峰值和循环接缝。

数值绘图使用 [requirements-plots.txt](../../tools/requirements-plots.txt) 中的 Matplotlib 3.9.2：

```powershell
python -m pip install -r tools/requirements-plots.txt
python tools/project.py doctor --optional plots
```

绘图脚本默认使用 Windows 微软雅黑字体；其他环境需配置可用的中文字体。建议在项目 `.venv` 中安装可选依赖。

## 进程环境

工具为每次任务创建独立的 APPDATA、LOCALAPPDATA、TEMP 和 TMP，数据位于项目 `.godot` 目录下。Windows 子进程隐藏启动。这些设置仅作用于本次子进程。
