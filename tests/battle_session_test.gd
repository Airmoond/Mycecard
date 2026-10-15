## 直接使用RefCounted会话验证真实结算、查询、反馈、随机隔离与准备/激活。
extends SceneTree

var _failures:int = 0
var _encounter:EncounterDefinition = load("res://battle/data/encounters/cave_crawler_encounter.tres")
var _player:CombatantDefinition = load("res://combatants/data/player.tres")

func _initialize()->void:
	_run.call_deferred()

func _expect(value:bool, message:String)->void:
	if not value:
		_failures += 1
		push_error(message)

func _card(id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % id)

func _rng(seed_value:int)->RandomNumberGenerator:
	var rng:RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng

func _session(deck:Array[CardDefinition], identity:String = "pure")->BattleSession:
	var session:BattleSession = BattleSession.new()
	session.configure_context(identity, "node-a", _rng(4242))
	_expect(session.start_battle(_encounter, _player, deck, 50, 50), "无场景会话能够启动")
	return session

func _run()->void:
	var node_count:int = root.get_child_count()
	_test_prepare_activate()
	_test_queries_and_actual_events()
	_test_fatal_archive()
	_test_weapon_and_power()
	var first:Array = _trace(86241, false)
	var second:Array = _trace(86241, true)
	_expect(first == second and first.size() > 2, "相同战斗随机源可复现完整动作；全局随机消费不干扰洗牌")
	_expect(root.get_child_count() == node_count, "会话完成真实战斗不创建任何场景节点")
	if _failures == 0:
		print("BattleSession检查通过")
	else:
		print("BattleSession检查失败：%d" % _failures)
	quit(0 if _failures == 0 else 1)

func _test_prepare_activate()->void:
	var session:BattleSession = BattleSession.new()
	var rng:RandomNumberGenerator = _rng(9191)
	session.configure_context("prepare-id", "map-id", rng)
	var rng_state:int = rng.state
	var signals:Array[BattleEvent] = []
	session.actual_result.connect(func(event:BattleEvent)->void: signals.append(event))
	_expect(session.prepare(_encounter, _player, [_card("strike"), _card("defend")], 37, 43), "合法配置可以准备")
	_expect(session.battle_state.current_phase == BattleState.BattlePhase.SETUP and session.battle_state.hand.is_empty(), "准备不开始回合或抽牌")
	_expect(rng.state == rng_state and signals.is_empty() and not session.can_end_turn(), "准备不消费随机源、不产生反馈、不接收操作")
	_expect(session.activate(), "提交后会话激活")
	var hand:Array[CardInstance] = session.battle_state.hand.duplicate()
	var energy:int = session.battle_state.current_available_energy
	_expect(not session.activate(), "激活只能提交一次")
	_expect(session.battle_state.hand == hand and session.battle_state.current_turn_number == 1 and session.battle_state.current_available_energy == energy, "重复激活不重复发能量/抽牌")
	_expect(session.battle_state.player_state.current_health == 37 and session.battle_state.player_state.max_health == 43, "本局实际生命和上限不被角色定义覆盖")
	var original:BattleState = session.battle_state
	var candidate_rng:RandomNumberGenerator = _rng(72)
	var candidate_rng_state:int = candidate_rng.state
	var active_rng_state:int = rng.state
	session.configure_context("rejected", "other-node", candidate_rng)
	_expect(not session.prepare(_encounter, _player, [_card("strike")], 50, 43), "预期负向：非法生命配置准备失败")
	_expect(session.battle_state == original and session.battle_id == "prepare-id" and session.node_id == "map-id" and session.can_end_turn(), "准备失败保留当前战斗与身份")
	_expect(candidate_rng.state == candidate_rng_state and rng.state == active_rng_state, "准备失败不消费候选或当前随机源")
	session.configure_context("prepare-id", "map-id", rng)
	# 旧模型即使被外部持有，重新准备后也不会给新会话产生反馈。
	var old:BattleState = session.battle_state
	_expect(session.prepare(_encounter, _player, [_card("defend")], 50, 50), "同一会话可以准备新战斗")
	signals.clear()
	old.player_state.gain_block(5)
	old.gain_energy(2)
	_expect(signals.is_empty(), "上一场模型信号已断开")
	session.dispose()
	_expect(not session.activate() and not session.can_end_turn() and not session.end_turn(), "释放会话不能由迟到操作再次激活或推进")

func _test_queries_and_actual_events()->void:
	var session:BattleSession = _session([_card("double_strike"), _card("defend")])
	var state:BattleState = session.battle_state
	var card:CardInstance
	for current:CardInstance in state.hand:
		if current.definition.card_id == "double_strike":
			card = current
	state.player_state.gain_strength(2)
	state.enemy_state.gain_block(9)
	_expect(session.card_description(card).contains("7"), "查询伤害与执行共用倍率")
	state.current_available_energy = 0
	_expect(session.card_play_failure(card) == &"not_enough_energy" and not session.play_card(card), "不可支付查询和提交一致")
	_expect(state.hand.has(card) and state.enemy_state.current_block == 9, "拒绝命令不改变牌堆和数值")
	state.current_available_energy = 3
	var events:Array[BattleEvent] = []
	var reentry:Array[bool] = []
	var handler:Callable = func(event:BattleEvent)->void:
		events.append(event)
		if event.kind == &"strike_hit":
			reentry.append(session.end_turn())
			reentry.append(session.check_battle_result())
			reentry.append(session.prepare(_encounter, _player, [_card("defend")], 50, 50))
	session.actual_result.connect(handler)
	_expect(session.can_play_card(card) and session.play_card(card), "合法命令被接受")
	var actual:Array = []
	var previous_sequence:int = 0
	for event:BattleEvent in events:
		_expect(event.battle_id == "pure" and event.sequence > previous_sequence, "真实事件保留战斗身份与严格顺序")
		previous_sequence = event.sequence
		_expect(event.source_id == &"player", "卡牌真实结果标明行动来源")
		if event.target_id == &"enemy":
			actual.append([event.kind, event.amount])
	_expect(actual == [[&"block_hit", 7], [&"block_hit", 2], [&"strike_hit", 5]], "两段伤害分别报告实际吸盾和生命损失")
	_expect(state.enemy_state.current_health == 25 and state.enemy_state.current_block == 0, "两段结算保持基线")
	_expect(reentry == [false, false, false] and state.current_turn_number == 1 and session.battle_state == state, "结算反馈回调不能重入命令、提前胜负归档或替换会话")
	_expect(state.discard_pile.has(card) and state.resolving_card == null and not state.is_invalid_battle(), "成功出牌完整归档且牌区守恒")
	session.actual_result.disconnect(handler)
	session.dispose()

func _test_fatal_archive()->void:
	var strike:CardDefinition = _card("strike").duplicate()
	strike.exhausts_on_play = true
	var encounter:EncounterDefinition = _encounter.duplicate()
	encounter.enemy_definition = encounter.enemy_definition.duplicate()
	encounter.enemy_definition.max_health = 1
	var session:BattleSession = BattleSession.new()
	session.configure_context("fatal", "node-b", _rng(3))
	_expect(session.start_battle(encounter, _player, [strike], 50, 50), "致死案例能够启动")
	var card:CardInstance = session.battle_state.hand[0]
	var results:Array[BattleResult] = []
	var handler:Callable = func(result:BattleResult)->void:
		results.append(result)
		_expect(session.battle_state.resolving_card == null and session.battle_state.exhaust_pile.has(card), "会话结果信号前致命消耗牌已归档")
	session.battle_finished.connect(handler)
	_expect(session.play_card(card), "致命攻击为已接受命令")
	_expect(results.size() == 1 and results[0].battle_id == "fatal" and results[0].node_id == "node-b" and results[0].victory and results[0].player_health == 50 and results[0].player_max_health == 50, "结构化结果保留身份和实际数值")
	session.check_battle_result()
	_expect(results.size() == 1 and not session.end_turn() and not session.play_card(card), "终局只报告一次，拒绝后续命令")
	session.battle_finished.disconnect(handler)
	session.dispose()
	# 失血致死停止后续收益且仍归档，失败优先于敌人死亡。
	var blood:CardDefinition = _card("defend").duplicate()
	var loss:CombatEffectDefinition = CombatEffectDefinition.new()
	loss.effect_type = CombatEffectDefinition.EffectType.LOSE_HEALTH
	loss.target_type = CombatEffectDefinition.TargetType.SELF
	loss.amount = 2
	blood.effects = [loss, blood.effects[0]]
	var fatal:BattleSession = BattleSession.new()
	_expect(fatal.start_battle(_encounter, _player, [blood], 1, 50), "失血案例启动")
	_expect(fatal.play_card(fatal.battle_state.hand[0]), "失血是已接受效果")
	_expect(not fatal.get_result().victory and fatal.get_result().player_health == 0 and fatal.battle_state.player_state.current_block == 0, "失血致死不执行后续格挡")
	fatal.dispose()

func _test_weapon_and_power()->void:
	var session:BattleSession = _session([_card("eternity"), _card("war_god_blessing"), _card("blood_cloak")])
	var weapon:CardInstance
	var blessing:CardInstance
	var power:CardInstance
	for card:CardInstance in session.battle_state.hand:
		match card.definition.card_id:
			"eternity": weapon = card
			"war_god_blessing": blessing = card
			"blood_cloak": power = card
	_expect(session.card_play_failure(blessing) == &"no_weapon" and not session.play_card(blessing), "强化查询与命令共同要求装备")
	_expect(session.play_card(weapon) and session.play_card(blessing), "武器装备与祝福能通过纯会话组合")
	_expect(session.battle_state.equipped_weapon == weapon and session.battle_state.exhaust_pile.has(blessing) and session.can_attack_with_weapon(), "当前祝福消耗规则及武器攻击入口保留")
	_expect(weapon.weapon.current_attack == 11 and weapon.weapon.current_durability == 5 and weapon.weapon.max_durability == 5, "永恒强化状态符合实际配置")
	session.battle_state.gain_energy(3)
	_expect(session.play_card(power) and session.battle_state.played_power_cards.has(power) and not session.battle_state.exhaust_pile.has(power), "能力离开循环但不计消耗")
	_expect(session.attack_with_weapon() and not session.can_attack_with_weapon(), "武器机会每回合一次")
	_expect(session.end_turn() and session.battle_state.current_turn_number == 2, "结束回合完整推进敌人到下一玩家回合")
	_expect(session.battle_state.player_state.current_block >= 5 and not session.battle_state.is_invalid_battle(), "能力回合开始触发且牌区守恒")
	session.dispose()

func _snapshot(state:BattleState)->Dictionary:
	var hand:Array[String] = []
	for card:CardInstance in state.hand:
		hand.append(card.definition.card_id)
	return {"turn":state.current_turn_number, "phase":state.current_phase, "hp":state.player_state.current_health,
		"max":state.player_state.max_health, "block":state.player_state.current_block, "enemy_hp":state.enemy_state.current_health,
		"energy":state.current_available_energy, "hand":hand, "draw":state.draw_pile.size(), "discard":state.discard_pile.size()}

func _trace(seed_value:int, global_noise:bool)->Array:
	var rng:RandomNumberGenerator = _rng(seed_value)
	var session:BattleSession = BattleSession.new()
	session.configure_context("repeatable", "node-r", rng)
	var deck:Array[CardDefinition] = [_card("strike"), _card("defend"), _card("double_strike"),
		_card("heavy_strike"), _card("uppercut"), _card("attack_and_block")]
	var started:bool = session.start_battle(_encounter, _player, deck, 50, 50)
	_expect(started, "可重复真实战斗启动")
	if not started:
		session.dispose()
		return []
	var trace:Array = [_snapshot(session.battle_state)]
	for _turn in range(30):
		while session.can_end_turn():
			if global_noise:
				for _sample in range(17):
					randi()
			var selected:CardInstance
			for card:CardInstance in session.battle_state.hand:
				if session.can_play_card(card):
					selected = card
					break
			if selected == null:
				break
			session.play_card(selected)
			trace.append(_snapshot(session.battle_state))
		if session.get_result() != null:
			break
		session.end_turn()
		trace.append(_snapshot(session.battle_state))
	_expect(session.get_result() != null and session.get_result().victory, "纯会话完整战斗最终胜利")
	session.dispose()
	return trace
