## 卡池筛选、无放回抽样、静态资源保护与实际奖励流程接入。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_rarity_groups();
	_test_reward_candidates();
	_test_source_unchanged();
	_test_insufficient_candidates();
	_test_reward_flow();
	await process_frame;
	await create_timer(0.5).timeout; # 仅等待测试退出时的混音线程释放。
	print("卡池抽样检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


## 每个稀有度的测试卡数量由counts指定，不改正式卡池。
func _pool(counts:Array[int])->Array[CardDefinition]:
	var pool:Array[CardDefinition] = [];
	for rarity in range(counts.size()):
		for index in range(counts[rarity]):
			var card:CardDefinition = load("res://cards/data/strike.tres").duplicate();
			card.card_id = "sample_test_%d_%d" % [rarity, index];
			card.card_name = "测试卡%d_%d" % [rarity, index];
			card.rarity = rarity;
			pool.append(card);
	return pool;


func _expect_unique(options:Array[CardDefinition], count:int)->void:
	_expect(options.size() == count, "候选数量应完整");
	var ids:Dictionary = {};
	for card in options:
		_expect(not ids.has(card.card_id), "同页不能重复出现相同card_id");
		ids[card.card_id] = true;


func _test_rarity_groups()->void:
	var pool:Array[CardDefinition] = _pool([2, 4, 4, 4]);
	for rarity in [CardDefinition.CardRarity.RARE, CardDefinition.CardRarity.EPIC, CardDefinition.CardRarity.LEGENDARY]:
		var options:Array[CardDefinition] = CardPoolSampler.sample(pool, 3, [rarity]);
		_expect_unique(options, 3);
		for card in options:
			_expect(card.rarity == rarity and pool.has(card), "按稀有度抽样的候选全部来自指定稀有度，保留原定义引用");
	# 固定随机种子使检查可重复；要求候选确实随多次抽取变化，不检验概率分布。
	seed(23);
	var selections:Dictionary = {};
	for index in range(12):
		var ids:PackedStringArray = [];
		for card in CardPoolSampler.sample(pool, 3, [CardDefinition.CardRarity.RARE]):
			ids.append(card.card_id);
		ids.sort();
		selections["|".join(ids)] = true;
	_expect(selections.size() > 1, "相同卡池多次抽取应能得到不同候选组合");


func _test_reward_candidates()->void:
	var pool:Array[CardDefinition] = _pool([4, 1, 1, 4]);
	var candidates:Array[CardDefinition] = CardPoolSampler.filter_pool(pool, CardPoolSampler.REWARD_RARITIES);
	_expect(candidates.size() == 6, "非传说卡全部进入同一个候选集合，不按稀有度分配名额");
	var options:Array[CardDefinition] = CardPoolSampler.sample(pool, 6, CardPoolSampler.REWARD_RARITIES);
	_expect_unique(options, 6);
	for card in options:
		_expect(card.rarity != CardDefinition.CardRarity.LEGENDARY and candidates.has(card), "普通奖励排除所有传说卡");
	var all_legendary:Array[CardDefinition] = _pool([0, 0, 0, 3]);
	_expect(CardPoolSampler.filter_pool(all_legendary, CardPoolSampler.REWARD_RARITIES).is_empty(), "全传说卡池没有普通奖励候选");


func _test_source_unchanged()->void:
	var pool:Array[CardDefinition] = _pool([2, 3, 3, 3]);
	var original:Array[CardDefinition] = pool.duplicate();
	var original_ids:PackedStringArray = [];
	var original_rarities:Array[int] = [];
	for card in pool:
		original_ids.append(card.card_id);
		original_rarities.append(card.rarity);
	var selected:Array[CardDefinition] = CardPoolSampler.sample(pool, 3, [CardDefinition.CardRarity.EPIC]);
	selected.clear();
	var filtered:Array[CardDefinition] = CardPoolSampler.filter_pool(pool, CardPoolSampler.REWARD_RARITIES);
	filtered.clear();
	_expect(pool == original, "抽样与修改返回数组不改变源卡池数量、顺序或引用");
	for index in range(pool.size()):
		_expect(pool[index].card_id == original_ids[index] and pool[index].rarity == original_rarities[index], "抽样不改写卡牌字段");


func _test_insufficient_candidates()->void:
	var pool:Array[CardDefinition] = _pool([0, 1, 1, 4]);
	print("以下两条配置错误为预期：非传说候选只有2张，不能展示3张。");
	_expect(CardPoolSampler.sample(pool, 3, CardPoolSampler.REWARD_RARITIES).is_empty(), "数量不足应返回空数组，不补空值、重复卡或部分候选");
	# 本项只验证战后候选容量，隔离不期而遇各自的三选一配置。
	var definition:RunDefinition = load("res://tests/fixtures/linear_run.tres").duplicate();
	definition.character_definition = definition.character_definition.duplicate();
	definition.character_definition.reward_card_pool = pool;
	_expect(definition.is_invalid(), "配置容量检查按筛选后数量，不能用传说卡凑数");
	definition.reward_option_count = 2;
	_expect(not definition.is_invalid(), "恰好满足非传说候选数量的配置应合法");
	_expect(not load("res://run/data/default_run.tres").is_invalid(), "现有正式冒险仍可运行");


func _test_reward_flow()->void:
	var main:Node = load("res://main.tscn").instantiate();
	var flow:GameFlowController = main.get_node("game_flow_controller");
	flow.run_definition = load("res://tests/fixtures/linear_run.tres").duplicate();
	flow.run_definition.character_definition = flow.run_definition.character_definition.duplicate();
	var pool:Array[CardDefinition] = _pool([1, 1, 1, 4]);
	flow.run_definition.character_definition.reward_card_pool = pool;
	root.add_child(main);
	flow._start_new_run();
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	var starting_size:int = flow.run_state.owned_cards.size();
	flow._handle_map_node_selected("goblin_battle");
	var controller:BattleController = flow.current_page.get_node("battle_controller");
	controller.battle_state.enemy_state.take_unblocked_damage(100);
	controller._check_battle_result();
	for index in range(flow.run_definition.reward_selection_count):
		var reward:RewardView = flow.current_page as RewardView;
		_expect_unique(reward.reward_options, 3);
		for card in reward.reward_options:
			_expect(card.rarity != CardDefinition.CardRarity.LEGENDARY and pool.has(card), "每轮实际奖励页面均使用统一过滤后的候选");
		var chosen:CardDefinition = reward.reward_options[0];
		reward._reward_card_views[0].pressed.emit();
		_expect(flow.run_state.owned_cards.size() == starting_size + index + 1 and flow.run_state.owned_cards.back() == chosen, "通过奖励组件点击增加选择的真实卡牌");
	_expect(flow.current_page is MapView and flow.run_state.completed_node_ids.has("goblin_battle"), "完成原有奖励次数后仍返回地图并完成节点");
	_expect(pool.size() == 7 and not flow.run_state.is_invalid(), "整局状态合法且角色卡池未被抽空");
	_expect(load("res://characters/data/warrior.tres").reward_card_pool.size() == 27, "测试配置不污染正式战士卡池");
	main.queue_free();
