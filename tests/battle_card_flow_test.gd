## 出牌区域、回能、固有、保留与直接失血的回归检查，不修改正式卡牌资源。
## 运行方式：Godot --headless --path <项目目录> --script res://tests/battle_card_flow_test.gd
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_draw_during_resolution();
	_test_card_destinations();
	_test_retained_hand();
	_test_unaffordable_card();
	_test_lethal_card_is_archived_before_result();
	_test_energy_card();
	_test_repeated_energy_effect();
	_test_innate_opening();
	_test_innate_overflow();
	_test_innate_and_retained_hand();
	_test_short_opening_and_new_battle();
	_test_health_loss_and_cost();
	_test_lethal_health_loss();
	_test_repeated_health_loss();
	_test_health_loss_after_lethal_damage();
	await process_frame;# 等待测试场景及旧卡牌视图释放。
	print("卡牌流转检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


## 复制卡牌定义来配置测试词条，不改变共享的strike.tres。
func _card(exhausts:bool = false, power:bool = false, retains:bool = false)->CardInstance:
	var definition:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	definition.exhausts_on_play = exhausts;
	definition.retains_on_turn_end = retains;
	if power:
		definition.card_type = CardDefinition.CardType.POWER;
	var card:CardInstance = CardInstance.new();
	_expect(card.card_instance_init(definition), "测试卡牌初始化失败");
	return card;


func _state(cards:Array[CardInstance])->BattleState:
	var player:CombatantState = CombatantState.new();
	_expect(player.combatant_init_from_definition(load("res://combatants/players/data/player.tres")), "玩家初始化失败");
	var enemy:EnemyState = EnemyState.new();
	_expect(enemy.enemy_state_init(load("res://combatants/enemies/data/cave_crawler.tres")), "敌人初始化失败");
	var state:BattleState = BattleState.new();
	_expect(state.battle_state_init(player, enemy, cards, 10, 5, 10), "战斗初始化失败");
	state.current_phase = BattleState.BattlePhase.PLAYER_TURN;
	state.reset_energy_for_turn();
	state.draw_multiple_cards(cards.size());
	return state;


## 抽牌堆耗尽时只能洗回另一张弃牌，不能抽回正在结算的牌。
func _test_draw_during_resolution()->void:
	var played:CardInstance = _card();
	var other:CardInstance = _card();
	var state:BattleState = _state([played, other]);
	state.discard_card_from_hand(other);
	_expect(state.begin_card_play(played), "应能开始出牌");
	var queue:ActionQueue = ActionQueue.new();
	queue.queue_draw(state, 2);
	_expect(queue.resolve_all(), "抽牌效果应完成");
	_expect(state.hand.size() == 1 and state.hand.has(other), "结算中的卡牌不应被洗回手牌");
	var energy:int = state.current_available_energy;
	_expect(not state.begin_card_play(other), "结算中不能再开始另一张牌");
	_expect(state.current_available_energy == energy, "拒绝重复出牌不应扣费");
	_expect(not state.is_invalid_battle(), "结算中也应保持卡牌数量与归属正确");
	state.finish_card_play();
	_expect(state.discard_pile.has(played), "普通牌结算后应弃置");
	_expect(state.resolving_card == null, "归档后应清空结算中引用");


func _test_card_destinations()->void:
	var ordinary:CardInstance = _card();
	var exhaust:CardInstance = _card(true);
	var power:CardInstance = _card(false, true);
	var exhaust_power:CardInstance = _card(true, true);
	var state:BattleState = _state([ordinary, exhaust, power, exhaust_power]);
	for card in [ordinary, exhaust, power, exhaust_power]:
		_expect(state.begin_card_play(card), "应能开始测试卡牌");
		state.finish_card_play();
	_expect(state.discard_pile.size() == 1 and state.discard_pile.has(ordinary), "普通牌应进入弃牌堆");
	_expect(state.exhaust_pile.size() == 2 and state.exhaust_pile.has(exhaust_power), "消耗词条应优先于能力类型");
	_expect(state.played_power_cards.size() == 1 and state.played_power_cards.has(power), "无消耗能力牌应独立归档");
	var drawn:Array[CardInstance] = state.draw_multiple_cards(10);
	_expect(drawn.size() == 1 and drawn.has(ordinary), "洗牌不应回收消耗牌或能力牌");
	_expect(not state.is_invalid_battle(), "归档和洗牌后应保持牌数守恒");
	_expect(state.battle_state_init(state.player_state, state.enemy_state, [ordinary], 3, 5, 10), "应能重建战斗");
	_expect(state.resolving_card == null and state.exhaust_pile.is_empty() and state.played_power_cards.is_empty(), "重建战斗应清空新增区域");


func _test_retained_hand()->void:
	var ordinary:CardInstance = _card();
	var exhaust:CardInstance = _card(true);
	var retained:CardInstance = _card(false, false, true);
	var retained_exhaust:CardInstance = _card(true, false, true);
	var state:BattleState = _state([ordinary, exhaust, retained, retained_exhaust]);
	state.discard_hand_at_turn_end();
	_expect(state.hand.size() == 2 and state.hand.has(retained) and state.hand.has(retained_exhaust), "保留牌应留在手牌");
	_expect(state.discard_pile.size() == 2 and state.discard_pile.has(exhaust), "未打出的消耗牌应正常弃置");
	_expect(state.exhaust_pile.is_empty(), "回合结束弃牌不应触发消耗");
	_expect(not state.is_invalid_battle(), "回合结束后应保持牌数守恒");


func _test_unaffordable_card()->void:
	var card:CardInstance = _card(true);
	var state:BattleState = _state([card]);
	state.current_available_energy = 0;
	_expect(not state.begin_card_play(card), "费用不足时应拒绝出牌");
	_expect(state.hand.has(card) and state.resolving_card == null and state.exhaust_pile.is_empty(), "拒绝出牌不应移动卡牌");
	_expect(state.current_available_energy == 0, "拒绝出牌不应改变能量");


## 使用真实控制器与场景，验证结果信号发出前已经完成消耗归档。
func _test_lethal_card_is_archived_before_result()->void:
	var scene:PackedScene = load("res://battle/battle.tscn");
	var page:Control = scene.instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	var card:CardInstance = _card(true);
	_expect(controller.start_battle(
		load("res://battle/encounters/data/cave_crawler_encounter.tres"),
		load("res://combatants/players/data/player.tres"),
		[card.definition], 50, 50
	), "测试战斗应成功启动");
	controller.battle_state.enemy_state.current_health = 1;
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
		results.append(victory);
		_expect(controller.battle_state.resolving_card == null, "发出胜利信号前必须归档卡牌");
		_expect(controller.battle_state.exhaust_pile.size() == 1, "致命消耗牌不能遗漏消耗");
	);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(results.size() == 1 and results[0], "应只报告一次胜利");
	page.queue_free();


## 用古代仪典的已确认规则验证完整出牌流程，不加入正式卡池。
func _energy_definition()->CardDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.GAIN_ENERGY;
	effect.target_type = CombatEffectDefinition.TargetType.SELF;
	effect.amount = 3;
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_energy";
	definition.card_name = "测试回能";
	definition.description = "获得3能量。消耗。";
	definition.exhausts_on_play = true;
	definition.effects = [effect];
	return definition;


func _energy_controller(definition:CardDefinition)->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(
		load("res://battle/encounters/data/cave_crawler_encounter.tres"),
		load("res://combatants/players/data/player.tres"), [definition], 50, 50
	), "回能测试战斗应能启动");
	return controller;


func _test_energy_card()->void:
	for starting_energy in [0, 1, 3]:
		var definition:CardDefinition = _energy_definition();
		var controller:BattleController = _energy_controller(definition);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		state.current_available_energy = starting_energy;
		controller._on_card_selected(card);
		if starting_energy == 0:
			_expect(state.current_available_energy == 0 and state.hand.has(card), "费用不足不能预支回能效果");
			_expect(state.exhaust_pile.is_empty() and state.resolving_card == null, "未打出的回能牌不能被消耗");
		else:
			_expect(state.current_available_energy == starting_energy + 2, "支付1能量后获得3能量，净增2");
			_expect(state.exhaust_pile.has(card) and state.hand.is_empty(), "回能完成后按消耗词条归档");
			_expect(controller.energy_label.text == "能量：%d / 3" % (starting_energy + 2), "界面应显示超过基础值的当前能量");
		_expect(state.energy_per_turn == 3 and definition.effects[0].amount == 3, "回能不能改写基础能量或静态效果");
		_expect(not state.is_invalid_battle(), "回能出牌后牌区应保持正确");
		controller._on_end_turn_button_pressed();
		_expect(state.current_available_energy == 3, "下一回合恢复基础能量，不继承额外能量");
		controller.get_parent().queue_free();


func _test_repeated_energy_effect()->void:
	var definition:CardDefinition = _energy_definition();
	definition.effects[0].amount = 2;
	definition.effects[0].repeat_count = 2;
	var controller:BattleController = _energy_controller(definition);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	_expect(controller._queue_card_effect(card), "回能效果应能加入队列");
	_expect(state.current_available_energy == 3, "准备效果不能提前发放能量");
	controller.action_queue.clear_actions();
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 6, "1费卡重复获得2能量两次，应从3变为6");
	_expect(state.exhaust_pile.size() == 1 and state.resolving_card == null, "重复的是效果，卡牌只归档一次");
	controller.get_parent().queue_free();


func _opening_definitions(innate_count:int, ordinary_count:int, retains:bool = false)->Array[CardDefinition]:
	var innate:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	innate.is_innate = true;
	innate.retains_on_turn_end = retains;
	var ordinary:CardDefinition = load("res://cards/data/defend.tres");
	var definitions:Array[CardDefinition] = [];
	for _index in range(innate_count):
		definitions.append(innate);
	for _index in range(ordinary_count):
		definitions.append(ordinary);
	return definitions;


func _opening_controller(definitions:Array[CardDefinition], draw_count:int = 5, hand_limit:int = 10)->BattleController:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate();
	encounter.cards_per_turn = draw_count;
	encounter.max_hand_size = hand_limit;
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), definitions, 50, 50), "起手测试战斗应正常启动");
	return controller;


## 覆盖无固有、固有不足基础数量、恰好等于基础数量和超过基础数量。
func _test_innate_opening()->void:
	for innate_count in [0, 2, 5, 7]:
		var controller:BattleController = _opening_controller(_opening_definitions(innate_count, 8));
		var state:BattleState = controller.battle_state;
		_expect(state.hand.size() == maxi(5, innate_count), "固有占用基础抽牌名额，仅超过基础数时扩展起手");
		for index in range(innate_count):
			_expect(state.hand[index].definition.is_innate, "首回合应先抽固有，再抽普通牌");
		_expect(not state.is_invalid_battle(), "起手调整只能移动原实例，不能丢牌或复制");
		controller._on_end_turn_button_pressed();
		_expect(state.hand.size() == 5 and state.cards_per_turn == 5, "第二回合恢复基础抽牌数");
		for card in state.hand:
			_expect(not card.definition.is_innate, "固有只安排一次，剩余普通牌足够时不能从弃牌堆取回固有牌");
		controller.get_parent().queue_free();


func _test_innate_overflow()->void:
	var controller:BattleController = _opening_controller(_opening_definitions(5, 2), 2, 3);
	var state:BattleState = controller.battle_state;
	_expect(state.hand.size() == 3 and state.draw_pile.size() == 4, "固有超过容量时仅抽到手牌上限，剩余牌保留在牌堆");
	for card in state.hand:
		_expect(card.definition.is_innate, "满手起手不能让普通牌挤占固有牌");
	state.discard_card_from_hand(state.hand[0]);
	var drawn:CardInstance = state.draw_one_card();
	_expect(drawn.definition.is_innate, "腾出空位后普通抽牌也应先抽剩余固有牌");
	controller._on_end_turn_button_pressed();
	_expect(state.hand.size() == 2 and state.hand[0].definition.is_innate, "下回合按基础数量抽牌，剩余固有仍在牌堆顶");
	_expect(not state.is_invalid_battle(), "超额固有处理后牌数与容量合法");
	controller.get_parent().queue_free();


func _test_innate_and_retained_hand()->void:
	var controller:BattleController = _opening_controller(_opening_definitions(2, 8, true), 3, 4);
	var state:BattleState = controller.battle_state;
	var retained:Array[CardInstance] = [state.hand[0], state.hand[1]];
	controller._on_end_turn_button_pressed();
	_expect(state.hand.size() == 4 and state.draw_pile.size() == 5, "保留两张后尝试抽三张，容量只允许再抽两张");
	for card in retained:
		_expect(state.hand.has(card), "固有加保留的牌应保留原实例，不重新生成");
	_expect(not state.is_invalid_battle(), "保留与固有组合不超过手牌上限");
	controller.get_parent().queue_free();


func _test_short_opening_and_new_battle()->void:
	var definitions:Array[CardDefinition] = _opening_definitions(1, 1);
	var controller:BattleController = _opening_controller(definitions);
	_expect(controller.battle_state.hand.size() == 2, "牌组不足起手数量时只抽已有牌");
	var old_card:CardInstance = controller.battle_state.hand[0];
	_expect(controller.start_battle(
		load("res://battle/encounters/data/cave_crawler_encounter.tres"),
		load("res://combatants/players/data/player.tres"), definitions, 50, 50
	), "同一控制器应能重新开始战斗");
	var state:BattleState = controller.battle_state;
	_expect(state.current_turn_number == 1 and state.hand[0].definition.is_innate, "每场新战斗都重新安排固有起手");
	_expect(state.hand[0] != old_card and not state.is_invalid_battle(), "新战斗使用新实例，旧起手状态不残留");
	controller.get_parent().queue_free();


## 测试技能：1费，先失去2生命，再造成6伤害；不修改正式卡牌资源。
func _health_loss_definition()->CardDefinition:
	var loss:CombatEffectDefinition = CombatEffectDefinition.new();
	loss.effect_type = CombatEffectDefinition.EffectType.LOSE_HEALTH;
	loss.target_type = CombatEffectDefinition.TargetType.SELF;
	loss.amount = 2;
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_health_loss";
	definition.card_name = "测试失血";
	definition.description = "失去2生命，然后造成6伤害。";
	definition.effects = [loss, strike.effects[0]];
	return definition;


func _test_health_loss_and_cost()->void:
	for energy in [0, 3]:
		var controller:BattleController = _opening_controller([_health_loss_definition()]);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		state.current_available_energy = energy;
		state.player_state.current_block = 10;
		state.enemy_state.current_block = 3;
		controller._on_card_selected(card);
		if energy == 0:
			_expect(state.player_state.current_health == 50 and state.hand.has(card), "费用不足不能失血或移牌");
			_expect(state.enemy_state.current_health == 30, "费用不足不能执行后续攻击");
		else:
			_expect(state.player_state.current_health == 48 and state.player_state.current_block == 10, "直接失血扣生命但不扣格挡");
			_expect(state.enemy_state.current_health == 27 and state.enemy_state.current_block == 0, "存活时继续后续伤害，并正常计算敌人格挡");
			_expect(state.current_available_energy == 2 and state.discard_pile.has(card), "失血牌正常支付费用并归档");
		_expect(state.player_state.max_health == 50 and state.player_state.definition.max_health == 50, "直接失血不修改最大生命或静态定义");
		controller.get_parent().queue_free();
	var target:CombatantState = CombatantState.new();
	target.combatant_init("测试角色", 3);
	_expect(target.lose_health(5) == 3 and target.current_health == 0, "过量失血返回实际损失，生命不低于0");


func _test_lethal_health_loss()->void:
	for exhausts in [false, true]:
		var definition:CardDefinition = _health_loss_definition();
		definition.exhausts_on_play = exhausts;
		var block:CombatEffectDefinition = CombatEffectDefinition.new();
		block.effect_type = CombatEffectDefinition.EffectType.BLOCK;
		block.amount = 10;
		definition.effects.append(block);
		var gain:CombatEffectDefinition = CombatEffectDefinition.new();
		gain.effect_type = CombatEffectDefinition.EffectType.GAIN_ENERGY;
		gain.amount = 3;
		definition.effects.append(gain);
		var controller:BattleController = _opening_controller([definition]);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		state.player_state.current_health = 1;
		state.player_state.current_block = 9;
		state.enemy_state.current_health = 1;
		_expect(controller._card_is_playable(card), "失血属于效果，生命不足不会额外禁止出牌");
		var results:Array[bool] = [];
		controller.battle_finished.connect(func(victory:bool, health:int, _max_health:int)->void:
			results.append(victory);
			var final_pile:Array[CardInstance] = state.exhaust_pile if exhausts else state.discard_pile;
			_expect(final_pile.has(card) and state.resolving_card == null, "失血致死也必须在结果信号前完成归档");
			_expect(health == 0, "失败结果应报告0生命");
		);
		controller._on_card_selected(card);
		_expect(state.enemy_state.current_health == 1, "失血致死后不能继续攻击敌人");
		_expect(state.player_state.current_block == 9 and state.current_available_energy == 2, "失血致死后不继续获得格挡或能量");
		_expect(controller.action_queue.resolve_all(), "失血中断后队列应清空且可正常结束");
		_expect(state.enemy_state.current_health == 1 and state.current_available_energy == 2, "再次处理队列不能执行残留效果");
		controller._check_battle_result();
		_expect(results.size() == 1 and not results[0], "失血致死只报告一次失败");
		_expect(not state.is_invalid_battle(), "失血致死后卡牌数量与归属正确");
		controller.get_parent().queue_free();


func _test_repeated_health_loss()->void:
	for health in [5, 3]:
		var definition:CardDefinition = _health_loss_definition();
		definition.effects[0].repeat_count = 2;
		var controller:BattleController = _opening_controller([definition]);
		var state:BattleState = controller.battle_state;
		state.player_state.current_health = health;
		controller._on_card_selected(state.hand[0]);
		if health == 5:
			_expect(state.player_state.current_health == 1 and state.enemy_state.current_health == 24, "重复失血逐次执行，存活后继续攻击");
		else:
			_expect(state.player_state.current_health == 0 and state.enemy_state.current_health == 30, "重复失血中途致死后停止剩余效果");
		controller.get_parent().queue_free();


func _test_health_loss_after_lethal_damage()->void:
	var definition:CardDefinition = _health_loss_definition();
	definition.effects.reverse();# 先击杀敌人，随后自身失血致死。
	var controller:BattleController = _opening_controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.current_health = 1;
	state.enemy_state.current_health = 1;
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void: results.append(victory));
	controller._on_card_selected(state.hand[0]);
	_expect(state.player_state.current_health == 0 and state.enemy_state.current_health == 0, "效果仍按配置的先后顺序执行");
	_expect(results.size() == 1 and not results[0], "玩家失血致死不能因敌人先死亡而误判胜利");
	controller.get_parent().queue_free();
