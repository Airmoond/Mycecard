## 易伤、虚弱的数值、整轮时序、目标与预览检查。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_damage_formula();
	_test_stacking_and_first_tick();
	_test_player_debuffs_enemy();
	_test_enemy_debuffs_player();
	_test_player_self_debuffs();
	_test_effect_order_and_preview();
	_test_weapon_statuses();
	_test_non_attack_and_health_loss();
	_test_new_battle_reset();
	await process_frame;
	print("易伤与虚弱检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _effect(type:CombatEffectDefinition.EffectType, amount:int, target:CombatEffectDefinition.TargetType = CombatEffectDefinition.TargetType.OPPONENT)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = type;
	effect.amount = amount;
	effect.target_type = target;
	return effect;


func _card(effects:Array[CombatEffectDefinition])->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_status";
	definition.card_name = "测试状态";
	definition.description = "仅用于状态回归检查。";
	definition.base_energy_cost = 0;
	definition.effects = effects;
	return definition;


func _action(effects:Array[CombatEffectDefinition])->EnemyActionDefinition:
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_action";
	action.intent_text = "测试行动";
	action.effects = effects;
	return action;


func _controller(definitions:Array[CardDefinition], actions:Array[EnemyActionDefinition])->BattleController:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate();
	encounter.enemy_definition = encounter.enemy_definition.duplicate();
	encounter.enemy_definition.action_pattern = actions;
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), definitions, 50, 50), "状态测试战斗应启动");
	return controller;


func _in_hand(controller:BattleController, definition:CardDefinition)->CardInstance:
	for card in controller.battle_state.hand:
		if card.definition == definition:
			return card;
	return null;


func _attack()->EnemyActionDefinition:
	return _action([_effect(CombatEffectDefinition.EffectType.DAMAGE, 6)]);


func _test_damage_formula()->void:
	_expect(AttackDamageResolver.calculate(8, 2, true, true) == 11, "8基础加2力量，同时虚弱和易伤应为11");
	_expect(AttackDamageResolver.calculate(7, 0, true, true) == 7, "7基础同时虚弱易伤不能在中途取整");
	_expect(AttackDamageResolver.calculate(6, 0, true, false) == 4, "单独虚弱为0.75倍后向下取整");
	_expect(AttackDamageResolver.calculate(6, 0, false, true) == 9, "单独易伤为1.5倍");
	_expect(AttackDamageResolver.calculate(0, 0, true, true) == 0, "0基础伤害仍为0");


func _test_stacking_and_first_tick()->void:
	var target:CombatantState = CombatantState.new();
	target.combatant_init("测试", 50);
	target.apply_weak(2, false);
	target.apply_weak(1, true);
	target.apply_vulnerable(1, true);
	target.apply_vulnerable(1, true);
	target.tick_statuses_at_round_end();
	_expect(target.weak_turns == 2, "已有虚弱再受敌人施加，不重新跳过递减");
	_expect(target.vulnerable_turns == 2, "首次由敌人施加后同轮叠加，仍只跳过一次");
	target.tick_statuses_at_round_end();
	_expect(target.weak_turns == 1 and target.vulnerable_turns == 1, "之后每个整轮各减1，不改变倍率");
	target.tick_statuses_at_round_end();
	_expect(target.weak_turns == 0 and target.vulnerable_turns == 0, "状态到0后结束");
	target.apply_weak(1, true);
	target.apply_vulnerable(1, false);
	target.tick_statuses_at_round_end();
	_expect(target.weak_turns == 1 and target.vulnerable_turns == 0, "两种状态分别记录首次施加，不共享标记");


func _test_player_debuffs_enemy()->void:
	var debuff:CardDefinition = _card([_effect(CombatEffectDefinition.EffectType.APPLY_WEAK, 1), _effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1)]);
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var controller:BattleController = _controller([debuff, strike], [_attack()]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(_in_hand(controller, debuff));
	_expect(controller.enemy_view.weak_label.visible and controller.enemy_view.vulnerable_label.text == "易伤：1 回合", "界面应显示两种状态的剩余时间");
	_expect(controller.enemy_view.intent_label.text.contains("4点伤害"), "1回合虚弱应立即更新敌人意图");
	controller._on_card_selected(_in_hand(controller, strike));
	_expect(state.enemy_state.current_health == 21, "1回合易伤应影响同回合后续攻击");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 46, "虚弱必须保留到敌人攻击执行时");
	_expect(state.enemy_state.weak_turns == 0 and state.enemy_state.vulnerable_turns == 0, "本轮敌人行动后状态结束");
	_expect(not controller.enemy_view.weak_label.visible and controller.enemy_view.intent_label.text.contains("6点伤害"), "到期后隐藏状态并恢复意图伤害");
	controller.get_parent().queue_free();


func _test_enemy_debuffs_player()->void:
	var debuff:EnemyActionDefinition = _action([_effect(CombatEffectDefinition.EffectType.APPLY_WEAK, 1), _effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1)]);
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var controller:BattleController = _controller([strike], [debuff, _attack()]);
	var state:BattleState = controller.battle_state;
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.weak_turns == 1 and state.player_state.vulnerable_turns == 1, "敌人首次施加1回合状态应保留到下一玩家回合");
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 26, "下一玩家回合攻击受到虚弱影响");
	_expect(controller.enemy_view.intent_label.text.contains("9点伤害"), "下一次敌人攻击预览受到玩家易伤影响");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 41, "玩家易伤应保留至敌人攻击完成");
	_expect(state.player_state.weak_turns == 0 and state.player_state.vulnerable_turns == 0, "完整影响一轮后到期");
	controller.get_parent().queue_free();
	controller = _controller([strike], [debuff]);
	controller._on_end_turn_button_pressed();
	controller._on_end_turn_button_pressed();
	_expect(controller.battle_state.player_state.weak_turns == 1 and controller.battle_state.player_state.vulnerable_turns == 1, "已有1层时再次加1，应在整轮结束减回1而非重新跳过");
	controller.get_parent().queue_free();


func _test_player_self_debuffs()->void:
	var definition:CardDefinition = _card([
		_effect(CombatEffectDefinition.EffectType.APPLY_WEAK, 1, CombatEffectDefinition.TargetType.SELF),
		_effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1, CombatEffectDefinition.TargetType.SELF),
		_effect(CombatEffectDefinition.EffectType.DAMAGE, 6)
	]);
	var controller:BattleController = _controller([definition], [_attack()]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 26, "玩家自施虚弱立即影响本卡后续攻击");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 41, "玩家自施易伤保留至本轮敌人攻击");
	_expect(state.player_state.weak_turns == 0 and state.player_state.vulnerable_turns == 0, "玩家自己施加不跳过首次整轮递减");
	controller.get_parent().queue_free();


func _test_effect_order_and_preview()->void:
	var repeated:CombatEffectDefinition = _effect(CombatEffectDefinition.EffectType.DAMAGE, 3);
	repeated.repeat_count = 2;
	var definition:CardDefinition = _card([_effect(CombatEffectDefinition.EffectType.DAMAGE, 3), _effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1), repeated]);
	var controller:BattleController = _controller([definition], [_attack()]);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.enemy_state.current_health == 19, "先攻击3，再易伤后攻击4两次，状态不能追溯影响前段");
	controller.get_parent().queue_free();
	var attack:CombatEffectDefinition = _effect(CombatEffectDefinition.EffectType.DAMAGE, 6);
	attack.repeat_count = 2;
	var action:EnemyActionDefinition = _action([
		_effect(CombatEffectDefinition.EffectType.APPLY_WEAK, 1, CombatEffectDefinition.TargetType.SELF),
		_effect(CombatEffectDefinition.EffectType.APPLY_VULNERABLE, 1), attack
	]);
	controller = _controller([load("res://cards/data/defend.tres")], [action]);
	_expect(controller.enemy_view.intent_label.text.contains("6点伤害 × 2"), "意图应按顺序预览本次自施虚弱和施加易伤");
	controller.battle_state.player_state.current_block = 4;
	controller._on_end_turn_button_pressed();
	_expect(controller.battle_state.player_state.current_health == 42, "两段6伤害抵消4格挡后应损失8生命，与预览一致");
	controller.get_parent().queue_free();


func _test_weapon_statuses()->void:
	var definition:CardDefinition = _card([]);
	definition.card_type = CardDefinition.CardType.WEAPON;
	definition.weapon_definition = WeaponDefinition.new();
	definition.weapon_definition.base_attack = 7;
	definition.weapon_definition.base_max_durability = 2;
	var controller:BattleController = _controller([definition], [_attack()]);
	var state:BattleState = controller.battle_state;
	state.player_state.apply_weak(1, false);
	state.enemy_state.apply_vulnerable(1, false);
	controller._on_card_selected(state.hand[0]);
	var attack_view:Button = controller.hand_area.get_node("weapon_attack");
	_expect(attack_view.tooltip_text == "预计伤害：7（格挡前）", "武器预览应同时计算虚弱与易伤并最后取整");
	attack_view.pressed.emit();
	_expect(state.enemy_state.current_health == 23 and state.equipped_weapon.weapon.current_durability == 1, "武器伤害与预览一致，倍率不影响耐久消耗");
	controller.get_parent().queue_free();


func _test_non_attack_and_health_loss()->void:
	var damage:CombatEffectDefinition = _effect(CombatEffectDefinition.EffectType.DAMAGE, 6);
	damage.is_attack_damage = false;
	var definition:CardDefinition = _card([damage, _effect(CombatEffectDefinition.EffectType.LOSE_HEALTH, 2, CombatEffectDefinition.TargetType.SELF)]);
	var controller:BattleController = _controller([definition], [_attack()]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_strength(8);
	state.player_state.apply_weak(2, false);
	state.player_state.apply_vulnerable(2, false);
	state.enemy_state.apply_vulnerable(2, false);
	state.enemy_state.current_block = 2;
	state.player_state.current_block = 9;
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 26, "非攻击伤害不受力量、虚弱、易伤影响，仍扣格挡");
	_expect(state.player_state.current_health == 48 and state.player_state.current_block == 9, "失血完全绕过攻击修正和格挡");
	controller.get_parent().queue_free();


func _test_new_battle_reset()->void:
	var definition:CardDefinition = load("res://cards/data/defend.tres");
	var controller:BattleController = _controller([definition], [_attack()]);
	controller.battle_state.player_state.apply_weak(3, true);
	controller.battle_state.enemy_state.apply_vulnerable(3, true);
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [definition], 50, 50), "新战斗应启动");
	var state:BattleState = controller.battle_state;
	_expect(state.player_state.weak_turns == 0 and state.enemy_state.vulnerable_turns == 0, "新战斗不能继承状态");
	_expect(not controller.player_view.weak_label.visible and not controller.enemy_view.vulnerable_label.visible, "新战斗不能残留状态显示");
	state.player_state.apply_weak(1, true);
	state.player_state.combatant_init_from_definition(load("res://combatants/players/data/player.tres"));
	state.player_state.apply_weak(1, false);
	state.player_state.tick_statuses_at_round_end();
	_expect(state.player_state.weak_turns == 0, "重新初始化同一角色也清空首次递减标记");
	controller.get_parent().queue_free();
