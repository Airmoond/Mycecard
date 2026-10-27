## 力量的实际出牌、攻击与预览检查；测试资源不加入正式卡池。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_power_and_lifetime();
	_test_multihit();
	_test_effect_order();
	_test_non_attack_and_health_loss();
	_test_weapon_strength();
	_test_enemy_strength_preview();
	await process_frame;
	print("力量检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _strength_effect()->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.GAIN_STRENGTH;
	effect.amount = 2;
	return effect;


func _power()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_strength";
	definition.card_name = "测试力量";
	definition.description = "获得2力量。";
	definition.card_type = CardDefinition.CardType.POWER;
	definition.effects = [_strength_effect()];
	return definition;


func _controller(definitions:Array[CardDefinition], encounter:EncounterDefinition = null)->BattleController:
	if encounter == null:
		encounter = load("res://battle/encounters/data/cave_crawler_encounter.tres");
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), definitions, 50, 50), "力量测试战斗应启动");
	return controller;


func _in_hand(controller:BattleController, definition:CardDefinition)->CardInstance:
	for card in controller.battle_state.hand:
		if card.definition == definition:
			return card;
	return null;


func _test_power_and_lifetime()->void:
	var power:CardDefinition = _power();
	var controller:BattleController = _controller([power, power]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	state.current_available_energy = 0;
	controller._on_card_selected(card);
	_expect(state.player_state.strength == 0 and state.hand.has(card), "费用不足不能获得力量或移牌");
	state.current_available_energy = 3;
	controller._on_card_selected(card);
	controller._on_card_selected(state.hand[0]);
	_expect(state.player_state.strength == 4 and state.current_available_energy == 1, "两次力量增益应叠加并正常扣费");
	_expect(state.played_power_cards.size() == 2 and state.exhaust_pile.is_empty(), "即时力量能力牌退出循环，不要求持续监听器");
	_expect(controller.player_view.strength_label.text == "力量：4" and controller.player_view.strength_label.visible, "界面应显示力量");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.strength == 4, "力量不随回合衰减");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [power], 50, 50), "下一场战斗应启动");
	_expect(controller.battle_state.player_state.strength == 0 and not controller.player_view.strength_label.visible, "新战斗清空力量并隐藏标签");
	controller.get_parent().queue_free();


func _test_multihit()->void:
	var definition:CardDefinition = load("res://cards/data/double_strike.tres");
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_strength(2);
	state.enemy_state.current_block = 6;
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 22 and state.enemy_state.current_block == 0, "5伤害两次加2力量，应逐段造成7伤害，再抵消6格挡");
	_expect(definition.effects[0].amount == 5, "力量不能修改静态卡牌伤害");
	controller.get_parent().queue_free();


func _test_effect_order()->void:
	for strength_first in [true, false]:
		var definition:CardDefinition = _power();
		definition.card_type = CardDefinition.CardType.SKILL;
		var damage:CombatEffectDefinition = load("res://cards/data/double_strike.tres").effects[0];
		definition.effects.append(damage);
		if not strength_first:
			definition.effects.reverse();
		var controller:BattleController = _controller([definition]);
		controller._on_card_selected(controller.battle_state.hand[0]);
		var expected_health:int = 16 if strength_first else 20;
		_expect(controller.battle_state.enemy_state.current_health == expected_health, "攻击执行时读取力量，效果先后顺序应影响伤害");
		_expect(controller.battle_state.player_state.strength == 2, "两种顺序都应获得2力量");
		controller.get_parent().queue_free();


func _test_non_attack_and_health_loss()->void:
	var definition:CardDefinition = _power();
	var damage:CombatEffectDefinition = CombatEffectDefinition.new();
	damage.effect_type = CombatEffectDefinition.EffectType.DAMAGE;
	damage.target_type = CombatEffectDefinition.TargetType.OPPONENT;
	damage.amount = 3;
	damage.is_attack_damage = false;
	var loss:CombatEffectDefinition = CombatEffectDefinition.new();
	loss.effect_type = CombatEffectDefinition.EffectType.LOSE_HEALTH;
	loss.amount = 2;
	definition.effects = [damage, loss];
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_strength(8);
	state.player_state.current_block = 9;
	state.enemy_state.current_block = 2;
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 29, "非攻击伤害不加力量，但仍受格挡抵消");
	_expect(state.player_state.current_health == 48 and state.player_state.current_block == 9, "直接失血不受力量或格挡影响");
	controller.get_parent().queue_free();


func _test_weapon_strength()->void:
	for base_attack in [0, 3]:
		var definition:CardDefinition = _power();
		definition.card_type = CardDefinition.CardType.WEAPON;
		definition.effects = [];
		definition.weapon_definition = WeaponDefinition.new();
		definition.weapon_definition.base_attack = base_attack;
		definition.weapon_definition.base_max_durability = 1;
		definition.weapon_definition.break_destination = WeaponDefinition.BreakDestination.RETURN_TO_HAND;
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		state.player_state.gain_strength(2);
		controller._on_card_selected(card);
		var attack_view:Button = controller.hand_area.get_node("weapon_attack");
		_expect(attack_view.tooltip_text == "预计伤害：%d（格挡前）" % (base_attack + 2), "武器预览应计算角色力量");
		attack_view.pressed.emit();
		_expect(state.enemy_state.current_health == 30 - base_attack - 2, "武器实际伤害应与预览一致，包括0基础攻击");
		_expect(state.hand.has(card) and card.weapon.current_durability == 0, "力量不影响1点耐久损耗与回手");
		controller._on_card_selected(card);
		_expect(card.weapon.current_attack == base_attack and state.player_state.strength == 2, "回手重装不能把角色力量累加进武器数值");
		controller.get_parent().queue_free();


func _test_enemy_strength_preview()->void:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate();
	encounter.enemy_definition = encounter.enemy_definition.duplicate();
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_strength_attack";
	action.intent_text = "强化攻击";
	action.effects = [_strength_effect(), load("res://cards/data/double_strike.tres").effects[0]];
	encounter.enemy_definition.action_pattern = [action];
	var controller:BattleController = _controller([load("res://cards/data/defend.tres")], encounter);
	var state:BattleState = controller.battle_state;
	_expect(controller.enemy_view.intent_label.text.contains("7点伤害 × 2"), "敌人意图应包含本次先获得的力量");
	state.player_state.current_block = 6;
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 42 and state.enemy_state.strength == 2, "敌人攻击应与预览一致，逐段加力量并抵消格挡");
	_expect(controller.enemy_view.strength_label.text == "力量：2", "敌人界面应显示实际力量");
	_expect(controller.enemy_view.intent_label.text.contains("9点伤害 × 2"), "下次意图应基于已获得的力量继续预览");
	controller.get_parent().queue_free();
