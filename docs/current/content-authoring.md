# 内容配置与编辑

内容由 `.tres` 资源配置，运行时保持只读。服务与状态职责见 [项目架构](../architecture/架构与重构记录.md)。

## 初始牌组与奖励

编辑 `characters/data/warrior.tres`：

- `starting_deck_entries` 决定初始牌组的卡牌及数量。
- `reward_card_pool` 保存角色卡池；普通战斗奖励会从中排除传说卡，再抽取候选。

编辑 `run/data/default_run.tres`：

- `character_definition` 选择本局使用的角色配置。
- `reward_option_count` 决定每轮展示几张不同卡牌，不能超过非传说奖励池大小。
- `reward_selection_count` 决定普通战斗胜利后连续选择几次。
- `unexpected_encounter_pool` 配置不期而遇实例池，地图按路线独立抽取并允许重复。

默认资源使用 3 个奖励选项，并显式配置 `reward_selection_count = 1`。战士基础牌组已设为 3 打击＋3 防御。开局展示每组全部候选，只需每组至少一张；普通奖励仍需至少三个非传说候选。

## 开局界面

- `run/draft/starting_draft_view.tscn`：顶部横条、左中展示框、三列网格、分页按钮和右侧滚动牌组栏。可直接调整容器间距、边距、字体与面板样式。
- `run/draft/deck_card_row.tscn`：每张牌的名称横条样式，同名牌逐条显示。
- 选牌交互使用 `ui/cards/card_choice_view.tscn`，视觉卡面与手牌共同引用 `cards/card_face.tscn`。每页最多 6 张由 `StartingDraftView.CARDS_PER_PAGE` 指定；分页和加牌职责独立，调整外观不需要修改 `RunState`。

## 卡牌伤害文案

卡牌 `description` 中使用 `{damage_效果下标}` 表示该效果的单段伤害，下标从 0 开始，按整个 `effects` 数组编号。例如：

- 打击：`造成{damage_0}点伤害`，对应 `effects[0]` 的伤害。
- 防守反击：`获得3点格挡，然后造成{damage_1}点伤害`，因为 `effects[0]` 是格挡，伤害在 `effects[1]`。
- 双重打击：`造成{damage_0}点伤害2次。`，占位符显示每一段的伤害，次数仍由文案表达。

战斗中填入力量、虚弱和易伤修正后的数值，奖励页填入固定基础数值。按格挡伤害在战斗外显示 `X`，例如 `造成{damage_0}点伤害，基础伤害等于当前格挡。`；战斗内填入实际预览数值。调整效果顺序时同步调整占位符下标；没有占位符的文字不会自动改写。此预览表达格挡前伤害，不预测实际失血或死亡中断，也不把修正值保存回资源。

## 地图

编辑 `run/map/data/first_map.tres`：

- `nodes` 保存全部节点定义。
- `starting_node_ids` 决定新局最先解锁的节点。
- `map_position` 决定节点在地图页面中的显示坐标。
- `next_node_ids` 决定完成节点后解锁哪些后继节点。
- 静态战斗配置可通过 `encounter_definition` 指定遭遇；默认分支地图使用整局随机池和本局绑定。
- 默认三条路线各三个位置的类型由本局随机排列决定；`route_*_rest`是兼容ID，不再代表固定休整。
- 线性测试地图的休整节点通过 `heal_amount` 决定恢复量；不期而遇数值编辑 `run/encounter/data/` 对应资源。

## 单场规则

编辑 `battle/data/encounters/` 中的遭遇资源：

- `enemy_definition` 选择敌人。
- `energy_per_turn`、`cards_per_turn`、`max_hand_size` 调整单场规则。
- 未在 `.tres` 中显式写出的字段使用 `EncounterDefinition` 脚本默认值。

## 新增不期而遇

复制 [余烬营地](../../run/encounter/data/ember_camp.tres)、[血契祭坛](../../run/encounter/data/blood_pact_altar.tres) 或 [遗忘之泉](../../run/encounter/data/forgetting_spring.tres) 作为模板，在Godot检查器编辑：

1. 使用唯一 `encounter_id`，填写名称、故事、插画。
2. 编辑 `options` 内的 UnexpectedEncounterOptionDefinition 子资源；每项使用唯一 `option_id`，填写 `label` 和 `result_text`。必须保留一个 LEAVE 操作。
3. `operation` 支持 LEAVE、HEAL、GAIN_CARD、REMOVE_CARD。HEAL填写正数 `heal_amount`；GAIN_CARD填写稀有度、排除卡ID与三张候选，`health_cost` 可设为零或正数；REMOVE_CARD选择实际牌组条目并至少留一张。费用只在确认选牌时和收益一起提交，且支付后生命必须大于零。
4. 结果模板使用 `{actual_heal}`、`{health_cost}`、`{card_name}` 等实际结果字段，不在显示文字中预先假定满额治疗。
5. 将实例加入 [default_run.tres](../../run/data/default_run.tres) 的 `unexpected_encounter_pool`，核对角色卡池能满足各选牌选项。

复用这四种操作不需要修改视图或流程控制器。新操作应扩展 [选项定义](../../run/encounter/unexpected_encounter_option_definition.gd) 与 [执行器](../../run/encounter/unexpected_encounter_executor.gd)，由RunSession提交。旧 `kind`、实例级 `heal_amount`／`health_cost` 是兼容元数据，生产行为以 `options` 配置为准。

候选保存在本局状态中；翻页、取消和重建页面不重新抽取。单局内容随机与战斗抽牌分流，指定流程控制器 `run_seed` 并使用相同配置可重现问题。

## 测试新增内容

运行 `python tools/project.py test --group flow` 验证候选、地图和状态推进。规则行为可直接创建 RunSession／BattleSession 测试；布局、长文字或原画改动还需在 GPU 环境检查，入口见 [界面编辑](./ui-editing.md)。
