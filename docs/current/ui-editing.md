# 界面编辑

固定布局、标题和提示优先在 Godot 场景编辑器修改 `.tscn`；动态状态文字在相应 View 脚本绑定；公共颜色、字体、按钮和面板编辑 [fantasy_theme.tres](../../ui/themes/fantasy_theme.tres)。脚本主题辅助函数直接使用该共享资源。

| 需要修改 | 布局／固定文字入口 | 动态显示／交互入口 |
| --- | --- | --- |
| 开始界面的标题、按钮、说明、背景布局 | [main_menu.tscn](../../run/screens/main_menu.tscn) | [main_menu.gd](../../run/screens/main_menu.gd) |
| 地图顶部、底部固定提示与背景布局 | [map_view.tscn](../../run/map/map_view.tscn) | [map_view.gd](../../run/map/map_view.gd)：生命、牌组数、节点进度 |
| 地图节点卡片样式 | [map_node_view.tscn](../../run/map/map_node_view.tscn) | [map_node_view.gd](../../run/map/map_node_view.gd)：类型、名称、解锁状态 |
| 地图节点位置与连接 | [first_map.tres](../../run/map/data/first_map.tres) | RunSession 新局绑定类型与实例 |
| 战斗界面、角色区、能量与牌堆按钮、结束回合 | [battle.tscn](../../battle/battle.tscn) | [BattleView](../../battle/view/battle_view.gd)：1920×1080设计画布尺寸适配与状态绑定 |
| 手牌排列与输入区域 | 战斗场景的 hand_area | [HandView](../../battle/view/hand_view.gd)：按 CardInstance 维护与排列 |
| 卡面边框、原画位置、标题和描述区 | [card_face.tscn](../../cards/card_face.tscn) | [CardFace](../../cards/card_face.gd)：稀有度、内容、尺寸缩放 |
| 手牌点击与悬停 | [card_view.tscn](../../cards/card_view.tscn) | [CardView](../../cards/card_view.gd) |
| 构筑、奖励、不期而遇的共用选择卡 | [card_choice_view.tscn](../../ui/cards/card_choice_view.tscn) | [CardChoiceView](../../ui/cards/card_choice_view.gd) |
| 开局构筑布局、分页、右侧牌组 | [starting_draft_view.tscn](../../run/draft/starting_draft_view.tscn)、[deck_card_row.tscn](../../run/draft/deck_card_row.tscn) | [starting_draft_view.gd](../../run/draft/starting_draft_view.gd) |
| 开局藏品三选一 | [collection_choice_view.tscn](../../run/collection/collection_choice_view.tscn) | [collection_choice_view.gd](../../run/collection/collection_choice_view.gd) |
| 普通战斗奖励、跳过按钮 | [reward_view.tscn](../../run/reward/reward_view.tscn) | [reward_view.gd](../../run/reward/reward_view.gd) |
| 不期而遇标题区、插画区、故事区与选项区 | [unexpected_encounter_view.tscn](../../run/encounter/unexpected_encounter_view.tscn) | [unexpected_encounter_view.gd](../../run/encounter/unexpected_encounter_view.gd)：读取统一选项查询、候选分页和结果模板 |
| 不期而遇故事、选项、效果与插画引用 | [encounter/data](../../run/encounter/data/) 中的实例 `.tres` | [内容新增说明](./content-authoring.md) |
| 胜败结算 | [run_result.tscn](../../run/screens/run_result.tscn) | [run_result.gd](../../run/screens/run_result.gd) |
| 声音设置按钮、滑条、静音与返回 | [audio_settings.tscn](../../ui/audio_settings.tscn) | [AudioSettings](../../ui/audio_settings.gd) |
| 页面加载失败提示与恢复按钮 | [navigation_error.tscn](../../ui/navigation/navigation_error.tscn) | [NavigationError](../../ui/navigation/navigation_error.gd) |
| 卡牌、武器及藏品查看窗口 | [card_inspector.tscn](../../ui/inspect/card_inspector.tscn)、[collection_inspector.tscn](../../ui/inspect/collection_inspector.tscn) | 同目录脚本，仅展示实际数据 |

地图底部提示位于 `map_view.tscn` 的 `route_hint` 标签，分支地图直接使用场景文字。线性测试地图由脚本填入“选择下一处可进入的地图节点”。开始界面由 `run/screens/main_menu.tscn` 控制，`main.tscn` 是应用装配入口。

卡面缩放按场景中的矩形、字号和装饰位置计算。公共主题提供 TitleLabel、HeadingLabel、StoryLabel、StatusLabel、ProminentButton、SmallIconButton 等控件样式，页面可保留局部排版设置。

动画修改 [BattlePresentation](../../battle/presentation/battle_presentation.gd)，音量与混音修改 [GameAudioManager](../../audio/audio_manager.gd)，原始音效／BGM位于 [audio](../../audio/)。规则数值修改 `.tres` 或规则模块，不通过动画和显示文本修改。

应用装配与窗口关闭入口为 [AppRoot](../../ui/app_root.gd)。关闭应用时统一调用正常退出接口，禁用界面输入、停止音频并等待播放实例释放。相关测试见 [app_shutdown_test.gd](../../tests/app_shutdown_test.gd)。

界面检查覆盖1920×1080、1280×720和1024×600，核对原画、固定文字、长描述、分页和最上层窗口。布局测试之后，还需在实际 GPU 环境检查绘制、鼠标命中和 Esc 关闭顺序。
