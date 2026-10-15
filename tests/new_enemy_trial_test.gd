## F6敌人试炼入口的菜单、基础牌组与多次切换战斗检查。
## 仅改变单场运行时状态验证隔离；不修改正式角色、卡牌或敌人资源。
extends SceneTree

const TRIAL_SCENE:PackedScene = preload("res://综合数值模型/新敌人实验/敌人试炼.tscn");
const ENEMY_IDS:Array[String] = ["bulwark_sentinel", "hexbound_acolyte", "ragebound_brute"];

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _buttons(node:Node)->Array[Button]:
	var result:Array[Button] = [];
	if node is Button:
		result.append(node);
	for child in node.get_children():
		result.append_array(_buttons(child));
	return result;


func _check_selection(trial:Control)->void:
	var choices:Array[Button] = _buttons(trial);
	_expect(choices.size() == 3, "试炼选择页应显示三个敌人选择按钮");
	for enemy_id in ENEMY_IDS:
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id);
		var found:bool = false;
		for button in choices:
			if button.text.contains(enemy.display_name):
				found = true;
				_expect(button.text.contains(str(enemy.max_health)), "选择按钮应显示该敌人的正式生命");
				_expect(not button.disabled and button.pressed.get_connections().size() > 0, "敌人选择按钮应可用且已连接交互");
		_expect(found, "选择页应包含新敌人：%s" % enemy_id);
	_expect(trial.get_node_or_null("battle") == null, "返回选择页后应移除上一场战斗界面");


func _check_base_deck(state:BattleState)->void:
	var all_cards:Array[CardInstance] = [];
	all_cards.append_array(state.draw_pile);
	all_cards.append_array(state.hand);
	all_cards.append_array(state.discard_pile);
	all_cards.append_array(state.exhaust_pile);
	all_cards.append_array(state.played_power_cards);
	if state.resolving_card != null:
		all_cards.append(state.resolving_card);
	if state.equipped_weapon != null:
		all_cards.append(state.equipped_weapon);
	var counts:Dictionary = {"strike":0, "defend":0};
	for card in all_cards:
		var card_id:String = card.definition.card_id;
		counts[card_id] = int(counts.get(card_id, 0)) + 1;
	_expect(all_cards.size() == 6 and counts.size() == 2 and counts.strike == 3 and counts.defend == 3, "试炼所有牌区合计必须只有3打击与3防御");
	_expect(not state.is_invalid_battle(), "试炼牌组实例与正式战斗状态应完整合法");


func _run()->void:
	var trial:Control = TRIAL_SCENE.instantiate();
	root.add_child(trial);
	_check_selection(trial);
	var previous_state:BattleState = null;
	# 最后再次进入哨卫，检查离开已强化的蛮兵后仍然从全新战斗开始。
	for enemy_id in ["bulwark_sentinel", "hexbound_acolyte", "ragebound_brute", "bulwark_sentinel"]:
		trial.call("_start_fight", enemy_id);
		var controller:BattleController = trial.get_node_or_null("battle/battle_controller") as BattleController;
		_expect(controller != null and controller.battle_state != null, "试炼应创建并启动正式战斗控制器");
		if controller == null or controller.battle_state == null:
			trial.call("_show_selection");
			continue;
		var state:BattleState = controller.battle_state;
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id);
		_expect(state != previous_state, "切换试炼必须使用新的战斗状态");
		_expect(state.current_phase == BattleState.BattlePhase.PLAYER_TURN and state.current_turn_number == 1, "试炼应从第一个玩家回合开始");
		_expect(state.player_state.current_health == 50 and state.player_state.max_health == 50, "每次试炼玩家都应以50/50生命开始");
		_expect(state.player_state.strength == 0 and state.enemy_state.strength == 0, "切换敌人后双方不能继承上一场力量");
		_expect(state.player_state.weak_turns == 0 and state.player_state.vulnerable_turns == 0, "新试炼不能继承双减益");
		_expect(state.energy_per_turn == 3 and state.current_available_energy == 3 and state.cards_per_turn == 5, "试炼应保留正式3能量与5抽牌规则");
		_expect(state.enemy_state.enemy_definition.combatant_id == enemy_id, "试炼应加载选择的敌人");
		_expect(state.enemy_state.current_health == enemy.max_health and state.enemy_state.max_health == enemy.max_health, "试炼敌人应以正式资源的完整生命开始");
		_check_base_deck(state);
		state.player_state.lose_health(11);
		state.player_state.gain_strength(5);
		state.enemy_state.gain_strength(12);
		state.player_state.apply_weak(2, true);
		state.player_state.apply_vulnerable(2, true);
		previous_state = state;
		trial.call("_show_selection");
		_check_selection(trial);
	trial.queue_free();
	await process_frame;
	print("新敌人试炼入口检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);
