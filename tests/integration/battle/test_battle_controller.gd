extends GdUnitTestSuite


func test_battle_scene_initialization() -> void:
	# Arrange：加载真实战斗场景
	var runner := scene_runner("res://battle/battle.tscn")

	# 获取 BattleView
	var view: BattleView = runner.scene() as BattleView
	assert_object(view).is_not_null()

	# 获取真实 BattleController 节点
	var controller: BattleController = view.get_node(
		"battle_controller"
	) as BattleController

	# Assert：验证控制器初始化
	assert_object(controller).is_not_null()
	assert_object(controller.presentation).is_not_null()

	# 尚未启动战斗，不应存在会话
	assert_object(controller.session).is_null()
	
# 测试2：View 发出出牌信号后，Controller 正确执行出牌
func test_card_selected_triggers_battle_action() -> void:
	# Arrange：运行真实战斗场景
	var runner := scene_runner("res://battle/battle.tscn")
	var view: BattleView = runner.scene() as BattleView
	var controller: BattleController = view.get_controller()

	# 加载真实资源
	var encounter: EncounterDefinition = load(
		"res://battle/encounters/data/cave_crawler_encounter.tres"
	)
	var player: CombatantDefinition = load(
		"res://combatants/players/data/player.tres"
	)
	var strike: CardDefinition = load(
		"res://cards/data/strike.tres"
	)

	var deck: Array[CardDefinition] = [strike]

	# 固定随机性
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	controller.configure_context("test-battle", "test-node", rng)

	# 启动战斗
	assert_bool(
		controller.start_battle(encounter, player, deck, 50, 50)
	).is_true()

	var state: BattleState = controller.battle_state
	assert_int(state.hand.size()).is_equal(1)

	var card: CardInstance = state.hand[0]

	var energy_before: int = state.current_available_energy
	var hp_before: int = state.enemy_state.current_health

	# Act：模拟 BattleView 发送出牌意图
	view.card_selected.emit(card)

	# Assert：验证真实战斗数据发生变化
	assert_int(state.current_available_energy).is_equal(
		energy_before - 1
	)

	assert_int(state.enemy_state.current_health).is_equal(
		hp_before - 6
	)

	assert_bool(state.hand.has(card)).is_false()
	assert_bool(state.discard_pile.has(card)).is_true()

	# 验证 UI 已同步更新
	assert_str(view.energy_label.text).is_equal(
		"能量：%d / %d" % [
			state.current_available_energy,
			state.energy_per_turn
		]
	)

	assert_bool(state.is_invalid_battle()).is_false()
