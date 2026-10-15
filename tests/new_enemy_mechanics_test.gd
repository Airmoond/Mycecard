## 新敌人的真实行动顺序、状态覆盖、连续强化与新战斗重置检查。
## 延长测试玩家生命以观察完整机制；不改变正式资源或依赖校准后的敌人生命。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_bulwark_cycle();
	_test_hex_timing();
	_test_unlimited_strength_and_reset();
	await process_frame;
	print("新敌人机制检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _controller(enemy_id:String)->BattleController:
	var encounter:EncounterDefinition = load("res://battle/data/encounters/%s_encounter.tres" % enemy_id);
	_expect(encounter != null and not encounter.is_invalid(), "新敌人遭遇应完整合法");
	if encounter == null or encounter.is_invalid():
		return null;
	_expect(encounter.enemy_definition.max_health > 0 and encounter.enemy_definition.max_health <= 100, "三种新普通敌人生命应为合法正数且不超过100");
	var player:CombatantDefinition = load("res://combatants/data/player.tres").duplicate();
	player.max_health = 1000;
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	var deck:Array[CardDefinition] = [load("res://cards/data/defend.tres")];
	if not controller.start_battle(encounter, player, deck, 1000, 1000):
		_expect(false, "新敌人机制测试战斗应启动");
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


func _expect_damage_intent(controller:BattleController, damage:int)->void:
	var intent:String = controller._build_enemy_intent_text(controller.battle_state.enemy_state.current_action);
	_expect(intent.contains("%d点伤害" % damage), "敌人意图应预览本次真实单段伤害：%d" % damage);


func _action_amount(action:EnemyActionDefinition, effect_type:CombatEffectDefinition.EffectType)->int:
	var total:int = 0;
	for effect in action.effects:
		if effect.effect_type == effect_type:
			total += effect.amount * effect.repeat_count;
	return total;


func _test_bulwark_cycle()->void:
	var controller:BattleController = _controller("bulwark_sentinel");
	if controller == null:
		return;
	var state:BattleState = controller.battle_state;
	var enemy:EnemyDefinition = state.enemy_state.enemy_definition;
	var snapshot:Dictionary = _definition_snapshot(enemy);
	_expect(enemy.action_pattern.size() == 4, "哨卫应连续防守三回合，第四回合重击后重新循环");
	if enemy.action_pattern.size() != 4:
		controller.get_parent().queue_free();
		return;
	var damages:Array[int] = [];
	var blocks:Array[int] = [];
	for index in range(4):
		var action:EnemyActionDefinition = enemy.action_pattern[index];
		var damage:int = _action_amount(action, CombatEffectDefinition.EffectType.DAMAGE);
		var block:int = _action_amount(action, CombatEffectDefinition.EffectType.BLOCK);
		_expect((damage >= 0 and damage <= 3 and block > 0) if index < 3 else (damage > 0 and block == 0), "哨卫前三轮以格挡配少量盾击防守，第四轮仅进行重击");
		_expect(damage / 12.0 + block / 10.0 <= 1.8, "哨卫每个行动的伤害与格挡合计价值不能超过1.8");
		damages.append(damage);
		blocks.append(block);
	_expect(damages[3] > maxi(maxi(damages[0], damages[1]), damages[2]) * 3, "第四轮重击应明显高于前三轮少量盾击");
	_expect(state.enemy_state.current_block == 0, "哨卫首个玩家回合没有提前获得格挡");
	for turn in range(12):
		var heavy_blow:bool = turn % 4 == 3;
		var expected_damage:int = damages[turn % 4];
		var expected_block:int = blocks[turn % 4];
		state.enemy_state.gain_block(37); # 未消耗旧盾也必须在敌人自身回合开始清空。
		if expected_damage > 0:
			_expect_damage_intent(controller, expected_damage);
		if not heavy_blow:
			_expect(controller._build_enemy_intent_text(state.enemy_state.current_action).contains("%d点格挡" % expected_block), "防守意图应显示该次真实格挡");
		var before:int = state.player_state.current_health;
		controller._on_end_turn_button_pressed();
		_expect(before - state.player_state.current_health == expected_damage, "哨卫前三轮少量盾击，第四轮重击伤害与配置、预览一致");
		_expect(state.enemy_state.current_block == expected_block, "哨卫清除旧盾后再获得新盾，不能三轮累积格挡");
		_expect(state.enemy_state.current_action_index == (turn + 1) % 4, "哨卫的三防一攻应重复循环");
	_expect(_definition_snapshot(state.enemy_state.enemy_definition) == snapshot, "哨卫实际循环不能污染静态资源");
	controller.get_parent().queue_free();


func _test_hex_timing()->void:
	var controller:BattleController = _controller("hexbound_acolyte");
	if controller == null:
		return;
	var state:BattleState = controller.battle_state;
	var enemy:EnemyDefinition = state.enemy_state.enemy_definition;
	var snapshot:Dictionary = _definition_snapshot(enemy);
	_expect(enemy.action_pattern.size() == 2, "侍徒应交替进行虚弱咒击与易伤咒击");
	if enemy.action_pattern.size() != 2:
		controller.get_parent().queue_free();
		return;
	var base_damages:Array[int] = [];
	for action in enemy.action_pattern:
		var base_damage:int = _action_amount(action, CombatEffectDefinition.EffectType.DAMAGE);
		_expect(base_damage > 0, "侍徒每个循环行动应有低基础攻击");
		base_damages.append(base_damage);
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	for turn in range(8):
		var action_index:int = turn % base_damages.size();
		var weak_action:bool = action_index == 0;
		var base_damage:int = base_damages[action_index];
		var expected_damage:int = base_damage if turn == 0 else floori(base_damage * 1.5);
		var expected_strike_damage:int = 6 if weak_action else 4;
		var strike_preview:Array[int] = AttackDamageResolver.preview_effect_damage(strike.effects, state.player_state, state.enemy_state, state.player_state.current_block);
		_expect(strike_preview[0] == expected_strike_damage, "虚弱只覆盖下一玩家回合，基础打击应按6/4伤交替而非持续虚弱");
		_expect_damage_intent(controller, expected_damage);
		var before:int = state.player_state.current_health;
		controller._on_end_turn_button_pressed();
		_expect(before - state.player_state.current_health == expected_damage, "侍徒先攻击后虚弱；另一轮先易伤再攻击，易伤同时影响该轮与下一次咒击");
		_expect(state.player_state.weak_turns == (1 if weak_action else 0), "新施加虚弱跳过首次递减，覆盖下一玩家回合后正常消退");
		_expect(state.player_state.vulnerable_turns == (0 if weak_action else 1), "易伤施加轮保留，覆盖下一次咒击后降为0");
		_expect(state.enemy_state.current_action_index == (turn + 1) % base_damages.size(), "侍徒两种减益行动应严格交替循环");
	_expect(_definition_snapshot(state.enemy_state.enemy_definition) == snapshot, "侍徒减益不能改写静态效果");
	controller.get_parent().queue_free();


func _test_unlimited_strength_and_reset()->void:
	var controller:BattleController = _controller("ragebound_brute");
	if controller == null:
		return;
	var state:BattleState = controller.battle_state;
	var enemy:EnemyDefinition = state.enemy_state.enemy_definition;
	var snapshot:Dictionary = _definition_snapshot(enemy);
	var base_damage:int = 0;
	for effect in enemy.action_pattern[0].effects:
		if effect.effect_type == CombatEffectDefinition.EffectType.DAMAGE:
			base_damage += effect.amount * effect.repeat_count;
	_expect(base_damage > 0, "蛮兵应有低初始攻击");
	for turn in range(12):
		var expected_strength:int = 2 * (turn + 1);
		var expected_damage:int = base_damage + expected_strength;
		_expect_damage_intent(controller, expected_damage);
		var before:int = state.player_state.current_health;
		controller._on_end_turn_button_pressed();
		_expect(state.enemy_state.strength == expected_strength, "蛮兵每次攻击之前获得2力量，十二回合连续增长");
		_expect(before - state.player_state.current_health == expected_damage, "本次新增力量立即计入实际单段攻击，与意图一致");
	_expect((base_damage + state.enemy_state.strength) / 12.0 > 1.8, "持续成长可以突破普通敌人1.8模型上限，不能暗中封顶");
	_expect(_definition_snapshot(enemy) == snapshot, "力量仅保存在本场状态，不得修改静态2力量或基础伤害");
	var player:CombatantDefinition = load("res://combatants/data/player.tres").duplicate();
	player.max_health = 1000;
	var encounter:EncounterDefinition = load("res://battle/data/encounters/ragebound_brute_encounter.tres");
	var deck:Array[CardDefinition] = [load("res://cards/data/defend.tres")];
	_expect(controller.start_battle(encounter, player, deck, 1000, 1000), "同一控制器应能重新开启蛮兵战斗");
	_expect(controller.battle_state.enemy_state.strength == 0, "新战斗必须将蛮兵力量归零");
	_expect_damage_intent(controller, base_damage + 2);
	var first_health:int = controller.battle_state.player_state.current_health;
	controller._on_end_turn_button_pressed();
	_expect(first_health - controller.battle_state.player_state.current_health == base_damage + 2, "新战斗首击不继承上一场强化");
	_expect(_definition_snapshot(enemy) == snapshot, "重开战斗后资源仍应保持初始定义");
	controller.get_parent().queue_free();
