## 背水一战：先抽后禁、重复使用、统一抽牌入口、回合恢复及永恒回手。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_draw_then_block();
	_test_repeat_and_other_effects();
	_test_no_reshuffle();
	_test_turn_and_battle_reset();
	_test_limited_first_draw();
	_test_weapon_return();
	await process_frame;
	print("本回合禁止抽牌检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _effect(kind:CombatEffectDefinition.EffectType, amount:int = 0)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = kind;
	effect.target_type = CombatEffectDefinition.TargetType.SELF;
	effect.amount = amount;
	return effect;


func _card()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_prevent_draw";
	definition.card_name = "测试背水一战";
	definition.description = "抽3张牌。本回合你不能再抽牌。";
	definition.base_energy_cost = 0;
	definition.is_innate = true; # 保证测试起手，与正式卡牌词条无关。
	definition.effects = [_effect(CombatEffectDefinition.EffectType.DRAW, 3), _effect(CombatEffectDefinition.EffectType.PREVENT_DRAW)];
	return definition;


func _controller(specials:Array[CardDefinition], filler_count:int = 10, hand_limit:int = 10)->BattleController:
	var definitions:Array[CardDefinition] = specials.duplicate();
	for index in range(filler_count):
		definitions.append(load("res://cards/data/defend.tres"));
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate();
	encounter.cards_per_turn = 2;
	encounter.max_hand_size = hand_limit;
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), definitions, 50, 50), "抽牌限制测试战斗应能启动");
	return controller;


func _test_draw_then_block()->void:
	var controller:BattleController = _controller([_card()]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	var deck_size:int = state.draw_pile.size();
	controller._on_card_selected(card);
	_expect(state.hand.size() == 4 and state.draw_pile.size() == deck_size - 3, "先完成3张抽牌，再施加限制");
	_expect(state.draw_blocked_this_turn and state.discard_pile.has(card) and state.current_available_energy == 3, "0费技能正常归档并禁抽");
	_expect(controller.draw_pile_label.text.contains("禁抽"), "界面应提示本回合禁抽");
	_expect(state.draw_one_card() == null and state.draw_multiple_cards(3).is_empty(), "单张和多张抽牌共用限制");
	_expect(state.hand.size() == 4 and state.draw_pile.size() == deck_size - 3 and not state.is_invalid_battle(), "被拦截后牌区不变且守恒");
	controller.get_parent().queue_free();


func _test_repeat_and_other_effects()->void:
	var other:CardDefinition = _card();
	other.card_id = "test_draw_and_block";
	other.effects = [_effect(CombatEffectDefinition.EffectType.DRAW, 2), _effect(CombatEffectDefinition.EffectType.BLOCK, 5)];
	var controller:BattleController = _controller([_card(), _card(), other]);
	var state:BattleState = controller.battle_state;
	var opening:Array[CardInstance] = state.hand.duplicate();
	for card in opening:
		if card.definition.card_id == "test_prevent_draw":
			controller._on_card_selected(card);
	var deck_size:int = state.draw_pile.size();
	_expect(state.hand.size() == 4 and state.discard_pile.size() == 2, "第二张背水一战仍可打出，但不会再次抽牌");
	for card in opening:
		if card.definition == other:
			controller._on_card_selected(card);
	_expect(state.draw_pile.size() == deck_size and state.player_state.current_block == 5, "其他卡牌抽牌被拦截，后续格挡照常结算");
	_expect(state.hand.size() == 3 and not state.is_invalid_battle(), "三张技能正常归档，没有复制或丢失卡牌");
	controller.get_parent().queue_free();


func _test_no_reshuffle()->void:
	var controller:BattleController = _controller([_card()], 0);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(state.hand[0]);
	var discarded:Array[CardInstance] = state.discard_pile.duplicate();
	controller.action_queue.queue_draw(state, 1);
	controller.action_queue.queue_gain_energy(state, 1);
	controller.action_queue.resolve_all();
	_expect(state.draw_pile.is_empty() and state.hand.is_empty() and state.discard_pile == discarded, "禁止抽牌时不把弃牌堆洗回抽牌堆");
	_expect(state.current_available_energy == 4, "抽牌未成功不影响队列后续效果");
	controller.get_parent().queue_free();


func _test_turn_and_battle_reset()->void:
	var controller:BattleController = _controller([_card()]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(state.hand[0]);
	controller._on_end_turn_button_pressed();
	_expect(state.current_turn_number == 2 and not state.draw_blocked_this_turn and state.hand.size() == 2, "下一回合先解禁，再正常抽基础数量");
	_expect(not controller.draw_pile_label.text.contains("禁抽") and controller.draw_pile_label.tooltip_text.is_empty(), "解禁时清除界面提示");
	state.prevent_draw_for_turn();
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [load("res://cards/data/defend.tres")], 50, 50), "可启动新战斗");
	_expect(not controller.battle_state.draw_blocked_this_turn and controller.battle_state.hand.size() == 1, "新战斗不继承禁抽状态");
	controller.get_parent().queue_free();


func _test_limited_first_draw()->void:
	for filler_count in [0, 1, 10]:
		var controller:BattleController = _controller([_card()], filler_count, 2);
		var state:BattleState = controller.battle_state;
		controller._on_card_selected(state.hand[0]);
		_expect(state.hand.size() == mini(filler_count, 2), "先抽牌仍受剩余牌数和手牌上限约束");
		_expect(state.draw_blocked_this_turn and state.discard_pile.size() == 1 and not state.is_invalid_battle(), "抽不足3张也施加禁抽，正在结算的卡不会抽回自身");
		controller.get_parent().queue_free();


func _test_weapon_return()->void:
	for full_hand in [false, true]:
		var weapon:CardDefinition = CardDefinition.new();
		weapon.card_id = "test_eternal";
		weapon.card_name = "测试永恒";
		weapon.description = "损坏后回手。";
		weapon.card_type = CardDefinition.CardType.WEAPON;
		weapon.is_innate = true;
		weapon.weapon_definition = WeaponDefinition.new();
		weapon.weapon_definition.base_attack = 3;
		weapon.weapon_definition.base_max_durability = 1;
		weapon.weapon_definition.break_destination = WeaponDefinition.BreakDestination.RETURN_TO_HAND;
		var controller:BattleController = _controller([weapon, _card()], 10, 2 if full_hand else 10);
		var state:BattleState = controller.battle_state;
		var opening:Array[CardInstance] = state.hand.duplicate();
		var weapon_card:CardInstance;
		for card in opening:
			if card.definition == weapon:
				weapon_card = card;
				controller._on_card_selected(card);
		for card in opening:
			if card.definition != weapon:
				controller._on_card_selected(card);
		_expect(state.draw_blocked_this_turn and state.attack_with_weapon(), "禁抽期间仍可正常进行武器攻击");
		if full_hand:
			_expect(state.discard_pile.has(weapon_card), "禁抽期间满手的永恒仍进入弃牌堆");
		else:
			_expect(state.hand.has(weapon_card), "禁抽不影响永恒原实例回手");
		_expect(state.equipped_weapon == null and state.exhaust_pile.is_empty() and not state.is_invalid_battle(), "损坏归档正确且卡牌数量守恒");
		controller.get_parent().queue_free();
