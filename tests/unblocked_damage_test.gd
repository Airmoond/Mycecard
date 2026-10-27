## 无视格挡伤害的独立入口，以及武器修正、范围、耐久与胜负收尾。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_damage_entry();
	_test_weapon_comparison();
	_test_modifiers_and_preview();
	_test_weapon_only();
	_test_zero_damage();
	_test_lethal_attack();
	_test_replacement();
	await process_frame;
	print("无视格挡伤害检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _weapon(ignores_block:bool = true)->CardDefinition:
	var definition:CardDefinition = CardDefinition.new();
	definition.card_id = "test_unblocked_weapon";
	definition.card_name = "测试致命之刃";
	definition.description = "仅用于无视格挡检查。";
	definition.card_type = CardDefinition.CardType.WEAPON;
	definition.base_energy_cost = 3;
	definition.weapon_definition = WeaponDefinition.new();
	definition.weapon_definition.base_attack = 15;
	definition.weapon_definition.base_max_durability = 2;
	definition.weapon_definition.ignores_block = ignores_block;
	return definition;


func _controller(cards:Array[CardDefinition])->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), cards, 50, 50), "无视格挡测试应能启动");
	return controller;


func _in_hand(controller:BattleController, definition:CardDefinition)->CardInstance:
	for card in controller.battle_state.hand:
		if card.definition == definition:
			return card;
	return null;


func _test_damage_entry()->void:
	var target:CombatantState = CombatantState.new();
	target.combatant_init("受击者", 50);
	target.gain_block(10);
	_expect(target.take_unblocked_damage(8) == 8 and target.current_health == 42 and target.current_block == 10, "独立入口扣8生命且完整保留10格挡");
	_expect(target.take_damage(8) == 0 and target.current_health == 42 and target.current_block == 2, "普通伤害仍先消耗格挡");
	_expect(target.take_unblocked_damage(0) == 0 and target.current_health == 42 and target.current_block == 2, "0伤害不改变生命或格挡");
	target.current_health = 3;
	_expect(target.take_unblocked_damage(15) == 3 and target.current_health == 0 and target.current_block == 2, "过量伤害返回实际损失，生命最低为0");


func _test_weapon_comparison()->void:
	_expect(not WeaponDefinition.new().ignores_block, "默认武器继续受格挡抵消");
	for ignores_block in [false, true]:
		var definition:CardDefinition = _weapon(ignores_block);
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		state.enemy_state.gain_block(20);
		controller._on_card_selected(state.hand[0]);
		_expect(state.current_available_energy == 0, "按草案3费正常装备");
		var card:CardInstance = state.equipped_weapon;
		controller._on_weapon_attack_requested();
		_expect(state.enemy_state.current_health == (15 if ignores_block else 30), "无视格挡才直接造成15生命损失");
		_expect(state.enemy_state.current_block == (20 if ignores_block else 5), "穿透保留格挡，普通攻击抵消格挡");
		_expect(card.weapon.current_durability == 1 and not state.weapon_attack_available, "仍消耗1耐久和本回合攻击机会");
		controller._on_weapon_attack_requested();
		_expect(card.weapon.current_durability == 1 and state.enemy_state.current_health == (15 if ignores_block else 30), "重复点击不能再次攻击");
		controller.get_parent().queue_free();


func _test_modifiers_and_preview()->void:
	var definition:CardDefinition = _weapon();
	definition.weapon_definition.base_attack = 7;
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_strength(3);
	state.player_state.apply_weak(1, false);
	state.enemy_state.apply_vulnerable(1, false);
	state.enemy_state.gain_block(99);
	controller._on_card_selected(state.hand[0]);
	var attack_view:Button = controller.hand_area.get_node("weapon_attack");
	_expect(attack_view.tooltip_text == "预计伤害：11（无视格挡）", "穿透攻击仍先加力量、乘虚弱和易伤并最终取整");
	attack_view.pressed.emit();
	_expect(state.enemy_state.current_health == 19 and state.enemy_state.current_block == 99, "实际伤害与预览一致，99格挡不变");
	_expect(definition.weapon_definition.base_attack == 7 and definition.weapon_definition.ignores_block, "修正不改写武器配置");
	controller.get_parent().queue_free();


func _test_weapon_only()->void:
	var definition:CardDefinition = _weapon();
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	definition.effects.assign(strike.effects);
	var controller:BattleController = _controller([definition, strike]);
	var state:BattleState = controller.battle_state;
	state.enemy_state.gain_block(20);
	controller._on_card_selected(_in_hand(controller, definition));
	_expect(state.enemy_state.current_block == 14 and state.enemy_state.current_health == 30, "武器的装备附加伤害仍按自身效果规则抵消格挡");
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_block == 14 and state.enemy_state.current_health == 15, "只有独立武器攻击读取该武器的穿透开关");
	state.gain_energy(1);
	controller._on_card_selected(_in_hand(controller, strike));
	_expect(state.enemy_state.current_block == 8 and state.enemy_state.current_health == 15, "装备穿透武器不让普通攻击牌穿透");
	controller.get_parent().queue_free();


func _test_zero_damage()->void:
	var definition:CardDefinition = _weapon();
	definition.weapon_definition.base_attack = 0;
	definition.weapon_definition.base_max_durability = 1;
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	state.enemy_state.gain_block(10);
	controller._on_card_selected(card);
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_health == 30 and state.enemy_state.current_block == 10, "0点穿透伤害不改生命或格挡");
	_expect(not state.weapon_attack_available and state.equipped_weapon == null and state.exhaust_pile.has(card), "0伤害仍扣最后耐久并按普通武器消耗");
	controller.get_parent().queue_free();


func _test_lethal_attack()->void:
	var definition:CardDefinition = _weapon();
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	controller._on_card_selected(card);
	card.weapon.current_durability = 1;
	state.enemy_state.current_health = 4;
	state.enemy_state.gain_block(99);
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
		results.append(victory);
		_expect(state.enemy_state.current_health == 0 and state.enemy_state.current_block == 99, "致命攻击仍保留格挡");
		_expect(state.equipped_weapon == null and card.weapon.current_durability == 0 and state.exhaust_pile.has(card), "报告胜利前完成耐久与消耗归档");
	);
	controller._on_weapon_attack_requested();
	controller._on_weapon_attack_requested();
	_expect(results.size() == 1 and results[0] and not state.is_invalid_battle(), "致命攻击只报告一次胜利且牌区守恒");
	controller.get_parent().queue_free();


func _test_replacement()->void:
	var piercing:CardDefinition = _weapon();
	var ordinary:CardDefinition = _weapon(false);
	var controller:BattleController = _controller([piercing, ordinary]);
	var state:BattleState = controller.battle_state;
	state.enemy_state.gain_block(20);
	controller._on_card_selected(_in_hand(controller, piercing));
	state.gain_energy(3);
	controller._on_card_selected(_in_hand(controller, ordinary));
	var attack_view:Button = controller.hand_area.get_node("weapon_attack");
	_expect(attack_view.tooltip_text == "预计伤害：15（格挡前）", "更换武器后提示读取新武器规则");
	attack_view.pressed.emit();
	_expect(state.enemy_state.current_health == 30 and state.enemy_state.current_block == 5, "穿透属于武器配置，换普通武器后不会残留");
	controller.get_parent().queue_free();
