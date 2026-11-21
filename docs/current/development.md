# 开发指南

在 Godot 4.6.1 中打开 [project.godot](../../project.godot)，按 F5 运行主游戏；打开独立场景后按 F6 运行该场景。工具链配置见 [开发环境](./environment.md)。以下命令均从项目根目录执行，使用 `GODOT_BIN`，也可添加 `--godot` 指定控制台程序。

## 日常开发

```powershell
python tools/project.py doctor
python tools/project.py import
python tools/project.py docs-check
```

[project.py](../../tools/project.py) 提供资源导入、文档检查、构建和数值实验入口。

## 干净源验证与 Windows 构建

```powershell
python tools/project.py clean-check
python tools/project.py release
```

`clean-check` 创建干净的源码副本，从零导入 Godot 资源，校验冻结的数值历史文件，并检测验证期间主树的文件变化。报告和日志保存在 `.godot/` 下的独立目录。

`release` 检查文档链接、资源导入和数值历史文件，导出到 `release/refactor/<run>/Mycecard.exe`。构建清单记录源码和产物指纹、工具和模板版本，以及从发布目录执行的两次启动检查。

发布启动检查分别以无头模式和默认 GPU 后端运行程序，通过应用参数 `-- --smoke-quit-after-frames=120` 走正常退出流程。两次检查都要求退出码为零、日志出现正常退出标记，并且没有错误或警告。GPU 检查还要求记录渲染后端。可用 `--gpu-backend gl_compatibility` 指定兼容后端。

GdUnit4 套件尚未接入。干净源验证和发布报告的 `automated_tests` 字段显示“测试未接入”。报告的 `passed` 字段对应实际运行的工程检查。

界面改动还需在实际图形环境检查绘制和输入，音频改动需检查实际混音与播放。尺寸要求和编辑入口见 [界面编辑](./ui-editing.md)。

## 数值实验

```powershell
python tools/project.py history-check
python tools/project.py experiment --scenario models
python tools/project.py experiment --scenario combined
python tools/project.py experiment --scenario collections
python tools/project.py experiment --scenario enemy-validation
python tools/project.py experiment --scenario boss-validation
```

实验使用独立源副本，结果写入 `.godot/experiments/`。`enemy-calibration` 用于单独搜索敌人参数；验证和参数搜索使用分开的入口。条件与来源记录见 [数值模型](./numerical-baselines.md)。

## 代码约定

静态内容资源在运行时只读；规则模型处理状态，视图发送操作意图，流程层编排页面。共用卡面、选牌和主题组件位于 `ui/` 与 `cards/`。调整资源位置或名称时，同步检查静态引用、动态加载路径、UID 和相关测试。
