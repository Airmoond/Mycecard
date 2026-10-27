## 鲜血狂宴：按实际失血治疗，验证格挡、过量伤害、费用、归档和胜负时序。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_healing_amount();
	_test_max_health();
	_test_modifiers();
	_test_multihit();
	_test_lethal_attack();
	_test_insufficient_energy();
	_test_health_loss_order();
	_test_enemy_healing();
	await process_frame;
	print("按伤害治疗检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _damage(amount:int, heals:bool = true)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.DAMAGE;
	effect.target_type = CombatEffectDefinition.TargetType.OPPONENT;
	effect.amount = amount;
	effect.heals_from_damage = heals;
	return effect;


func _card()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	definition.card_id = "test_damage_healing";
	definition.card_name = "测试鲜血狂宴";
	definition.description = "造成{damage_0}点伤害，按实际失血回血。消耗。";
	definition.base_energy_cost = 2;
	definition.exhausts_on_play = true;
	definition.effects = [_damage(10)];
	return definition;


func _health_loss(amount:int)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.LOSE_HEALTH;
	effect.target_type = CombatEffectDefinition.TargetType.SELF;
	effect.amount = amount;
	return effect;


func _controller(definition:CardDefinition, enemy_effects:Array[CombatEffectDefinition] = [])->BattleController:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres");
	if not enemy_effects.is_empty():
		encounter = encounter.duplicate();
		encounter.enemy_definition = encounter.enemy_definition.duplicate();
		var action:EnemyActionDefinition = EnemyActionDefinition.new();
		action.action_id = "test_damage_healing";
		action.intent_text = "测试行动";
		action.effects = enemy_effects;
		encounter.enemy_definition.action_pattern = [action];
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), [definition], 20, 50), "治疗测试战斗应能以20生命启动");
	return controller;


func _test_healing_amount()->void:
	# 每行依次为敌人格挡、敌人生命、预期实际失血。
	for values in [[0, 30, 10], [3, 30, 7], [30, 30, 0], [3, 4, 4]]:
		var definition:CardDefinition = _card();
		var controller:BattleController = _controller(definition);
		var state:BattleState = controller.battle_state;
		state.enemy_state.gain_block(values[0]);
		state.enemy_state.current_health = values[1];
		var card:CardInstance = state.hand[0];
		controller._on_card_selected(card);
		_expect(state.player_state.current_health == 20 + values[2], "回血等于实际失血，排除格挡和过量伤害：%s" % str(values));
		_expect(state.enemy_state.current_health == values[1] - values[2], "伤害结算与治疗来源一致");
		_expect(state.current_available_energy == 1 and state.exhaust_pile.has(card) and state.resolving_card == null, "2费攻击在治疗后完成消耗归档");
		_expect(definition.effects[0].amount == 10, "治疗不修改卡牌基础数值");
		controller.get_parent().queue_free();


func _test_max_health()->void:
	var target:CombatantState = CombatantState.new();
	target.combatant_init("治疗目标", 50);
	target.current_health = 48;
	_expect(target.heal(10) == 2 and target.current_health == 50, "治疗方法返回实际恢复量，不超过最大生命");
	_expect(target.heal(0) == 0 and target.heal(10) == 0 and target.current_health == 50, "0治疗与满生命治疗均不增加生命");
	for health in [49, 50]:
		var controller:BattleController = _controller(_card());
		controller.battle_state.player_state.current_health = health;
		controller._on_card_selected(controller.battle_state.hand[0]);
		_expect(controller.battle_state.player_state.current_health == 50 and controller.battle_state.enemy_state.current_health == 20, "治疗封顶不减少本次攻击伤害");
		controller.get_parent().queue_free();


func _test_modifiers()->void:
	for is_attack in [true, false]:
		var definition:CardDefinition = _card();
		definition.effects[0].is_attack_damage = is_attack;
		var controller:BattleController = _controller(definition);
		var state:BattleState = controller.battle_state;
		state.player_state.gain_strength(2);
		state.player_state.apply_weak(1, false);
		state.enemy_state.apply_vulnerable(1, false);
		state.enemy_state.gain_block(3);
		controller._refresh_battle_view();
		var view:CardView = controller.hand_area.get_child(0);
		_expect(view.card_face.description_label.text.begins_with("造成%d点伤害" % (13 if is_attack else 10)), "伤害预览沿用类别与倍率规则");
		controller._on_card_selected(state.hand[0]);
		var actual_loss:int = 10 if is_attack else 7;
		_expect(state.player_state.current_health == 20 + actual_loss and state.enemy_state.current_health == 30 - actual_loss, "回血读取修正并抵消格挡后的实际失血，不再次乘倍率");
		controller.get_parent().queue_free();


func _test_multihit()->void:
	var definition:CardDefinition = _card();
	var repeated:CombatEffectDefinition = _damage(5);
	repeated.repeat_count = 3;
	definition.effects = [_damage(3, false), repeated];
	var controller:BattleController = _controller(definition);
	var state:BattleState = controller.battle_state;
	state.enemy_state.current_health = 9;
	state.enemy_state.gain_block(1);
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 0 and state.player_state.current_health == 27, "普通伤害先扣2不回血；后续三段只按5、2、0回血，无前次伤害残留");
	controller.get_parent().queue_free();


func _test_lethal_attack()->void:
	var definition:CardDefinition = _card();
	var controller:BattleController = _controller(definition);
	var state:BattleState = controller.battle_state;
	state.enemy_state.current_health = 4;
	state.enemy_state.gain_block(3);
	var card:CardInstance = state.hand[0];
	var health_results:Array[int] = [];
	controller.battle_finished.connect(func(victory:bool, health:int, _max_health:int)->void:
		health_results.append(health);
		_expect(victory and health == 24, "胜利信号必须携带治疗后的生命，供整局流程回写");
		_expect(state.exhaust_pile.has(card) and state.resolving_card == null, "报告胜利前完成消耗归档");
	);
	controller._on_card_selected(card);
	controller._on_card_selected(card);
	_expect(health_results.size() == 1 and not state.is_invalid_battle(), "重复点击不重复治疗或报告结果，牌区保持守恒");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [definition], health_results[0], 50), "后续战斗可使用治疗后的生命启动");
	_expect(controller.battle_state.player_state.current_health == 24 and controller.battle_state.exhaust_pile.is_empty(), "生命正确延续，消耗记录不跨战斗");
	controller.get_parent().queue_free();


func _test_insufficient_energy()->void:
	var controller:BattleController = _controller(_card());
	var state:BattleState = controller.battle_state;
	state.current_available_energy = 1;
	var card:CardInstance = state.hand[0];
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 1 and state.hand.has(card) and state.exhaust_pile.is_empty(), "费用不足不扣费、不移牌");
	_expect(state.player_state.current_health == 20 and state.enemy_state.current_health == 30, "费用不足不造成伤害或治疗");
	controller.get_parent().queue_free();


func _test_health_loss_order()->void:
	var definition:CardDefinition = _card();
	definition.effects.push_front(_health_loss(20));
	var controller:BattleController = _controller(definition);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.is_defeat() and controller.battle_state.enemy_state.current_health == 30 and controller.battle_state.exhaust_pile.size() == 1, "前序失血致死会中断后续攻击与治疗，仍归档失败");
	controller.get_parent().queue_free();
	definition = _card();
	definition.effects.append(_health_loss(25));
	controller = _controller(definition);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.player_state.current_health == 5 and not controller.battle_state.is_defeat(), "先伤害回血至30，再失去25生命，治疗不能延迟到全卡效果结束");
	controller.get_parent().queue_free();


func _test_enemy_healing()->void:
	var controller:BattleController = _controller(load("res://cards/data/defend.tres"), [_damage(6)]);
	var state:BattleState = controller.battle_state;
	state.enemy_state.current_health = 10;
	state.player_state.gain_block(2);
	controller._refresh_battle_view();
	_expect(controller.enemy_view.intent_label.text.contains("按目标失血回血"), "敌人意图说明按伤害治疗");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 16 and state.enemy_state.current_health == 14, "治疗目标是本次行动者，敌人同样读取实际失血");
	controller.get_parent().queue_free();
