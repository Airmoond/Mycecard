## 当前敌人固定循环与标准模型实验检查；不依赖玩家随机抽牌造成伤害。
extends SceneTree

var _failures:int = 0;

func _initialize()->void:
	_run.call_deferred();

func _run()->void:
	_test_resource(load("res://combatants/enemies/data/cave_crawler.tres"), [8, 12], [0, 0], 0.7, 1.8, 30);
	_test_resource(load("res://combatants/enemies/data/ruin_guard.tres"), [0, 16, 18], [13, 0, 0], 1.3, 2.6, 99);
	_test_actual_cycle("res://battle/data/encounters/cave_crawler_encounter.tres", [8, 12], [0, 0]);
	_test_actual_cycle("res://battle/data/encounters/ruin_guard_encounter.tres", [0, 16, 18], [13, 0, 0]);
	await process_frame;
	print("敌人模型实验检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);

func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);

func _test_resource(enemy:EnemyDefinition, damages:Array, blocks:Array, opening:float, ceiling:float, health:int)->void:
	_expect(not enemy.is_invalid(), "实验敌人配置应合法");
	_expect(enemy.max_health == health, "本轮生命应为普通30、Boss99");
	_expect(enemy.action_pattern.size() == damages.size(), "行动循环长度应匹配");
	for index in range(enemy.action_pattern.size()):
		var damage:int = 0;
		var block:int = 0;
		for effect in enemy.action_pattern[index].effects:
			_expect(effect.effect_type in [CombatEffectDefinition.EffectType.DAMAGE, CombatEffectDefinition.EffectType.BLOCK], "本轮敌人无需成长或额外状态");
			if effect.effect_type == CombatEffectDefinition.EffectType.DAMAGE:
				damage += effect.amount * effect.repeat_count;
			elif effect.effect_type == CombatEffectDefinition.EffectType.BLOCK:
				block += effect.amount * effect.repeat_count;
		_expect(damage == damages[index] and block == blocks[index], "有序行动的伤害与格挡应符合模型方案");
		var value:float = damage / 12.0 + block / 10.0;
		_expect(value <= ceiling, "每个行动整体价值不得超过该类敌人的模型上限");
		if index == 0:
			_expect(absf(value - opening) <= 0.05, "首行动应达到对应目标值");

func _test_actual_cycle(encounter_path:String, damages:Array, blocks:Array)->void:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	var player:CombatantDefinition = load("res://combatants/data/player.tres").duplicate();
	player.max_health = 1000; # 仅测试中延长存活，完整观察多次循环，不改正式玩家数据。
	var deck:Array[CardDefinition] = [load("res://cards/data/defend.tres")];
	_expect(controller.start_battle(load(encounter_path), player, deck, 1000, 1000), "实验循环应可以从真实遭遇启动");
	var state:BattleState = controller.battle_state;
	for turn in range(damages.size() * 3):
		var index:int = turn % damages.size();
		var health_before:int = state.player_state.current_health;
		var intent:String = controller._build_enemy_intent_text(state.enemy_state.current_action);
		if damages[index] > 0:
			_expect(intent.contains("点伤害"), "攻击意图应显示伤害");
		else:
			_expect(intent.contains("%d点格挡" % blocks[index]), "防御意图应显示真实格挡数值");
		controller._on_end_turn_button_pressed();
		_expect(health_before - state.player_state.current_health == damages[index], "正式控制器的实际伤害应与行动预览一致");
		_expect(state.enemy_state.current_block == blocks[index], "敌人旧格挡正常清理，防御行动不会无限叠盾");
		_expect(state.enemy_state.strength == 0, "固定循环不应自动获得力量");
		_expect(state.enemy_state.current_action_index == (index + 1) % damages.size(), "下一意图按循环推进而非持续成长");
	page.queue_free();
