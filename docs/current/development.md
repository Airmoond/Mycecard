# 开发指南

在 Godot 4.6.1 中打开 [project.godot](../../project.godot)，按 F5 运行主游戏；打开独立场景后按 F6 运行该场景。工具链配置见 [开发环境](./environment.md)。以下命令均从项目根目录执行，使用 `GODOT_BIN`，也可添加 `--godot` 指定控制台程序。

## 日常开发

```powershell
python tools/project.py doctor
python tools/project.py import
python tools/project.py test
```

[project.py](../../tools/project.py) 统一处理资源导入、测试、构建和数值实验。`test` 会导入资源、检查工具行为并运行全部已登记的 Godot 测试。[tests/run_all.py](../../tests/run_all.py) 提供同一测试入口。

## 测试

```powershell
python tools/project.py test --group flow
python tools/project.py test --match battle_session
python tools/project.py test --group heavy --timeout 360
python tools/project.py tool-test
python tools/project.py docs-check
```

| 分组 | 主要范围 | 默认超时 |
| --- | --- | ---: |
| unit | 战斗规则与局部模型 | 90秒 |
| flow | 整局状态、页面路由与生命周期 | 180秒 |
| presentation | 卡面、布局与视图 | 180秒 |
| audio | 音频与表现反馈 | 180秒 |
| heavy | 多场战斗与试炼 | 360秒 |
| playtest | 完整整局流程 | 360秒 |

单项超时可在 [checks.json](../../tools/checks.json) 中配置，`--timeout` 可覆盖本次运行的上限。`--jobs` 默认2，最多4；`--match` 按文件名正则筛选。已完成资源导入的工作目录可使用 `--no-import`。

新增测试需登记分组、成功标记及预期错误。测试工具将非零退出、超时、缺少成功标记、未声明的 SCRIPT ERROR／ERROR／WARNING 判为失败；负向用例按完整错误文字和次数匹配。零匹配、漏登记和丢失的测试文件也会失败。每次运行的命令、耗时、退出码和日志保存在 `.godot/tools/` 的独立目录。

## 干净源验证与 Windows 构建

```powershell
python tools/project.py clean-check
python tools/project.py release
```

`clean-check` 创建不含导入缓存、Git 元数据、发布产物和虚拟环境的源副本，核对文件指纹，从零导入并运行测试。验证期间主树发生增删改会导致检查失败。

`release` 检查工具、资源、测试和数值历史文件后，导出到 `release/refactor/<run>/Mycecard.exe`。构建目录中的 `manifest.json` 记录源码清单、工具与模板版本、产物 SHA、测试结果及独立启动结果；构建期间的源码变化会中止交付。

发布程序从输出目录分别以 headless 和项目默认 GPU 后端启动。需要兼容渲染时可显式指定 `--gpu-backend gl_compatibility`，实际后端和设备写入 manifest。启动检查通过应用参数 `-- --smoke-quit-after-frames=120` 运行120帧，再调用正常退出接口；要求退出码0、完成标记完整且无意外诊断。窗口关闭与启动检查共用音频清理流程，详见 [项目架构](../architecture/架构与重构记录.md)。

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
