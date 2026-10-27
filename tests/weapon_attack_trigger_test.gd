## 嗜血长剑：伤害后获得力量并抽牌，再扣耐久与处理损坏。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_order_and_next_turn();
	_test_blocked_and_zero_damage();
	_test_draw_limits();
	_test_last_durability();
	_test_trigger_scope();
	_test_next_battle();
	await process_frame;
	print("武器攻击触发检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _weapon(has_trigger:bool = true)->CardDefinition:
	var definition:CardDefinition = CardDefinition.new();
	definition.card_id = "test_bloodthirsty_sword" if has_trigger else "test_plain_sword";
	definition.card_name = "测试嗜血长剑" if has_trigger else "测试普通武器";
	definition.description = "武器攻击触发测试，不加入正式卡池。";
	definition.card_type = CardDefinition.CardType.WEAPON;
	definition.base_energy_cost = 2;
	definition.is_innate = true; # 仅用于保证测试起手。
	definition.weapon_definition = WeaponDefinition.new();
	definition.weapon_definition.base_attack = 8;
	definition.weapon_definition.base_max_durability = 3;
	if has_trigger:
		definition.weapon_definition.strength_on_attack = 1;
		definition.weapon_definition.draw_on_attack = 1;
	return definition;


func _controller(specials:Array[CardDefinition], filler_count:int = 10)->BattleController:
	var deck:Array[CardDefinition] = specials.duplicate();
	for index in range(filler_count):
		deck.append(load("res://cards/data/defend.tres"));
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), deck, 50, 50), "武器触发测试战斗应启动");
	return controller;


func _in_hand(state:BattleState, definition:CardDefinition)->CardInstance:
	for card in state.hand:
		if card.definition == definition:
			return card;
	return null;


func _test_order_and_next_turn()->void:
	var definition:CardDefinition = _weapon();
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(state.hand[0]);
	state.player_state.gain_strength(2);
	state.player_state.apply_weak(2, false);
	state.enemy_state.apply_vulnerable(2, false);
	controller._refresh_battle_view();
	var attack:Button = controller.hand_area.get_node("weapon_attack");
	_expect(attack.tooltip_text.contains("预计伤害：11") and attack.tooltip_text.contains("攻击后：获得1点力量") and attack.tooltip_text.contains("攻击后：抽1张牌"), "预览只计已有力量，说明攻击后触发");
	attack.pressed.emit();
	_expect(state.enemy_state.current_health == 19 and state.player_state.strength == 3, "先用已有2力量造成11伤害，再获得1力量");
	_expect(state.hand.size() == 5 and state.equipped_weapon.weapon.current_durability == 2 and state.current_available_energy == 1, "抽1张、扣1耐久，装备花2费且攻击不回能");
	controller._on_weapon_attack_requested();
	_expect(state.hand.size() == 5 and state.player_state.strength == 3 and state.enemy_state.current_health == 19, "重复点击不重复触发");
	controller._on_end_turn_button_pressed();
	state.enemy_state.current_block = 0;
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_health == 7 and state.player_state.strength == 4 and state.hand.size() == 6, "下一回合攻击享受上次力量，随后再次获得力量与抽牌");
	_expect(definition.weapon_definition.base_attack == 8 and not state.is_invalid_battle(), "力量不写入武器攻击力，牌区守恒");
	controller.get_parent().queue_free();


func _test_blocked_and_zero_damage()->void:
	for zero_attack in [false, true]:
		var definition:CardDefinition = _weapon();
		if zero_attack:
			definition.weapon_definition.base_attack = 0;
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		controller._on_card_selected(state.hand[0]);
		state.enemy_state.gain_block(20);
		controller._on_weapon_attack_requested();
		_expect(state.enemy_state.current_health == 30 and state.player_state.strength == 1 and state.hand.size() == 5, "零伤害或完全格挡仍触发力量与抽牌");
		_expect(state.equipped_weapon.weapon.current_durability == 2, "无实际失血也照常扣耐久");
		controller.get_parent().queue_free();


func _test_draw_limits()->void:
	for mode in ["blocked", "full", "empty", "reshuffle"]:
		var controller:BattleController = _controller([_weapon()], 0 if mode == "empty" else 10);
		var state:BattleState = controller.battle_state;
		controller._on_card_selected(state.hand[0]);
		if mode == "blocked":
			state.prevent_draw_for_turn();
			controller._refresh_battle_view();
			_expect(controller.hand_area.get_node("weapon_attack").tooltip_text.contains("本回合禁止抽牌"), "武器抽牌提示反映禁抽状态");
		elif mode == "full":
			state.draw_multiple_cards(10);
		elif mode == "reshuffle":
			state.discard_pile.append_array(state.draw_pile);
			state.draw_pile.clear();
		var hand_size:int = state.hand.size();
		controller._on_weapon_attack_requested();
		_expect(state.player_state.strength == 1, "抽牌受限不影响获得力量：%s" % mode);
		_expect(state.hand.size() == hand_size + (1 if mode == "reshuffle" else 0), "武器抽牌遵守禁抽、手牌容量、空牌堆和洗牌规则：%s" % mode);
		_expect(not state.is_invalid_battle(), "武器抽牌只移动原卡实例");
		controller.get_parent().queue_free();


func _test_last_durability()->void:
	for lethal in [false, true]:
		var controller:BattleController = _controller([_weapon()]);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		controller._on_card_selected(card);
		card.weapon.current_durability = 1;
		if lethal:
			state.enemy_state.current_health = 1;
		var results:Array[bool] = [];
		controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
			results.append(victory);
			_expect(state.player_state.strength == 1 and state.hand.size() == 5, "胜利报告前已完成力量与抽牌");
			_expect(state.exhaust_pile.has(card) and state.equipped_weapon == null, "胜利报告前已损坏归档");
		);
		controller._on_weapon_attack_requested();
		controller._on_weapon_attack_requested();
		_expect(state.player_state.strength == 1 and state.hand.size() == 5 and state.exhaust_pile.has(card), "最后耐久仍触发一次，随后损坏");
		_expect(results.size() == (1 if lethal else 0) and not state.is_invalid_battle(), "胜负结果不重复，牌区守恒");
		controller.get_parent().queue_free();


func _test_trigger_scope()->void:
	var triggered:CardDefinition = _weapon();
	var plain:CardDefinition = _weapon(false);
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	triggered.effects.assign(strike.effects);
	var controller:BattleController = _controller([triggered, plain, strike], 0);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(_in_hand(state, triggered));
	_expect(state.player_state.strength == 0 and state.hand.size() == 2, "装备附加伤害不触发武器攻击奖励");
	controller._on_card_selected(_in_hand(state, strike));
	_expect(state.player_state.strength == 0 and state.hand.size() == 1, "普通攻击牌不触发装备的武器攻击奖励");
	state.gain_energy(2);
	controller._on_card_selected(_in_hand(state, plain));
	_expect(state.player_state.strength == 0 and state.hand.is_empty(), "替换造成的损坏不触发奖励");
	controller._on_weapon_attack_requested();
	_expect(state.player_state.strength == 0 and state.hand.is_empty(), "换成普通武器后不残留旧武器效果");
	controller.get_parent().queue_free();


func _test_next_battle()->void:
	var definition:CardDefinition = _weapon();
	var controller:BattleController = _controller([definition]);
	controller._on_card_selected(controller.battle_state.hand[0]);
	controller._on_weapon_attack_requested();
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [definition], 50, 50), "新战斗可以启动");
	_expect(controller.battle_state.player_state.strength == 0 and controller.battle_state.hand[0].weapon.current_durability == 3, "新战斗不继承力量与旧耐久");
	controller._on_card_selected(controller.battle_state.hand[0]);
	controller._on_weapon_attack_requested();
	_expect(controller.battle_state.player_state.strength == 1 and controller.battle_state.enemy_state.current_health == 22, "新实例仍按静态配置正常触发");
	controller.get_parent().queue_free();
