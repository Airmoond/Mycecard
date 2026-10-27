## 藏品与正式战斗共用伤害、回合开始队列和输入入口。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_starting_strength();
	_test_strength_weapon_and_statuses();
	_test_early_block();
	_test_retained_block_and_shield_slam();
	_test_lethal_turn_start();
	_test_no_battle_heal_and_legacy_entry();
	await process_frame;
	await _test_inspector();
	await process_frame;
	print("藏品战斗检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _card(card_id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % card_id);


func _collection(collection_id:String)->CollectionDefinition:
	return load("res://collections/data/%s.tres" % collection_id);


## 只替换本测试敌人行动和生命，静态正式资源保持原样。
func _safe_encounter(boss:bool = false)->EncounterDefinition:
	var path:String = "ruin_guard" if boss else "cave_crawler";
	var encounter:EncounterDefinition = load("res://battle/encounters/data/%s_encounter.tres" % path).duplicate();
	encounter.enemy_definition = encounter.enemy_definition.duplicate();
	encounter.enemy_definition.max_health = 10000;
	var block:CombatEffectDefinition = CombatEffectDefinition.new();
	block.effect_type = CombatEffectDefinition.EffectType.BLOCK;
	block.amount = 1;
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_collection_safe_enemy";
	action.intent_text = "观察藏品";
	action.effects = [block];
	encounter.enemy_definition.action_pattern = [action];
	return encounter;


func _controller(cards:Array[CardDefinition], collection:CollectionDefinition = null, boss:bool = false)->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(_safe_encounter(boss), load("res://combatants/players/data/player.tres"), cards, 50, 50, collection), "藏品测试战斗应正常启动");
	return controller;


func _test_starting_strength()->void:
	for boss in [false, true]:
		var fang:CollectionDefinition = _collection("copper_fang");
		var controller:BattleController = _controller([_card("double_strike")], fang, boss);
		var state:BattleState = controller.battle_state;
		_expect(controller.selected_collection == fang and state.player_state.strength == 1 and state.current_turn_number == 1, "普通与Boss战均在第一次出牌前获得1力量");
		controller._on_card_selected(state.hand[0]);
		_expect(state.enemy_state.current_health == 9988, "双重打击每段由5变6，共造成12伤害");
		controller._refresh_battle_view();
		controller._start_player_turn();
		controller._on_end_turn_button_pressed();
		_expect(state.player_state.strength == 1 and state.current_turn_number == 2, "刷新和后续回合不重复领取开局力量");
		state.player_state.gain_strength(9);
		_expect(controller.start_battle(_safe_encounter(boss), load("res://combatants/players/data/player.tres"), [_card("strike")], 40, 50, fang), "同控制器可重新启动另一场带藏品战斗");
		_expect(controller.battle_state.player_state.strength == 1 and controller.battle_state.player_state.current_health == 40, "新战斗清除旧力量，再重新获得藏品的1力量");
		_expect(fang.amount == 1 and _card("double_strike").effects[0].amount == 5, "力量效果不写入藏品或卡牌资源");
		controller.get_parent().queue_free();


func _test_strength_weapon_and_statuses()->void:
	var controller:BattleController = _controller([_card("bloodthirsty_sword")], _collection("copper_fang"));
	var state:BattleState = controller.battle_state;
	state.player_state.apply_weak(1, false);
	state.enemy_state.apply_vulnerable(1, false);
	controller._on_card_selected(state.hand[0]);
	var attack:Button = controller.hand_area.get_node("weapon_attack");
	_expect(attack.tooltip_text.contains("预计伤害：10"), "武器预览用8攻击加1力量，再统一计算虚弱与易伤");
	attack.pressed.emit();
	_expect(state.enemy_state.current_health == 9990 and state.player_state.strength == 2, "实际武器伤害与预览一致，攻击后武器额外力量正常叠加");
	_expect(_card("bloodthirsty_sword").weapon_definition.base_attack == 8 and state.equipped_weapon.weapon.current_attack == 8, "藏品力量不永久修改武器攻击力");
	controller.get_parent().queue_free();


func _test_early_block()->void:
	for boss in [false, true]:
		var shield:CollectionDefinition = _collection("oathguard_emblem");
		var controller:BattleController = _controller([_card("defend")], shield, boss);
		var state:BattleState = controller.battle_state;
		for turn in range(1, 6):
			_expect(state.current_turn_number == turn and state.player_state.current_block == (3 if turn <= 3 else 0), "盾徽仅在前3个玩家回合各给3格挡，不保留旧格挡");
			var energy:int = state.current_available_energy;
			var hand_size:int = state.hand.size();
			controller._start_player_turn();
			controller._refresh_battle_view();
			_expect(state.current_turn_number == turn and state.player_state.current_block == (3 if turn <= 3 else 0) and state.current_available_energy == energy and state.hand.size() == hand_size, "当前玩家回合不能重复开始来刷新能量、抽牌或叠加藏品格挡");
			if turn < 5:
				controller._on_end_turn_button_pressed();
		_expect(controller.start_battle(_safe_encounter(boss), load("res://combatants/players/data/player.tres"), [_card("defend")], 50, 50, shield), "盾徽次数随新战斗重置");
		_expect(controller.battle_state.current_turn_number == 1 and controller.battle_state.player_state.current_block == 3, "新战斗重新享有首回合3格挡");
		controller.get_parent().queue_free();


func _test_retained_block_and_shield_slam()->void:
	var controller:BattleController = _controller([_card("fortress"), _card("shield_slam")], _collection("oathguard_emblem"));
	var state:BattleState = controller.battle_state;
	for card in state.hand.duplicate():
		if card.definition.card_id == "fortress":
			controller._on_card_selected(card);
	for card in state.hand.duplicate():
		if card.definition.card_id == "shield_slam":
			controller._on_card_selected(card);
	_expect(state.player_state.current_block == 3 and state.enemy_state.current_health == 9997, "藏品格挡可正常参与盾牌猛击，攻击后保留格挡");
	for turn in range(2, 5):
		controller._on_end_turn_button_pressed();
		_expect(state.player_state.current_block == mini(turn, 3) * 3, "坚城保留已有格挡，盾徽前三回合累计9，此后不再额外增加");
	_expect(not state.is_invalid_battle(), "能力牌、盾牌猛击和藏品共存仍保持牌区守恒");
	controller.get_parent().queue_free();


func _test_lethal_turn_start()->void:
	var controller:BattleController = _controller([_card("blood_cloak"), _card("defend"), _card("defend")], _collection("oathguard_emblem"));
	var state:BattleState = controller.battle_state;
	for card in state.hand.duplicate():
		if card.definition.card_id == "blood_cloak":
			controller._on_card_selected(card);
	state.player_state.current_health = 1;
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void: results.append(victory));
	controller._on_end_turn_button_pressed();
	controller._on_end_turn_button_pressed();
	controller._start_player_turn();
	_expect(results == [false] and state.current_phase == BattleState.BattlePhase.FINISHED, "披风回合开始失血致死只报告一次失败");
	_expect(state.player_state.current_health == 0 and state.player_state.current_block == 0 and state.hand.is_empty() and state.discard_pile.size() == 2, "致死后不执行披风格挡、藏品格挡或抽牌，队列按原顺序中断");
	_expect(controller.collection_button.disabled, "已结束的战斗不能再打开藏品查看窗口");
	controller.get_parent().queue_free();


func _test_no_battle_heal_and_legacy_entry()->void:
	for boss in [false, true]:
		var controller:BattleController = _controller([_card("strike")], _collection("ember_chalice"), boss);
		var state:BattleState = controller.battle_state;
		state.player_state.current_health = 40;
		state.enemy_state.take_unblocked_damage(10000);
		controller._check_battle_result();
		_expect(state.player_state.current_health == 40 and state.player_state.strength == 0 and state.player_state.current_block == 0, "圣杯不在战斗控制器内加血，普通胜利治疗交由整局流程，Boss也不误治");
		_expect(controller.start_battle(_safe_encounter(), load("res://combatants/players/data/player.tres"), [_card("strike")], 40, 50), "原五参数战斗入口继续兼容试炼和无藏品评估");
		_expect(controller.selected_collection == null and controller.battle_state.player_state.current_health == 40 and controller.battle_state.player_state.strength == 0 and controller.battle_state.player_state.current_block == 0, "不传藏品的新战斗无旧藏品或状态残留");
		controller.get_parent().queue_free();


func _test_inspector()->void:
	var fang:CollectionDefinition = _collection("copper_fang");
	var controller:BattleController = _controller([_card("eternity"), _card("strike")], fang);
	var state:BattleState = controller.battle_state;
	for card in state.hand.duplicate():
		if card.definition.card_id == "eternity":
			controller._on_card_selected(card);
	var energy:int = state.current_available_energy;
	var enemy_health:int = state.enemy_state.current_health;
	var durability:int = state.equipped_weapon.weapon.current_durability;
	var card:CardInstance = state.hand[0];
	controller.collection_button.pressed.emit();
	var inspector:CollectionInspector = controller._collection_inspector;
	_expect(inspector != null and controller.end_turn_button.disabled and controller.collection_button.disabled, "查看藏品在结束回合上方打开单一窗口并禁用背景按钮");
	_expect(inspector.collection == fang and inspector.name_label.text == fang.display_name and inspector.description_label.text == fang.description, "查看窗口展示本场实际持有的藏品名称和效果");
	controller.collection_button.pressed.emit();
	_expect(controller._collection_inspector == inspector, "连续触发不会创建多个查看窗口");
	_expect(not controller._card_is_playable(card) and (controller.hand_area.get_node("weapon_attack") as Button).disabled, "查看时手牌和武器入口显示为不可操作");
	controller._on_card_selected(card);
	controller._on_weapon_attack_requested();
	controller.end_turn_button.pressed.emit();
	_expect(state.current_turn_number == 1 and state.current_available_energy == energy and state.hand.has(card) and state.enemy_state.current_health == enemy_health and state.equipped_weapon.weapon.current_durability == durability, "程序直接触发背景出牌、武器与结束回合入口也不穿透查看窗口");
	inspector.close_button.pressed.emit();
	_expect(not controller._has_collection_inspector() and not controller.end_turn_button.disabled and not controller.collection_button.disabled, "关闭窗口后恢复同一回合的输入");
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_health == enemy_health - 4, "关闭后武器恢复使用，保留本场1力量");
	controller.collection_button.pressed.emit();
	var old_inspector:CollectionInspector = controller._collection_inspector;
	_expect(controller.start_battle(_safe_encounter(), load("res://combatants/players/data/player.tres"), [_card("strike")], 40, 50), "查看中启动新战斗正常重置");
	_expect(not controller._has_collection_inspector() and old_inspector.is_queued_for_deletion() and controller.selected_collection == null, "新战斗移除旧查看窗口，不继承旧藏品");
	controller.collection_button.pressed.emit();
	_expect(controller._collection_inspector != null, "无藏品兼容战斗仍可打开明确空态查看窗口");
	_expect(controller._collection_inspector.collection == null and controller._collection_inspector.name_label.text == "尚未获得藏品", "空态不显示上一场已持有的藏品");
	controller._collection_inspector.close_button.pressed.emit();
	await process_frame;
	controller.collection_button.pressed.emit();
	var escape:InputEventKey = InputEventKey.new();
	escape.keycode = KEY_ESCAPE;
	escape.physical_keycode = KEY_ESCAPE;
	escape.pressed = true;
	root.push_input(escape);
	_expect(not controller._has_collection_inspector() and not controller.end_turn_button.disabled, "Esc关闭藏品查看并恢复背景输入");
	controller.collection_button.pressed.emit();
	old_inspector = controller._collection_inspector;
	controller.battle_state.enemy_state.take_unblocked_damage(10000);
	controller._check_battle_result();
	controller.collection_button.pressed.emit();
	_expect(not controller._has_collection_inspector() and old_inspector.is_queued_for_deletion() and controller.collection_button.disabled, "战斗结束移除窗口并忽略后续查看请求");
	controller.get_parent().queue_free();
