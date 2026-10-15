## 按当前格挡造成伤害：结算时取值、状态修正、预览与回合清理。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_strength_and_modifiers();
	_test_zero_block_and_cost();
	_test_effect_order();
	_test_execution_time_and_repeats();
	_test_retained_block();
	_test_enemy_preview();
	_test_non_attack_and_reward();
	await process_frame;
	print("格挡伤害检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _shield_effect()->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.DAMAGE;
	effect.target_type = CombatEffectDefinition.TargetType.OPPONENT;
	effect.damage_source = CombatEffectDefinition.DamageSource.CURRENT_BLOCK;
	return effect;


func _shield_card()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	definition.card_id = "test_shield_attack";
	definition.card_name = "测试盾牌猛击";
	definition.description = "造成{damage_0}点伤害，基础伤害等于当前格挡。";
	definition.effects = [_shield_effect()];
	return definition;


func _effect(type:CombatEffectDefinition.EffectType, amount:int, target:CombatEffectDefinition.TargetType)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = type;
	effect.amount = amount;
	effect.target_type = target;
	return effect;


func _controller(cards:Array[CardDefinition], enemy_effects:Array[CombatEffectDefinition] = [])->BattleController:
	var encounter:EncounterDefinition = load("res://battle/data/encounters/cave_crawler_encounter.tres").duplicate();
	encounter.enemy_definition = encounter.enemy_definition.duplicate();
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_block_damage";
	action.intent_text = "测试行动";
	if enemy_effects.is_empty():
		enemy_effects = [_effect(CombatEffectDefinition.EffectType.DAMAGE, 7, CombatEffectDefinition.TargetType.OPPONENT)];
	action.effects = enemy_effects;
	encounter.enemy_definition.action_pattern = [action];
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/data/player.tres"), cards, 50, 50), "格挡伤害测试应正常启动");
	return controller;


func _view(controller:BattleController, definition:CardDefinition)->CardView:
	for child in controller.hand_area.get_children():
		if child is CardView and child.card_instance.definition == definition:
			return child;
	return null;


func _test_strength_and_modifiers()->void:
	for with_statuses in [false, true]:
		var definition:CardDefinition = _shield_card();
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		state.player_state.gain_block(10);
		state.player_state.gain_strength(2);
		if with_statuses:
			state.player_state.apply_weak(1, false);
			state.enemy_state.apply_vulnerable(1, false);
			state.enemy_state.gain_block(3);
		controller._refresh_battle_view();
		var damage:int = 13 if with_statuses else 12;
		_expect(_view(controller, definition).card_face.description_label.text.begins_with("造成%d点伤害" % damage), "格挡加力量，再乘倍率并最终取整");
		controller._on_card_selected(state.hand[0]);
		_expect(state.enemy_state.current_health == (20 if with_statuses else 18), "实伤与格挡前预览一致，再扣目标格挡");
		_expect(state.player_state.current_block == 10 and state.current_available_energy == 2 and state.discard_pile.size() == 1, "攻击不消耗自身格挡，正常扣费和弃置");
		_expect(definition.effects[0].amount == 0, "动态数值不写回静态配置");
		controller.get_parent().queue_free();


func _test_zero_block_and_cost()->void:
	for strength in [0, 2]:
		var definition:CardDefinition = _shield_card();
		_expect(not definition.is_invalid(), "动态伤害不需要伪造正数amount");
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		state.player_state.gain_strength(strength);
		controller._refresh_battle_view();
		_expect(controller._card_is_playable(state.hand[0]), "0格挡时仍可正常使用");
		_expect(_view(controller, definition).card_face.description_label.text.begins_with("造成%d点伤害" % strength), "0格挡仍按规则加力量");
		controller._on_card_selected(state.hand[0]);
		_expect(state.enemy_state.current_health == 30 - strength and state.current_available_energy == 2, "0基础伤害正常结算并支付费用");
		controller.get_parent().queue_free();
	var definition:CardDefinition = _shield_card();
	var controller:BattleController = _controller([definition]);
	controller.battle_state.current_available_energy = 0;
	controller.battle_state.player_state.gain_block(10);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.hand.size() == 1 and controller.battle_state.enemy_state.current_health == 30, "费用不足时不造成伤害、不移走卡牌");
	controller.get_parent().queue_free();


func _test_effect_order()->void:
	var definition:CardDefinition = _shield_card();
	var block:CombatEffectDefinition = _effect(CombatEffectDefinition.EffectType.BLOCK, 3, CombatEffectDefinition.TargetType.SELF);
	block.repeat_count = 2;
	definition.effects = [_shield_effect(), block, _shield_effect()];
	definition.description = "先造成{damage_0}点伤害，获得格挡，再造成{damage_2}点伤害。";
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_block(2);
	state.player_state.gain_strength(1);
	controller._refresh_battle_view();
	_expect(_view(controller, definition).card_face.description_label.text == "先造成3点伤害，获得格挡，再造成9点伤害。", "预览按顺序计入本卡先前获得的格挡，不影响前段");
	_expect(state.player_state.current_block == 2 and state.enemy_state.current_health == 30, "预览不改变真实格挡或生命");
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 18 and state.player_state.current_block == 8, "实际结算时先打3，再获得6格挡，再打9");
	controller.get_parent().queue_free();


func _test_execution_time_and_repeats()->void:
	var actor:CombatantState = CombatantState.new();
	var target:CombatantState = CombatantState.new();
	actor.combatant_init("攻击者", 50);
	target.combatant_init("受击者", 50);
	actor.gain_block(2);
	actor.gain_strength(1);
	var queue:ActionQueue = ActionQueue.new();
	queue.queue_damage_effect(actor, target, _shield_effect());
	actor.gain_block(5);
	_expect(queue.resolve_all() and target.current_health == 42, "入队后格挡发生变化，也应在执行时读到7格挡加1力量");
	var definition:CardDefinition = _shield_card();
	definition.effects[0].repeat_count = 2;
	var controller:BattleController = _controller([definition]);
	controller.battle_state.player_state.gain_block(5);
	controller.battle_state.player_state.gain_strength(2);
	controller.battle_state.enemy_state.gain_block(9);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.enemy_state.current_health == 25 and controller.battle_state.enemy_state.current_block == 0, "两段7伤害分别抵消9格挡，实际损失5生命");
	_expect(controller.battle_state.player_state.current_block == 5, "重复攻击也不消耗自身格挡");
	controller.get_parent().queue_free();


func _test_retained_block()->void:
	for retains_block in [false, true]:
		var definition:CardDefinition = _shield_card();
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		state.player_state.gain_block(12);
		if retains_block:
			state.player_state.apply_power(load("res://battle/powers/data/retain_block.tres"));
		controller._on_end_turn_button_pressed();
		var damage:int = 5 if retains_block else 0;
		_expect(_view(controller, definition).card_face.description_label.text.begins_with("造成%d点伤害" % damage), "下一回合预览读取坚城保留后的格挡，或正常清理后的0");
		controller._on_card_selected(state.hand[0]);
		_expect(state.enemy_state.current_health == 30 - damage, "坚城保留格挡与盾牌猛击结算一致");
		controller.get_parent().queue_free();


func _test_enemy_preview()->void:
	for retains_block in [false, true]:
		var controller:BattleController = _controller([load("res://cards/data/defend.tres")], [
			_effect(CombatEffectDefinition.EffectType.BLOCK, 4, CombatEffectDefinition.TargetType.SELF), _shield_effect()
		]);
		var state:BattleState = controller.battle_state;
		state.enemy_state.gain_block(20);
		if retains_block:
			state.enemy_state.apply_power(load("res://battle/powers/data/retain_block.tres"));
		controller._refresh_battle_view();
		var damage:int = 24 if retains_block else 4;
		_expect(controller.enemy_view.intent_label.text.contains("%d点伤害" % damage), "敌人意图先考虑旧格挡清理，再计算行动内新格挡");
		controller._on_end_turn_button_pressed();
		_expect(state.player_state.current_health == 50 - damage, "敌人实际格挡伤害与意图一致");
		controller.get_parent().queue_free();


func _test_non_attack_and_reward()->void:
	var definition:CardDefinition = _shield_card();
	definition.effects[0].is_attack_damage = false;
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_block(5);
	state.player_state.gain_strength(8);
	state.player_state.apply_weak(1, false);
	state.enemy_state.apply_vulnerable(1, false);
	state.enemy_state.gain_block(3);
	controller._refresh_battle_view();
	_expect(_view(controller, definition).card_face.description_label.text.begins_with("造成5点伤害"), "伤害来源不改变显式的非攻击类别");
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 28, "非攻击伤害读取5格挡但不应用攻击修正");
	var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
	root.add_child(reward);
	reward.setup(definition);
	_expect(reward.card_definition == definition, "动态伤害奖励卡可以绑定");
	_expect(reward.card_face.description_label.text == "造成X点伤害，基础伤害等于当前格挡。", "战斗外显示X和来源说明，不把缺少上下文当成0伤害");
	reward.queue_free();
	controller.get_parent().queue_free();
