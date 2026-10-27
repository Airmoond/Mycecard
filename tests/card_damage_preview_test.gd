## 验证手牌伤害、状态变化后的刷新、效果顺序与奖励基础文案。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_base_descriptions();
	_test_hand_refresh_and_execution();
	_test_effect_order();
	_test_target_and_damage_category();
	_test_reward_description();
	await process_frame;
	print("卡牌伤害预览检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _effect(type:CombatEffectDefinition.EffectType, amount:int, target:CombatEffectDefinition.TargetType)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = type;
	effect.amount = amount;
	effect.target_type = target;
	return effect;


func _combatant()->CombatantState:
	var state:CombatantState = CombatantState.new();
	state.combatant_init("预览测试", 50);
	return state;


func _view(controller:BattleController, definition:CardDefinition)->CardView:
	for child in controller.hand_area.get_children():
		if child is CardView and child.card_instance.definition == definition:
			return child;
	return null;


func _test_base_descriptions()->void:
	var expected:Dictionary = {
		"strike": "造成6点伤害",
		"double_strike": "造成5点伤害2次。",
		"attack_and_block": "获得3点格挡，然后造成4点伤害",
		"heavy_strike": "造成12点伤害"
	};
	for card_id in expected:
		var definition:CardDefinition = load("res://cards/data/%s.tres" % card_id);
		_expect(definition.format_description() == expected[card_id], "基础显示应保持原文案：%s" % card_id);
	var defend:CardDefinition = load("res://cards/data/defend.tres");
	_expect(defend.format_description() == defend.description, "无伤害占位符的文案不变");


func _test_hand_refresh_and_execution()->void:
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var double_strike:CardDefinition = load("res://cards/data/double_strike.tres");
	var buff:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	buff.base_energy_cost = 0;
	buff.effects = [
		_effect(CombatEffectDefinition.EffectType.GAIN_STRENGTH, 2, CombatEffectDefinition.TargetType.SELF),
		_effect(CombatEffectDefinition.EffectType.APPLY_WEAK, 1, CombatEffectDefinition.TargetType.SELF),
		_effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1, CombatEffectDefinition.TargetType.OPPONENT)
	];
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [strike, double_strike, buff], 50, 50), "预览测试战斗应启动");
	_expect(_view(controller, strike).card_face.description_label.text == "造成6点伤害", "初始手牌显示基础伤害");
	controller._on_card_selected(_view(controller, buff).card_instance);
	_expect(_view(controller, strike).card_face.description_label.text == "造成9点伤害", "打出状态牌后其余手牌应自动刷新");
	_expect(_view(controller, double_strike).card_face.description_label.text == "造成7点伤害2次。", "多段显示每段修正伤害并保留次数");
	controller._on_card_selected(_view(controller, double_strike).card_instance);
	_expect(controller.battle_state.enemy_state.current_health == 16, "两段实际伤害应为7加7");
	controller._on_end_turn_button_pressed();
	_expect(_view(controller, strike).card_face.description_label.text == "造成8点伤害", "状态到期后自动去掉倍率，保留力量");
	_expect(strike.description == "造成{damage_0}点伤害" and strike.effects[0].amount == 6, "预览不改写共享资源");
	page.queue_free();


func _test_effect_order()->void:
	var actor:CombatantState = _combatant();
	var target:CombatantState = _combatant();
	var gain:CombatEffectDefinition = _effect(CombatEffectDefinition.EffectType.GAIN_STRENGTH, 1, CombatEffectDefinition.TargetType.SELF);
	gain.repeat_count = 2;
	var definition:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	definition.effects = [
		_effect(CombatEffectDefinition.EffectType.DAMAGE, 3, CombatEffectDefinition.TargetType.OPPONENT), gain,
		_effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1, CombatEffectDefinition.TargetType.OPPONENT),
		_effect(CombatEffectDefinition.EffectType.DAMAGE, 3, CombatEffectDefinition.TargetType.OPPONENT)
	];
	definition.description = "先造成{damage_0}点伤害，加力量并施加易伤，再造成{damage_3}点伤害";
	var damages:Array[int] = AttackDamageResolver.preview_effect_damage(definition.effects, actor, target, actor.current_block);
	_expect(definition.format_description(damages) == "先造成3点伤害，加力量并施加易伤，再造成7点伤害", "每个占位符按效果顺序和数组下标取值");
	_expect(actor.strength == 0 and target.vulnerable_turns == 0 and target.current_health == 50, "计算预览不能真的施加状态或扣血");
	_expect(AttackDamageResolver.preview_effect_damage(definition.effects, actor, target, actor.current_block) == damages, "反复刷新不能叠加真实效果");


func _test_target_and_damage_category()->void:
	var actor:CombatantState = _combatant();
	var target:CombatantState = _combatant();
	actor.strength = 2;
	actor.weak_turns = 1;
	actor.vulnerable_turns = 1;
	var non_attack:CombatEffectDefinition = _effect(CombatEffectDefinition.EffectType.DAMAGE, 6, CombatEffectDefinition.TargetType.OPPONENT);
	non_attack.is_attack_damage = false;
	var effects:Array[CombatEffectDefinition] = [
		_effect(CombatEffectDefinition.EffectType.DAMAGE, 6, CombatEffectDefinition.TargetType.SELF),
		_effect(CombatEffectDefinition.EffectType.DAMAGE, 6, CombatEffectDefinition.TargetType.OPPONENT), non_attack,
		_effect(CombatEffectDefinition.EffectType.APPLY_WEAK, 1, CombatEffectDefinition.TargetType.OPPONENT),
		_effect(CombatEffectDefinition.EffectType.GAIN_STRENGTH, 8, CombatEffectDefinition.TargetType.OPPONENT),
		_effect(CombatEffectDefinition.EffectType.DAMAGE, 6, CombatEffectDefinition.TargetType.OPPONENT)
	];
	_expect(AttackDamageResolver.preview_effect_damage(effects, actor, target, actor.current_block) == [9, 6, 6, 0, 0, 6], "易伤读取目标，虚弱和力量读取攻击者；非攻击伤害不受修正");


func _test_reward_description()->void:
	var view:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
	root.add_child(view);
	view.setup(load("res://cards/data/attack_and_block.tres"));
	_expect(view.card_definition == load("res://cards/data/attack_and_block.tres"), "奖励卡应正常绑定");
	_expect(view.card_face.description_label.text == "获得3点格挡，然后造成4点伤害", "奖励页使用基础伤害且不显示占位符");
	view.queue_free();
