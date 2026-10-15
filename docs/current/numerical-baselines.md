# 数值模型与实验

| 模型 | 用途 |
| --- | --- |
| [卡牌标准模型](../../卡牌标准模型/README.md) | 卡牌效果的估值与比较 |
| [敌人标准模型](../../敌人标准模型/README.md) | 敌人行动与生命参数的参考模型 |
| [综合数值模型](../../综合数值模型/README.md) | 真实战斗、路线、藏品和敌人实验 |

## 运行实验

配置 [开发环境](./environment.md) 后，从项目根目录执行：

```powershell
python tools/project.py history-check
python tools/project.py experiment --scenario models
python tools/project.py experiment --scenario combined
python tools/project.py experiment --scenario collections
python tools/project.py experiment --scenario enemy-validation
python tools/project.py experiment --scenario boss-validation
```

工具创建 `.godot/experiments/<run>/source` 独立副本，记录输入文件指纹、配置和输出。模型脚本在写结果前校验隔离标记，复算仅修改副本。主树中保留的结果由 [historical_baseline.json](../../tools/historical_baseline.json) 校验。

## 条件与来源

主路线和藏品实验使用 [phase5_run.tres](../../tests/fixtures/phase5_run.tres) 与 [phase5_map.tres](../../tests/fixtures/phase5_map.tres)：两场普通战斗、休整、Boss，以及固定奖励策略。输出条件标记为 `phase5-conditions-current-code`，表示当前战斗实现运行这组固定条件。

这些条件与当前随机不期而遇地图不同。评估现有冒险数值时，需要另外明确路线、奖励跳过、加删卡和不期而遇选择策略，并保存独立结果。流程测试与数值评估分别覆盖状态正确性和策略表现。

历史数据中的来源 SHA 对应各次生成时的输入，保留原值。当前源码与旧来源不匹配的情况记录在冻结清单中；重新运行生成新的来源记录。参数日期表示配置登记时间，实际运行时间以实验 manifest 为准。

## 敌人参数搜索

`enemy-validation` 验证已配置的敌人资源，训练指标读取所保留的参数选择。需要搜索参数时单独执行：

```powershell
python tools/project.py experiment --scenario enemy-calibration
```

参数搜索和独立验证使用分开的种子与样本。候选写入实验副本，由维护者比较后再决定是否更新游戏资源。结果生成器检查来源指纹、样本和账目，实验前后还会核对主树历史文件。
