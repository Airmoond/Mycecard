extends GdUnitTestSuite


# Fixture Factory：创建一个已经启动的真实战斗会话
func create_battle_session() -> BattleSession:
	# 加载真实业务资源
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

	# 创建独立的战斗会话
	var session: BattleSession = BattleSession.new()

	# 固定随机种子
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 12345

	session.configure_context("test-battle", "test-node", rng)

	# 启动真实战斗
	var started: bool = session.start_battle(
		encounter,
		player,
		deck,
		50,
		50
	)

	assert_bool(started).is_true()

	return session


# 测试1：正常出牌
func test_play_strike_card() -> void:
	# Arrange
	var session: BattleSession = create_battle_session()
	var state: BattleState = session.battle_state

	assert_int(state.hand.size()).is_equal(1)

	var card: CardInstance = state.hand[0]

	var energy_before: int = state.current_available_energy
	var enemy_hp_before: int = state.enemy_state.current_health

	# Act
	var accepted: bool = session.play_card(card)

	# Assert
	assert_bool(accepted).is_true()

	# 能量减少1点
	assert_int(state.current_available_energy).is_equal(
		energy_before - 1
	)

	# 敌人受到6点伤害
	assert_int(state.enemy_state.current_health).is_equal(
		enemy_hp_before - 6
	)

	# 卡牌从手牌移动到弃牌堆
	assert_bool(state.hand.has(card)).is_false()
	assert_bool(state.discard_pile.has(card)).is_true()

	# 验证战斗状态合法
	assert_bool(state.is_invalid_battle()).is_false()

	session.dispose()


# 测试2：能量不足时拒绝出牌
func test_play_card_without_enough_energy() -> void:
	# Arrange
	var session: BattleSession = create_battle_session()
	var state: BattleState = session.battle_state
	var card: CardInstance = state.hand[0]

	# 人为制造能量不足
	state.current_available_energy = 0

	# 保存操作前状态
	var energy_before: int = state.current_available_energy
	var enemy_hp_before: int = state.enemy_state.current_health
	var hand_before: Array[CardInstance] = state.hand.duplicate()
	var discard_count_before: int = state.discard_pile.size()

	# Act
	var accepted: bool = session.play_card(card)

	# Assert
	assert_bool(accepted).is_false()

	# 验证拒绝原因
	assert_str(
		str(session.card_play_failure(card))
	).is_equal("not_enough_energy")

	# 验证没有任何业务副作用
	assert_int(state.current_available_energy).is_equal(energy_before)
	assert_int(state.enemy_state.current_health).is_equal(enemy_hp_before)
	assert_array(state.hand).is_equal(hand_before)
	assert_int(state.discard_pile.size()).is_equal(discard_count_before)

	assert_bool(state.hand.has(card)).is_true()
	assert_bool(state.is_invalid_battle()).is_false()

	session.dispose()
	
func test_cannot_play_card_before_battle_started() -> void:
	# Arrange
	var unstarted_session: BattleSession = BattleSession.new()

	# Act
	var accepted: bool = unstarted_session.play_card(null)

	# Assert
	assert_bool(accepted).is_false()
	assert_str(
		str(unstarted_session.player_operation_failure())
	).is_equal("not_started")

	assert_object(unstarted_session.battle_state).is_null()

	unstarted_session.dispose()
	
# 测试4：战斗胜利后禁止再次出牌
func test_cannot_play_card_after_victory() -> void:
	# Arrange：创建真实战斗
	var session: BattleSession = create_battle_session()
	var state: BattleState = session.battle_state
	var card: CardInstance = state.hand[0]

	# 设置敌人剩余1点生命
	assert_bool(
		state.enemy_state.set_current_health(1)
	).is_true()

	# Act 1：通过真实出牌流程击杀敌人
	var first_accepted: bool = session.play_card(card)

	# Assert 1：验证战斗胜利
	assert_bool(first_accepted).is_true()
	assert_int(state.enemy_state.current_health).is_equal(0)

	assert_int(state.current_phase).is_equal(
		BattleState.BattlePhase.FINISHED
	)

	var result: BattleResult = session.get_result()
	assert_object(result).is_not_null()
	assert_bool(result.victory).is_true()

	# 保存胜利后的状态快照
	var energy_before: int = state.current_available_energy
	var enemy_hp_before: int = state.enemy_state.current_health
	var hand_before: Array[CardInstance] = state.hand.duplicate()
	var discard_before: Array[CardInstance] = state.discard_pile.duplicate()

	# Act 2：战斗结束后再次尝试出牌
	var second_accepted: bool = session.play_card(card)

	# Assert 2：操作必须被拒绝
	assert_bool(second_accepted).is_false()

	assert_str(
		str(session.player_operation_failure())
	).is_equal("finished")

	# Assert 3：战斗结束状态不能被改变
	assert_int(state.current_phase).is_equal(
		BattleState.BattlePhase.FINISHED
	)

	# Assert 4：非法操作不得修改业务数据
	assert_int(state.current_available_energy).is_equal(energy_before)
	assert_int(state.enemy_state.current_health).is_equal(enemy_hp_before)
	assert_array(state.hand).is_equal(hand_before)
	assert_array(state.discard_pile).is_equal(discard_before)

	# Assert 5：战斗结果保持不变
	assert_object(session.get_result()).is_same(result)

	assert_bool(state.is_invalid_battle()).is_false()

	session.dispose()
	
# 测试5：战斗胜利信号只发送一次
func test_battle_finished_signal_emitted_once() -> void:
	# Arrange：创建真实战斗
	var session: BattleSession = create_battle_session()
	var state: BattleState = session.battle_state
	var card: CardInstance = state.hand[0]

	# 用于记录信号发送情况
	var received: Dictionary = {
		"count": 0,
		"result": null
	}

	# 监听战斗结束信号
	session.battle_finished.connect(
		func(result: BattleResult) -> void:
			received["count"] += 1
			received["result"] = result
	)

	# 准备真实的胜利条件
	assert_bool(
		state.enemy_state.set_current_health(1)
	).is_true()

	# Act 1：击败敌人
	var accepted: bool = session.play_card(card)

	# Assert 1：操作成功，信号发送一次
	assert_bool(accepted).is_true()
	assert_int(received["count"]).is_equal(1)

	# Assert 2：信号携带的结果正确
	var result: BattleResult = received["result"]
	assert_object(result).is_not_null()
	assert_bool(result.victory).is_true()
	assert_str(result.battle_id).is_equal("test-battle")
	assert_int(result.player_health).is_equal(
		state.player_state.current_health
	)

	# Assert 3：信号传递的是实际战斗结果
	assert_object(result).is_same(session.get_result())

	# Act 2：重复检查战斗结果
	session.check_battle_result()

	# Assert 4：不允许重复发送结束信号
	assert_int(received["count"]).is_equal(1)

	session.dispose()
