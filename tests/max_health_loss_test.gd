## 血祭：最大生命支付、当前生命夹取、治疗上限及完整冒险中的生命延续。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_card_health_and_view();
	_test_payment_requirements();
	_test_repeated_cost();
	_test_health_loss_interruption();
	_test_run_persistence(true);
	_test_run_persistence(false);
	await process_frame;
	await create_timer(0.5).timeout; # 仅等待已释放播放器的混音线程收尾。
	print("最大生命损失检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _card()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_blood_sacrifice";
	definition.card_name = "测试血祭";
	definition.description = "减少1点最大生命，获得14点格挡。";
	var loss:CombatEffectDefinition = CombatEffectDefinition.new();
	loss.effect_type = CombatEffectDefinition.EffectType.LOSE_MAX_HEALTH;
	loss.target_type = CombatEffectDefinition.TargetType.SELF;
	loss.amount = 1;
	var block:CombatEffectDefinition = CombatEffectDefinition.new();
	block.effect_type = CombatEffectDefinition.EffectType.BLOCK;
	block.target_type = CombatEffectDefinition.TargetType.SELF;
	block.amount = 14;
	definition.effects = [loss, block];
	return definition;


func _controller(card:CardDefinition, health:int, max_health:int)->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(load("res://battle/data/encounters/cave_crawler_encounter.tres"), load("res://combatants/data/player.tres"), [card], health, max_health), "血祭测试战斗应启动");
	return controller;


func _test_card_health_and_view()->void:
	for health in [30, 50]:
		var controller:BattleController = _controller(_card(), health, 50);
		var state:BattleState = controller.battle_state;
		state.player_state.gain_block(7);
		state.player_state.gain_strength(10);
		state.player_state.apply_weak(2, false);
		state.player_state.apply_vulnerable(2, false);
		var card:CardInstance = state.hand[0];
		controller._on_card_selected(card);
		_expect(state.player_state.max_health == 49 and state.player_state.current_health == mini(health, 49), "减少上限只压低超过上限的当前生命");
		_expect(state.player_state.current_block == 21 and state.current_available_energy == 2, "不抵消格挡、不受攻击修正，扣1费后获得14格挡");
		_expect(state.discard_pile.has(card) and state.exhaust_pile.is_empty(), "消耗最大生命不等于卡牌消耗词条");
		_expect(controller.player_view.health_label.text == "%d / 49" % mini(health, 49) and controller.player_view.health_bar.max_value == 49, "战斗数字与血条均使用实际最大生命");
		_expect(state.player_state.heal(100) == 49 - mini(health, 49) and state.player_state.current_health == 49, "战斗治疗按新上限封顶");
		_expect(state.player_state.definition.max_health == 50 and not state.is_invalid_battle(), "静态定义不变，牌区守恒");
		controller.get_parent().queue_free();


func _test_payment_requirements()->void:
	for values in [[1, 3], [2, 0], [2, 3]]:
		var controller:BattleController = _controller(_card(), values[0], values[0]);
		var state:BattleState = controller.battle_state;
		state.current_available_energy = values[1];
		var card:CardInstance = state.hand[0];
		var can_play:bool = values[0] == 2 and values[1] == 3;
		_expect(controller._card_is_playable(card) == can_play, "显示可用性检查能量与最大生命");
		controller._on_card_selected(card);
		if can_play:
			_expect(state.player_state.max_health == 1 and state.player_state.current_health == 1 and state.player_state.current_block == 14, "2点上限可支付，保留1生命并获得格挡");
		else:
			_expect(state.hand.has(card) and state.current_available_energy == values[1] and state.player_state.max_health == values[0] and state.player_state.current_block == 0, "不能支付时不扣费、不移牌、不执行效果");
		controller.get_parent().queue_free();


func _test_repeated_cost()->void:
	# repeat_count与多个减上限效果都必须计入整张牌的支付需求。
	for max_health in [3, 4]:
		var definition:CardDefinition = _card();
		definition.effects[0].repeat_count = 2;
		var extra:CombatEffectDefinition = definition.effects[0].duplicate();
		extra.repeat_count = 1;
		definition.effects.append(extra);
		var controller:BattleController = _controller(definition, max_health, max_health);
		var state:BattleState = controller.battle_state;
		controller._on_card_selected(state.hand[0]);
		if max_health == 3:
			_expect(state.player_state.max_health == 3 and state.current_available_energy == 3 and state.hand.size() == 1, "支付总量不足时整张牌不能开始结算");
		else:
			_expect(state.player_state.max_health == 1 and state.player_state.current_health == 1 and state.player_state.current_block == 14, "足额支付后按配置逐项执行");
		controller.get_parent().queue_free();


func _test_health_loss_interruption()->void:
	var definition:CardDefinition = _card();
	var loss:CombatEffectDefinition = CombatEffectDefinition.new();
	loss.effect_type = CombatEffectDefinition.EffectType.LOSE_HEALTH;
	loss.amount = 2;
	definition.effects.push_front(loss);
	var controller:BattleController = _controller(definition, 2, 50);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.is_defeat() and controller.battle_state.player_state.max_health == 50 and controller.battle_state.player_state.current_block == 0, "前序失血致死仍中断减上限和格挡");
	_expect(controller.battle_state.discard_pile.size() == 1, "中断后正常归档");
	controller.get_parent().queue_free();


func _test_run_persistence(boss_victory:bool)->void:
	var main:Node = load("res://main.tscn").instantiate();
	root.add_child(main);
	var flow:GameFlowController = main.get_node("game_flow_controller");
	# 固定线性测试配置只用于卡牌机制隔离；正式地图在branch_map_test验证。
	flow.run_definition = load("res://tests/fixtures/linear_run.tres");
	flow._start_new_run();
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	var run:RunState = flow.run_state;
	_expect(run.current_health == 50 and run.max_health == 50, "新冒险从基础上限满血开始");
	run.owned_cards = [_card()];
	run.current_health = 40;
	flow._handle_map_node_selected("goblin_battle");
	var controller:BattleController = flow.current_page.get_node("battle_controller");
	controller._on_card_selected(controller.battle_state.hand[0]);
	controller.battle_state.enemy_state.take_unblocked_damage(100);
	controller._check_battle_result();
	_expect(run.current_health == 40 and run.max_health == 49 and flow.current_page is RewardView, "普通战胜利回写当前与最大生命，再进入奖励");
	for index in range(flow.run_definition.reward_selection_count):
		flow._handle_reward_selected((flow.current_page as RewardView).reward_options[0]);
	_expect((flow.current_page as MapView).health_label.text == "生命：40 / 49", "地图读取本局实际上限");
	flow._handle_map_node_selected("rest_site");
	_expect(run.current_health == 49 and run.max_health == 49 and (flow.current_page as MapView).health_label.text == "生命：49 / 49", "休整15点按49封顶且地图同步");
	flow._handle_map_node_selected("ruin_guard_boss");
	controller = flow.current_page.get_node("battle_controller");
	_expect(controller.battle_state.player_state.max_health == 49 and controller.battle_state.player_state.current_health == 49, "下一场战斗不恢复已损失上限");
	for card in controller.battle_state.hand.duplicate():
		if card.definition.card_id == "test_blood_sacrifice":
			controller._on_card_selected(card);
	if boss_victory:
		controller.battle_state.enemy_state.take_unblocked_damage(100);
	else:
		controller.battle_state.player_state.take_unblocked_damage(100);
	controller._check_battle_result();
	_expect(run.max_health == 48 and run.current_health == (48 if boss_victory else 0), "终局前同样保存减少后的上限与生命");
	_expect(run.status == (RunState.RunStatus.VICTORY if boss_victory else RunState.RunStatus.DEFEAT) and not run.is_invalid(), "胜利与失败状态保持合法");
	flow._show_main_menu();
	flow._start_new_run();
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	_expect(flow.run_state != run and flow.run_state.max_health == 50 and flow.run_state.current_health == 50, "重新开始冒险恢复原始上限，不继承血祭损失");
	_expect(flow.run_definition.character_definition.combatant_definition.max_health == 50, "整局流程不污染角色静态定义");
	main.queue_free();
