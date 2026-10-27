## 两名新Boss的固定四步循环、减益时序、多段攻击和资源隔离检查。
## 玩家仅持有不打出的防御牌，以1000血观察连续12次正式敌人行动。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_iron_crown_cycle();
	_test_calamity_timing();
	_test_multi_hit_rounding();
	await process_frame;
	print("新Boss机制检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _controller(enemy_id:String)->BattleController:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/%s_encounter.tres" % enemy_id);
	_expect(encounter != null and not encounter.is_invalid(), "新Boss遭遇应完整合法：%s" % enemy_id);
	if encounter == null or encounter.is_invalid():
		return null;
	_expect(encounter.enemy_definition.max_health > 0, "Boss生命应为合法正数");
	var player:CombatantDefinition = load("res://combatants/players/data/player.tres").duplicate();
	player.max_health = 1000;
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	var deck:Array[CardDefinition] = [load("res://cards/data/defend.tres")];
	if not controller.start_battle(encounter, player, deck, 1000, 1000):
		_expect(false, "新Boss机制战斗应启动：%s" % enemy_id);
		page.queue_free();
		return null;
	return controller;


func _definition_snapshot(enemy:EnemyDefinition)->Dictionary:
	var actions:Array = [];
	for action in enemy.action_pattern:
		var effects:Array = [];
		for effect in action.effects:
			effects.append([effect.effect_type, effect.target_type, effect.amount, effect.repeat_count]);
		actions.append({"id":action.action_id, "intent":action.intent_text, "effects":effects});
	return {"id":enemy.combatant_id, "health":enemy.max_health, "actions":actions};


func _state_snapshot(state:BattleState)->Array:
	return [
		state.player_state.current_health, state.player_state.current_block,
		state.player_state.strength, state.player_state.weak_turns, state.player_state.vulnerable_turns,
		state.enemy_state.current_health, state.enemy_state.current_block,
		state.enemy_state.strength, state.enemy_state.weak_turns, state.enemy_state.vulnerable_turns,
		state.enemy_state.current_action_index
	];


func _action_amount(action:EnemyActionDefinition, effect_type:int)->int:
	var total:int = 0;
	for effect in action.effects:
		if effect.effect_type == effect_type:
			total += effect.amount * effect.repeat_count;
	return total;


func _effect_types(action:EnemyActionDefinition)->Array[int]:
	var types:Array[int] = [];
	for effect in action.effects:
		types.append(effect.effect_type);
	return types;


func _expect_fixed_boss(enemy:EnemyDefinition)->bool:
	_expect(enemy.action_pattern.size() == 4, "新Boss应严格按四步固定行动循环");
	if enemy.action_pattern.size() != 4:
		return false;
	for action in enemy.action_pattern:
		for effect in action.effects:
			_expect(effect.effect_type != CombatEffectDefinition.EffectType.GAIN_STRENGTH, "新Boss使用固定循环，不应加入力量成长");
			if effect.effect_type == CombatEffectDefinition.EffectType.DAMAGE:
				_expect(effect.target_type == CombatEffectDefinition.TargetType.OPPONENT, "Boss攻击应指向玩家");
			elif effect.effect_type == CombatEffectDefinition.EffectType.BLOCK:
				_expect(effect.target_type == CombatEffectDefinition.TargetType.SELF, "Boss格挡应指向自身");
	var first:EnemyActionDefinition = enemy.action_pattern[0];
	var first_value:float = _action_amount(first, CombatEffectDefinition.EffectType.DAMAGE) / 12.0 + _action_amount(first, CombatEffectDefinition.EffectType.BLOCK) / 10.0;
	_expect(absf(first_value - 1.3) <= 0.05, "Boss首轮伤害与格挡直接价值应接近1.3");
	return true;


func _expect_intent(controller:BattleController)->void:
	var state:BattleState = controller.battle_state;
	var before:Array = _state_snapshot(state);
	var action:EnemyActionDefinition = state.enemy_state.current_action;
	var preview:Array[int] = AttackDamageResolver.preview_effect_damage(action.effects, state.enemy_state, state.player_state, 0);
	var intent:String = controller._build_enemy_intent_text(action);
	for index in range(action.effects.size()):
		var effect:CombatEffectDefinition = action.effects[index];
		var expected:String = "";
		if effect.effect_type == CombatEffectDefinition.EffectType.DAMAGE:
			expected = "%d点伤害" % preview[index];
		elif effect.effect_type == CombatEffectDefinition.EffectType.BLOCK:
			expected = "%d点格挡" % effect.amount;
		if not expected.is_empty():
			if effect.repeat_count > 1:
				expected += " × %d" % effect.repeat_count;
			_expect(intent.contains(expected), "Boss意图应显示各段真实数值与次数：%s" % expected);
	_expect(_state_snapshot(state) == before, "意图预览不得提前施加伤害、格挡或减益");


func _test_iron_crown_cycle()->void:
	var controller:BattleController = _controller("ironcrown_tyrant");
	if controller == null:
		return;
	var state:BattleState = controller.battle_state;
	var enemy:EnemyDefinition = state.enemy_state.enemy_definition;
	var snapshot:Dictionary = _definition_snapshot(enemy);
	if not _expect_fixed_boss(enemy):
		controller.get_parent().queue_free();
		return;
	var damages:Array[int] = [];
	var blocks:Array[int] = [];
	for index in range(4):
		var action:EnemyActionDefinition = enemy.action_pattern[index];
		var damage:int = _action_amount(action, CombatEffectDefinition.EffectType.DAMAGE);
		var block:int = _action_amount(action, CombatEffectDefinition.EffectType.BLOCK);
		var shape_valid:bool;
		if index == 0 or index == 2:
			shape_valid = damage > 0 and block > 0;
		elif index == 1:
			shape_valid = damage > 0 and block == 0;
		else:
			shape_valid = damage == 0 and block > 0;
		_expect(shape_valid, "铁冠暴君应按攻防、连击、攻防、纯防御循环");
		damages.append(damage);
		blocks.append(block);
	var multi:EnemyActionDefinition = enemy.action_pattern[1];
	_expect(multi.effects.size() == 1 and multi.effects[0].effect_type == CombatEffectDefinition.EffectType.DAMAGE and multi.effects[0].repeat_count == 3, "暴君第二步应使用真正的三段攻击，而非一段总伤害");
	_expect(state.enemy_state.current_block == 0, "首个玩家回合不提前获得Boss第一步格挡");
	for turn in range(12):
		var index:int = turn % 4;
		state.enemy_state.gain_block(37);
		_expect_intent(controller);
		var before:int = state.player_state.current_health;
		controller._on_end_turn_button_pressed();
		_expect(before - state.player_state.current_health == damages[index], "暴君每步真实伤害应与固定定义一致");
		_expect(state.enemy_state.current_block == blocks[index], "暴君先清空旧盾，再执行本步格挡，不能跨回合累积");
		_expect(damages[index] / 12.0 + blocks[index] / 10.0 <= 2.6, "暴君每轮伤害与格挡直接价值应不超过2.6");
		_expect(state.enemy_state.strength == 0, "暴君三个完整循环均保持零力量");
		_expect(state.enemy_state.current_action_index == (turn + 1) % 4, "暴君完成第四步后回到第一步");
	_expect(_definition_snapshot(enemy) == snapshot, "暴君行动及意图不能污染正式资源");
	controller.get_parent().queue_free();


func _test_calamity_timing()->void:
	var controller:BattleController = _controller("calamity_hierophant");
	if controller == null:
		return;
	var state:BattleState = controller.battle_state;
	var enemy:EnemyDefinition = state.enemy_state.enemy_definition;
	var snapshot:Dictionary = _definition_snapshot(enemy);
	if not _expect_fixed_boss(enemy):
		controller.get_parent().queue_free();
		return;
	_expect(_effect_types(enemy.action_pattern[0]) == [CombatEffectDefinition.EffectType.APPLY_WEAK, CombatEffectDefinition.EffectType.DAMAGE, CombatEffectDefinition.EffectType.BLOCK], "祭司第一步应先施加虚弱，再攻击并获得格挡");
	_expect(_effect_types(enemy.action_pattern[1]) == [CombatEffectDefinition.EffectType.APPLY_VULNERABLE, CombatEffectDefinition.EffectType.DAMAGE], "祭司第二步应先施加易伤，再攻击");
	_expect(_action_amount(enemy.action_pattern[0], CombatEffectDefinition.EffectType.APPLY_WEAK) == 1, "祭司每次虚弱只施加1回合");
	_expect(_action_amount(enemy.action_pattern[1], CombatEffectDefinition.EffectType.APPLY_VULNERABLE) == 1, "祭司每次易伤只施加1回合");
	_expect(_effect_types(enemy.action_pattern[2]) == [CombatEffectDefinition.EffectType.DAMAGE, CombatEffectDefinition.EffectType.BLOCK], "祭司第三步应攻击并获得格挡");
	_expect(_effect_types(enemy.action_pattern[3]) == [CombatEffectDefinition.EffectType.BLOCK], "祭司第四步应留下纯防御反击窗口");
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	_expect(state.enemy_state.current_block == 0, "祭司首个玩家回合不提前获得格挡");
	for turn in range(12):
		var index:int = turn % 4;
		var action:EnemyActionDefinition = enemy.action_pattern[index];
		var base_damage:int = _action_amount(action, CombatEffectDefinition.EffectType.DAMAGE);
		var expected_damage:int = floori(base_damage * 1.5) if index == 1 or index == 2 else base_damage;
		var expected_block:int = _action_amount(action, CombatEffectDefinition.EffectType.BLOCK);
		var strike_preview:Array[int] = AttackDamageResolver.preview_effect_damage(strike.effects, state.player_state, state.enemy_state, state.player_state.current_block);
		_expect(strike_preview[0] == (4 if index == 1 else 6), "虚弱只削弱祭司第二步前的玩家回合，基础打击应由6降到4后恢复");
		state.enemy_state.gain_block(37);
		_expect_intent(controller);
		var before:int = state.player_state.current_health;
		controller._on_end_turn_button_pressed();
		_expect(before - state.player_state.current_health == expected_damage, "祭司易伤同时放大施加轮与下一轮攻击，伤害与取整预览一致");
		_expect(state.player_state.weak_turns == (1 if index == 0 else 0), "祭司虚弱施加轮保留1回合，第二步结束后消退");
		_expect(state.player_state.vulnerable_turns == (1 if index == 1 else 0), "祭司易伤施加轮保留1回合，第三步攻击后消退");
		_expect(state.enemy_state.current_block == expected_block, "祭司清空旧盾后只保留本次新获得格挡");
		_expect(expected_damage / 12.0 + expected_block / 10.0 <= 2.6, "祭司计入真实易伤后，每轮伤害与格挡直接价值应不超过2.6");
		_expect(state.enemy_state.strength == 0, "祭司使用减益配合固定伤害，不额外成长力量");
		_expect(state.enemy_state.current_action_index == (turn + 1) % 4, "祭司固定四步循环应连续重复三次");
	_expect(_definition_snapshot(enemy) == snapshot, "祭司减益施加与消退不得改写正式行动资源");
	controller.get_parent().queue_free();


func _test_multi_hit_rounding()->void:
	var controller:BattleController = _controller("ironcrown_tyrant");
	if controller == null:
		return;
	var state:BattleState = controller.battle_state;
	var enemy:EnemyDefinition = state.enemy_state.enemy_definition;
	var snapshot:Dictionary = _definition_snapshot(enemy);
	controller._on_end_turn_button_pressed();
	var action:EnemyActionDefinition = state.enemy_state.current_action;
	if action.effects.size() != 1 or action.effects[0].effect_type != CombatEffectDefinition.EffectType.DAMAGE:
		_expect(false, "多段取整检查需要暴君第二步为单个重复伤害效果");
		controller.get_parent().queue_free();
		return;
	var effect:CombatEffectDefinition = action.effects[0];
	# 人为增加2力量及虚弱，只改变本场状态：7+2伤的三连击逐段为6，总共18而非20。
	state.enemy_state.gain_strength(2);
	state.enemy_state.apply_weak(1, false);
	var per_hit:int = floori((effect.amount + 2) * 0.75);
	var expected_damage:int = per_hit * effect.repeat_count;
	_expect(expected_damage != floori((effect.amount + 2) * 0.75 * effect.repeat_count), "选用的连击数值应能够区分逐段向下取整与合计取整");
	_expect_intent(controller);
	var before:int = state.player_state.current_health;
	controller._on_end_turn_button_pressed();
	_expect(before - state.player_state.current_health == expected_damage, "三段攻击应逐段计算并向下取整，不能先合并基础伤害");
	_expect(_definition_snapshot(enemy) == snapshot, "多段取整测试只改变运行时状态，正式Boss数值保持不变");
	controller.get_parent().queue_free();
