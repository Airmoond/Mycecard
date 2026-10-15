## 开局逐轮选择、完整分页、单次提交和正常冒险闭环。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_state();
	_test_configuration();
	_test_node_progression_and_healing();
	_test_page_refresh();
	await _test_paging_and_layout();
	await _test_complete_adventure();
	_test_return_and_restart();
	await process_frame;
	await create_timer(0.5).timeout; # 仅等待测试退出时的混音线程释放。
	print("开局构筑检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _card(id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % id);


func _main()->GameFlowController:
	var main:Node = load("res://main.tscn").instantiate();
	root.add_child(main);
	var flow:GameFlowController = main.get_node("game_flow_controller");
	flow.run_definition = load("res://tests/fixtures/phase5_run.tres");
	return flow;


func _test_state()->void:
	var state:RunState = RunState.new();
	_expect(state.run_state_init(load("res://run/data/default_run.tres")), "合法配置可初始化");
	_expect(state.status == RunState.RunStatus.DRAFTING and state.owned_cards.size() == 6 and not state.is_invalid(), "初始6张，处于构筑且状态合法");
	_expect(state.owned_cards.count(_card("strike")) == 3 and state.owned_cards.count(_card("defend")) == 3, "基础3打击3防御来自资源");
	_expect(not state.enter_node("start") and not state.add_card(_card("strike")) and not state.mark_victory() and not state.mark_defeat(), "构筑阶段不能进地图、领取奖励或结束冒险");
	_expect(not state.choose_starting_card(_card("bloodthirsty_sword")) and state.owned_cards.size() == 6, "首轮不能选择史诗");
	var foreign:CardDefinition = _card("eternity").duplicate();
	_expect(not state.choose_starting_card(foreign), "同名但不在角色卡池的资源不能提交");
	for id in ["eternity", "war_god_blessing", "battle_trance"]:
		var size_before:int = state.owned_cards.size();
		_expect(state.choose_starting_card(_card(id)), "按稀有度逐轮提交");
		_expect(state.owned_cards.size() == size_before + 1 and state.owned_cards.back() == _card(id), "每轮立即追加原定义引用");
		_expect(not state.choose_starting_card(_card(id)), "重复提交上一轮不能再次加牌");
	_expect(state.status == RunState.RunStatus.IN_PROGRESS and state.can_enter_node("start") and not state.is_invalid(), "三轮完成才开放地图");


func _test_configuration()->void:
	var definition:RunDefinition = load("res://tests/fixtures/phase5_run.tres").duplicate();
	definition.character_definition = definition.character_definition.duplicate();
	definition.character_definition.reward_card_pool = [_card("eternity"), _card("lethal_blade"), _card("battle_trance"), _card("heavy_strike")];
	_expect(not definition.is_invalid(), "开局每组1张即可，普通奖励仍有3张非传说");
	definition.character_definition.reward_card_pool.erase(_card("eternity"));
	print("以下开局缺少传说的配置报错为预期。");
	_expect(definition.is_invalid(), "空稀有度在配置入口报错");
	_expect(load("res://run/data/default_run.tres").reward_selection_count == 1, "默认普通奖励仅一次");


## 精简状态校验后，仍由真实进度和本局生命上限决定操作结果。
func _test_node_progression_and_healing()->void:
	var state:RunState = RunState.new();
	state.run_state_init(load("res://tests/fixtures/phase5_run.tres"));
	for id in ["eternity", "war_god_blessing", "battle_trance"]:
		state.choose_starting_card(_card(id));
	_expect(not state.enter_node("final_boss") and not state.mark_victory(), "未解锁 Boss 不可进入，也不能提前胜利");
	_expect(state.enter_node("start") and state.begin_collection_selection() and state.choose_collection(state.definition.collection_pool[0]), "开始节点开放三条支线");
	_expect(state.enter_node("route_a_1"), "进入已解锁节点");
	_expect(not state.enter_node("route_a_1") and not state.enter_node("route_a_rest"), "处理当前节点期间不能再次进入节点");
	_expect(state.complete_current_node() and not state.complete_current_node(), "节点只完成一次");
	_expect(state.available_node_ids == ["route_a_2"] and state.completed_node_ids == ["start", "route_a_1"], "完成节点后只解锁本线后继，其他路线保持关闭");
	state.max_health = 49;
	state.current_health = 47;
	_expect(state.heal(15) == 2 and state.current_health == 49, "休整治疗遵守血祭改变后的本局上限");
	_expect(state.heal(15) == 0 and not state.mark_victory(), "满血治疗为0，完成普通节点不能胜利");
	state.enter_node("route_a_2");
	state.complete_current_node();
	state.enter_node("route_a_rest");
	state.complete_current_node();
	state.enter_node("final_boss");
	_expect(not state.mark_victory(), "Boss 节点尚未完成时不能胜利");
	state.complete_current_node();
	state.current_health = 0;
	_expect(not state.mark_victory(), "玩家死亡时不能标记胜利");
	state.current_health = 1;
	_expect(state.mark_victory() and not state.mark_victory() and not state.mark_defeat(), "胜利只能报告一次，不能反向改为失败");
	_expect(state.heal(15) == 0 and not state.add_card(_card("strike")) and not state.is_invalid(), "终局不再接受治疗和奖励，局内状态仍完整");


## 连续刷新后仍保持节点、连接和候选数量，旧视图不会继续留在容器中。
func _test_page_refresh()->void:
	var state:RunState = RunState.new();
	state.run_state_init(load("res://run/data/default_run.tres"));
	for id in ["eternity", "war_god_blessing", "battle_trance"]:
		state.choose_starting_card(_card(id));
	var map:MapView = load("res://run/map/map_view.tscn").instantiate();
	root.add_child(map);
	map.setup(state.definition.map_definition, state);
	map.refresh_map();
	map.refresh_map();
	_expect(map.node_layer.get_child_count() == 11 and map.connection_layer.get_child_count() == 12, "重复刷新地图不叠加节点和连线");
	var node_selections:Array[String] = [];
	map.node_selected.connect(func(id:String)->void: node_selections.append(id));
	var first:MapNodeView = map._node_views["start"];
	first.node_button.pressed.emit();
	first.node_button.pressed.emit();
	_expect(node_selections == ["start"], "地图刷新后重复点击仍只选择一次");
	map.queue_free();
	var reward:RewardView = load("res://run/reward/reward_view.tscn").instantiate();
	root.add_child(reward);
	var options:Array[CardDefinition] = [_card("heavy_strike"), _card("double_strike"), _card("battle_trance")];
	reward.setup(options);
	reward.refresh_options();
	reward.refresh_options();
	_expect(reward.options_container.get_child_count() == 3 and reward.reward_options == options, "奖励刷新不叠加视图、不改变候选");
	var selections:Array[CardDefinition] = [];
	reward.reward_selected.connect(func(card:CardDefinition)->void: selections.append(card));
	reward._reward_card_views[0].pressed.emit();
	reward.refresh_options();
	reward._reward_card_views[1].pressed.emit();
	_expect(selections == [options[0]] and reward._reward_card_views[1].disabled, "已选择的奖励刷新后不能再次领取");
	reward.setup(options);
	reward._reward_card_views[1].pressed.emit();
	_expect(selections == [options[0], options[1]], "绑定新一轮候选后可以重新选择");
	reward.queue_free();


func _test_paging_and_layout()->void:
	var candidates:Array[CardDefinition] = [];
	for index in range(13):
		var card:CardDefinition = _card("eternity").duplicate();
		card.card_id = "draft_page_%d" % index;
		candidates.append(card);
	var original:Array[CardDefinition] = candidates.duplicate();
	var page:StartingDraftView = load("res://run/draft/starting_draft_view.tscn").instantiate();
	root.add_child(page);
	page.setup(CardDefinition.CardRarity.LEGENDARY, candidates, [_card("strike"), _card("strike"), _card("defend")]);
	_expect(page._card_views.size() == 6 and page.previous_button.disabled and not page.next_button.disabled and page.page_label.text == "1 / 3", "13张分三页，首页六张");
	page.next_button.pressed.emit();
	_expect(page.page_index == 1 and page._card_views[0].card_definition == candidates[6] and page._card_views.size() == 6, "第二页从第7张开始");
	page.next_button.pressed.emit();
	_expect(page.page_label.text == "3 / 3" and page._card_views.size() == 1 and page._card_views[0].card_definition == candidates[12] and page.next_button.disabled, "末页只显示剩余1张，不补牌");
	page._change_page(1);
	_expect(page.page_index == 2, "末页不可越界");
	page.previous_button.pressed.emit();
	page.previous_button.pressed.emit();
	_expect(page._card_views[0].card_definition == candidates[0] and candidates == original, "往返翻页保持全部候选顺序和源卡池");
	_expect(page.deck_list.get_child_count() == 3 and page.deck_list.get_child(0).text == "打击" and page.deck_list.get_child(1).text == "打击", "右侧同名牌逐条显示，只写卡名");
	# 用实际容器排版验证常用窗口下六张卡全貌和侧栏都位于页面内。
	for viewport_size in [Vector2i(1152, 648), Vector2i(1280, 720)]:
		root.size = viewport_size;
		await process_frame;
		await process_frame;
		await process_frame;
		var bounds:Rect2 = page.get_global_rect();
		for view in page._card_views:
			_expect(bounds.encloses(view.get_global_rect()) and is_equal_approx(view.size.y / view.size.x, CardFace.BASE_SIZE.y / CardFace.BASE_SIZE.x), "六张完整卡面等比缩放并在页面范围内");
		_expect(bounds.encloses(page.back_button.get_global_rect()) and bounds.encloses(page.title_label.get_global_rect()), "标题和侧栏按钮没有溢出");
		_expect(page._card_views[0].global_position.y == page._card_views[2].global_position.y and page._card_views[3].global_position.y > page._card_views[0].global_position.y, "网格按两行三列排布");
	var selections:Array[CardDefinition] = [];
	page.card_selected.connect(func(card:CardDefinition)->void: selections.append(card));
	page.next_button.pressed.emit();
	page._card_views[1].pressed.emit();
	page._card_views[2].pressed.emit();
	page._change_page(1);
	_expect(selections == [candidates[7]] and page.page_index == 1, "非首页选择仅提交一次，提交后禁止继续翻页");
	page.queue_free();


func _test_complete_adventure()->void:
	var flow:GameFlowController = _main();
	flow.current_page.start_requested.emit();
	var run:RunState = flow.run_state;
	var pool:Array[CardDefinition] = flow.run_definition.character_definition.reward_card_pool.duplicate();
	var chosen_ids:Array[String] = ["eternity", "war_god_blessing", "strength_power"];
	for index in range(3):
		var page:StartingDraftView = flow.current_page as StartingDraftView;
		var rarity:int = RunDefinition.DRAFT_RARITIES[index];
		_expect(page.title_label.text == "选择1张%s卡牌，以组建你的初始牌组！" % StartingDraftView.RARITY_NAMES[rarity], "顶部准确提示本轮稀有度");
		_expect(page.candidates == CardPoolSampler.filter_pool(pool, [rarity]) and page.page_index == 0, "每轮展示该组全部候选且从第一页开始");
		_expect(page.deck_list.get_child_count() == 6 + index, "右侧随实际牌组从6到8逐轮更新");
		for view in page._card_views:
			if view.card_definition == _card(chosen_ids[index]):
				view.pressed.emit();
				view.pressed.emit(); # 旧页面的残余点击不影响下一轮。
				break;
		_expect(run.owned_cards.size() == 7 + index, "单击立即加牌且重复点击不跳轮");
	_expect(flow.current_page is MapView and run.owned_cards.size() == 9, "选完三张进入地图，牌组9张");
	flow._handle_map_node_selected("start");
	flow._handle_collection_selected(load("res://collections/data/copper_fang.tres"));
	flow._handle_map_node_selected("route_a_1");
	var controller:BattleController = flow.current_page.get_node("battle_controller");
	_expect(controller.battle_state.hand[0].definition == _card("eternity"), "开局选到的固有永恒进入实际战斗起手");
	controller.battle_state.enemy_state.take_unblocked_damage(1000);
	controller._check_battle_result();
	var reward:RewardView = flow.current_page as RewardView;
	_expect(reward.reward_options.size() == 3, "战后仍三选一");
	for card in reward.reward_options:
		_expect(card.rarity != CardDefinition.CardRarity.LEGENDARY, "战后奖励排除传说");
	reward._reward_card_views[0].pressed.emit();
	_expect(flow.current_page is MapView and run.owned_cards.size() == 10, "只选一次奖励后返回地图，牌组10张");
	flow._handle_map_node_selected("route_a_2");
	controller = flow.current_page.get_node("battle_controller");
	controller.battle_state.enemy_state.take_unblocked_damage(1000);
	controller._check_battle_result();
	(flow.current_page as RewardView)._reward_card_views[0].pressed.emit();
	_expect(run.owned_cards.size() == 11, "第二次普通战斗也只领取一张，Boss前共11张");
	flow._handle_map_node_selected("route_a_rest");
	flow._handle_map_node_selected("final_boss");
	controller = flow.current_page.get_node("battle_controller");
	_expect(controller.battle_state.hand.size() + controller.battle_state.draw_pile.size() == 11, "Boss战使用全部11张实际卡牌");
	controller.battle_state.enemy_state.take_unblocked_damage(1000);
	controller._check_battle_result();
	_expect(run.status == RunState.RunStatus.VICTORY and flow.current_page is RunResult, "Boss胜利正常进入结算");
	flow.current_page.restart_requested.emit();
	flow.current_page.start_requested.emit();
	_expect(flow.run_state != run and flow.run_state.owned_cards.size() == 6 and flow.current_page is StartingDraftView, "胜利后重开重新构筑");
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	flow._handle_map_node_selected("start");
	flow._handle_collection_selected(load("res://collections/data/copper_fang.tres"));
	flow._handle_map_node_selected("route_a_1");
	controller = flow.current_page.get_node("battle_controller");
	controller.battle_state.player_state.take_unblocked_damage(100);
	controller._check_battle_result();
	_expect(flow.run_state.status == RunState.RunStatus.DEFEAT and flow.current_page is RunResult, "新流程战败仍直接结算");
	_expect(pool == flow.run_definition.character_definition.reward_card_pool, "整局流程不污染角色卡池");
	flow.get_parent().queue_free();
	await process_frame;


func _test_return_and_restart()->void:
	var flow:GameFlowController = _main();
	flow._start_new_run();
	(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	var old_run:RunState = flow.run_state;
	(flow.current_page as StartingDraftView).back_button.pressed.emit();
	_expect(flow.run_state == null and flow.current_page is MainMenu, "构筑中返回主菜单释放未完成冒险");
	flow._start_new_run();
	var page:StartingDraftView = flow.current_page as StartingDraftView;
	_expect(flow.run_state != old_run and flow.run_state.draft_round == 0 and flow.run_state.owned_cards.size() == 6 and page.page_index == 0, "重开清空先前选择、轮次和页码");
	flow.get_parent().queue_free();
