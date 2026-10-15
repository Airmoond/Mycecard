## 一局冒险的运行时状态；静态资源和抽定的遭遇均只读。
class_name RunState
extends RefCounted

## 旧枚举编号保持稳定；IN_PROGRESS 表示可进入地图节点。
enum RunStatus { SETUP, IN_PROGRESS, VICTORY, DEFEAT, DRAFTING, CHOOSING_COLLECTION, CHOOSING_UNEXPECTED, UNEXPECTED_RESULT, IN_BATTLE, CHOOSING_REWARD }

var definition:RunDefinition
var current_health:int = 0
var max_health:int = 0
var owned_cards:Array[CardDefinition] = []
var current_node_id:String = ""
var available_node_ids:Array[String] = []
var completed_node_ids:Array[String] = []
var status:RunStatus = RunStatus.SETUP
var draft_round:int = 0
var draft_candidates:Array[CardDefinition] = [];
var random:RunRNG;
var session_id:String = "";
var active_battle_id:String = "";
var processed_battle_results:Dictionary = {};
var last_battle_result:Dictionary = {};
var reward_state:RewardState;
var reward_history:Dictionary = {};

## 首次进入一条支线时确定，直到新冒险才清空。
var selected_route_id:String = ""

## 新冒险一次生成全部战斗绑定；返回地图、领取奖励与休整不会重新抽取。
var node_encounters:Dictionary = {}

## 九个位置的实际类型与不期而遇定义一次抽定；所有共享资源保持只读。
var node_types:Dictionary = {}
var node_unexpected_encounters:Dictionary = {}
## 候选与结果按位置独立保存，同名内容在不同路线互不共享可变状态。
var unexpected_candidates:Dictionary = {}
## 每个选牌选项独立保存；unexpected_candidates 是第一组选牌候选的兼容读取。
var unexpected_option_candidates:Dictionary = {};
var unexpected_results:Dictionary = {}

## 开始节点选择的藏品不会进入牌组；候选仅抽取一次直到完成选择。
var selected_collection:CollectionDefinition
var collection_candidates:Array[CollectionDefinition] = []

## 圣杯按普通节点记录触发，重复战斗回调和奖励页面重建不能再次回血。
var _normal_victory_collection_nodes:Array[String] = []


func get_draft_rarity()->int:
	if draft_round < 0 or draft_round >= RunDefinition.DRAFT_RARITIES.size():
		return -1;
	return RunDefinition.DRAFT_RARITIES[draft_round];


func choose_starting_card(card:CardDefinition)->bool:
	if status != RunStatus.DRAFTING or definition == null or card == null:
		return false;
	if not definition.character_definition.reward_card_pool.has(card) or card.rarity != get_draft_rarity():
		return false;
	owned_cards.append(card);
	draft_round += 1;
	if draft_round == RunDefinition.DRAFT_RARITIES.size():
		status = RunStatus.IN_PROGRESS;
	return true;


## 验证和准备全部在局部完成，失败不会覆盖旧冒险或污染资源。
func run_state_init(new_definition:RunDefinition, rng:RandomNumberGenerator = null)->bool:
	if new_definition == null or new_definition.is_invalid():
		push_error("冒险定义无效，局内状态初始化失败");
		return false;
	var character:CharacterDefinition = new_definition.character_definition;
	var initial_cards:Array[CardDefinition] = [];
	for entry in character.starting_deck_entries:
		for _index in range(entry.count):
			initial_cards.append(entry.card_definition);

	var bindings:Dictionary = {};
	var types:Dictionary = {};
	var event_bindings:Dictionary = {};
	var map:MapDefinition = new_definition.map_definition;
	if map.is_branch_map:
		for route in map.get_route_ids():
			var candidates:Array[EncounterDefinition] = new_definition.normal_encounter_pool.duplicate();
			RunRNG.shuffle(candidates, rng);
			var route_nodes:Array[String] = map.get_route_node_ids(route);
			if map.randomize_route_contents:
				var route_types:Array[int] = [MapNodeDefinition.NodeType.BATTLE, MapNodeDefinition.NodeType.BATTLE, MapNodeDefinition.NodeType.UNEXPECTED];
				RunRNG.shuffle(route_types, rng);
				var battle_index:int = 0;
				for index in range(route_nodes.size()):
					var node_id:String = route_nodes[index];
					types[node_id] = route_types[index];
					if route_types[index] == MapNodeDefinition.NodeType.BATTLE:
						bindings[node_id] = candidates[battle_index];
						battle_index += 1;
					else:
						event_bindings[node_id] = new_definition.unexpected_encounter_pool[RunRNG.pick_index(new_definition.unexpected_encounter_pool.size(), rng)];
			else:
				bindings[route_nodes[0]] = candidates[0];
				bindings[route_nodes[1]] = candidates[1];
	for node in map.nodes:
		if not node.requires_encounter() or bindings.has(node.node_id):
			continue;
		if not node.random_encounter:
			bindings[node.node_id] = node.encounter_definition;
		else:
			var pool:Array[EncounterDefinition] = new_definition.boss_encounter_pool if node.node_type == MapNodeDefinition.NodeType.BOSS else new_definition.normal_encounter_pool;
			bindings[node.node_id] = pool[RunRNG.pick_index(pool.size(), rng)];
	bindings.make_read_only();
	types.make_read_only();
	event_bindings.make_read_only();

	definition = new_definition;
	max_health = character.combatant_definition.max_health;
	current_health = max_health;
	owned_cards = initial_cards;
	current_node_id = "";
	available_node_ids = map.starting_node_ids.duplicate();
	completed_node_ids = [];
	selected_route_id = "";
	node_encounters = bindings;
	node_types = types;
	node_unexpected_encounters = event_bindings;
	unexpected_candidates = {};
	unexpected_option_candidates = {};
	unexpected_results = {};
	selected_collection = null;
	collection_candidates = [];
	_normal_victory_collection_nodes = [];
	draft_round = 0;
	draft_candidates = [];
	random = null;
	session_id = "";
	active_battle_id = "";
	processed_battle_results = {};
	last_battle_result = {};
	reward_state = null;
	reward_history = {};
	status = RunStatus.DRAFTING;
	return true;


## 统一提供本局实际战斗内容，也兼容固定遭遇的旧地图。
func get_node_type(node_id:String)->int:
	if definition == null or definition.map_definition == null:
		return -1;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(node_id);
	if node == null:
		return -1;
	return node_types.get(node_id, node.node_type);


func node_requires_encounter(node_id:String)->bool:
	return get_node_type(node_id) in [MapNodeDefinition.NodeType.BATTLE, MapNodeDefinition.NodeType.BOSS];


func get_unexpected_encounter(node_id:String)->UnexpectedEncounterDefinition:
	return node_unexpected_encounters.get(node_id) as UnexpectedEncounterDefinition;


func get_node_encounter(node_id:String)->EncounterDefinition:
	if definition == null or definition.map_definition == null:
		return null;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(node_id);
	if node == null or not node_requires_encounter(node_id):
		return null;
	if node_encounters.has(node_id):
		return node_encounters[node_id] as EncounterDefinition;
	return node.encounter_definition;


func get_node_display_name(node_id:String)->String:
	if definition == null or definition.map_definition == null:
		return "";
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(node_id);
	if node == null:
		return "";
	var encounter:EncounterDefinition = get_node_encounter(node_id);
	if encounter != null and encounter.enemy_definition != null:
		return encounter.enemy_definition.display_name;
	var content:UnexpectedEncounterDefinition = get_unexpected_encounter(node_id);
	if content != null:
		return content.display_name;
	return node.display_name;


## 候选只在首次进入此位置时生成，重建页面或取消子页不能重抽。
func begin_unexpected_encounter(rng:RandomNumberGenerator = null)->bool:
	if get_node_type(current_node_id) != MapNodeDefinition.NodeType.UNEXPECTED or unexpected_results.has(current_node_id):
		return false;
	if status == RunStatus.CHOOSING_UNEXPECTED:
		return true;
	if status != RunStatus.IN_PROGRESS:
		return false;
	var content:UnexpectedEncounterDefinition = get_unexpected_encounter(current_node_id);
	if content == null:
		return false;
	if not unexpected_candidates.has(current_node_id):
		var by_option:Dictionary = UnexpectedEncounterExecutor.prepare_candidates(self, rng);
		for option in content.options:
			if option.operation == UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD and not by_option.has(option.option_id):
				return false;
		var options:Array[CardDefinition] = [];
		var first_option:UnexpectedEncounterOptionDefinition = content.first_card_option();
		if first_option != null:
			options = by_option[first_option.option_id];
		options.make_read_only();
		unexpected_candidates[current_node_id] = options;
		unexpected_option_candidates[current_node_id] = by_option;
	status = RunStatus.CHOOSING_UNEXPECTED;
	return true;


## 所有资格验证通过后，在同一同步调用内提交支付、收益与一次性结果。
func resolve_unexpected_encounter(option_id:String, card:CardDefinition = null, deck_index:int = -1)->bool:
	var result:Dictionary = UnexpectedEncounterExecutor.evaluate(self, option_id, card, deck_index);
	if result.is_empty():
		return false;
	current_health += result["actual_heal"] - result["health_cost"];
	if result["added_card"] != null:
		owned_cards.append(result["added_card"]);
	if result["removed_card"] != null:
		owned_cards.remove_at(result["removed_deck_index"]);
	unexpected_results[current_node_id] = result;
	status = RunStatus.UNEXPECTED_RESULT;
	return true;


func continue_unexpected_encounter()->bool:
	if status != RunStatus.UNEXPECTED_RESULT or not unexpected_results.has(current_node_id):
		return false;
	status = RunStatus.IN_PROGRESS;
	if not complete_current_node():
		status = RunStatus.UNEXPECTED_RESULT;
		return false;
	return true;


## 只有进入开始节点后才能生成候选，选牌阶段与地图查看均不触发。
func begin_collection_selection(rng:RandomNumberGenerator = null)->bool:
	if status != RunStatus.IN_PROGRESS or definition == null or definition.collection_pool.is_empty() or selected_collection != null:
		return false;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(current_node_id);
	if node == null or node.node_type != MapNodeDefinition.NodeType.START or completed_node_ids.has(current_node_id):
		return false;
	var candidates:Array[CollectionDefinition] = definition.collection_pool.duplicate();
	RunRNG.shuffle(candidates, rng);
	var choices:Array[CollectionDefinition] = [];
	for index in range(definition.collection_option_count):
		choices.append(candidates[index]);
	choices.make_read_only();
	collection_candidates = choices;
	status = RunStatus.CHOOSING_COLLECTION;
	return true;


## 仅接受本次展示的静态资源原引用；领取后完成开始节点并开放三条支线。
func choose_collection(collection:CollectionDefinition)->bool:
	if status != RunStatus.CHOOSING_COLLECTION or definition == null or selected_collection != null or collection == null:
		return false;
	if not collection_candidates.has(collection) or not definition.collection_pool.has(collection) or collection.is_invalid():
		return false;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(current_node_id);
	if node == null or node.node_type != MapNodeDefinition.NodeType.START or completed_node_ids.has(current_node_id):
		return false;
	var previous_candidates:Array[CollectionDefinition] = collection_candidates;
	selected_collection = collection;
	collection_candidates = [];
	status = RunStatus.IN_PROGRESS;
	if not complete_current_node():
		selected_collection = null;
		collection_candidates = previous_candidates;
		status = RunStatus.CHOOSING_COLLECTION;
		return false;
	return true;


## 游戏流程先同步战斗生命再调用；治疗不改变最大生命且每个普通节点仅一次。
func apply_normal_victory_collection()->int:
	if status != RunStatus.IN_PROGRESS or definition == null or current_health <= 0 or selected_collection == null:
		return 0;
	if selected_collection.effect_type != CollectionDefinition.EffectType.NORMAL_VICTORY_HEAL or _normal_victory_collection_nodes.has(current_node_id):
		return 0;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(current_node_id);
	if node == null or get_node_type(current_node_id) != MapNodeDefinition.NodeType.BATTLE:
		return 0;
	_normal_victory_collection_nodes.append(current_node_id);
	return heal(selected_collection.amount);


func is_invalid()->bool:
	if definition == null or definition.is_invalid():
		push_error("局内状态缺少合法冒险定义");
		return true;
	if not RunStatus.values().has(status) or status == RunStatus.SETUP:
		push_error("局内状态尚未初始化或状态枚举无效");
		return true;
	if max_health <= 0 or current_health < 0 or current_health > max_health:
		push_error("局内生命超出合法范围");
		return true;
	if (status == RunStatus.DEFEAT and current_health != 0) or (status != RunStatus.DEFEAT and current_health == 0):
		push_error("玩家生命与整局状态不一致");
		return true;
	if owned_cards.is_empty():
		push_error("本局实际牌组不能为空");
		return true;
	for card in owned_cards:
		if card == null or card.is_invalid():
			push_error("本局实际牌组包含无效卡牌");
			return true;
	if draft_round < 0 or draft_round > RunDefinition.DRAFT_RARITIES.size():
		push_error("开局构筑轮数无效");
		return true;
	if (status == RunStatus.DRAFTING and draft_round == RunDefinition.DRAFT_RARITIES.size()) or (status != RunStatus.DRAFTING and draft_round != RunDefinition.DRAFT_RARITIES.size()):
		push_error("开局构筑轮数与状态不一致");
		return true;

	var map:MapDefinition = definition.map_definition;
	if not current_node_id.is_empty() and not map.has_node(current_node_id):
		push_error("当前地图节点不存在");
		return true;
	var progress_ids:Dictionary = {};
	if not current_node_id.is_empty():
		progress_ids[current_node_id] = true;
	for ids in [available_node_ids, completed_node_ids]:
		for node_id in ids:
			if not map.has_node(node_id) or progress_ids.has(node_id):
				push_error("地图进度包含不存在、重复或冲突的节点");
				return true;
			progress_ids[node_id] = true;
	if _encounter_bindings_are_invalid():
		return true;
	if _collection_state_is_invalid():
		return true;
	if _unexpected_state_is_invalid():
		return true;
	if _session_state_is_invalid():
		return true;
	if status == RunStatus.DRAFTING and (not current_node_id.is_empty() or not completed_node_ids.is_empty() or available_node_ids != map.starting_node_ids or not selected_route_id.is_empty()):
		push_error("构筑阶段不能推进地图或提前选择支线");
		return true;
	if status in [RunStatus.VICTORY, RunStatus.DEFEAT] and not available_node_ids.is_empty():
		push_error("终局不能保留可进入节点");
		return true;
	if status == RunStatus.DEFEAT:
		var defeated_node:MapNodeDefinition = map.get_node_by_id(current_node_id);
		if defeated_node == null or not node_requires_encounter(current_node_id):
			push_error("失败状态必须保留发生失败的战斗节点");
			return true;
	if status == RunStatus.VICTORY:
		if not current_node_id.is_empty() or not _has_completed_boss():
			push_error("胜利必须已完成 Boss 且没有正在处理的节点");
			return true;
	if map.is_branch_map:
		return _branch_progress_is_invalid();
	if not selected_route_id.is_empty():
		push_error("线性地图不能保存支线选择");
		return true;
	return false;


func _collection_state_is_invalid()->bool:
	var map:MapDefinition = definition.map_definition;
	if definition.collection_pool.is_empty():
		if selected_collection != null or not collection_candidates.is_empty() or not _normal_victory_collection_nodes.is_empty() or status == RunStatus.CHOOSING_COLLECTION:
			push_error("未配置藏品的冒险不能保存藏品状态");
			return true;
		return false;
	var start_id:String = map.starting_node_ids[0];
	if selected_collection != null:
		if not definition.collection_pool.has(selected_collection) or selected_collection.is_invalid() or not completed_node_ids.has(start_id):
			push_error("持有藏品必须属于配置池，且已经完成开始节点");
			return true;
	else:
		if not completed_node_ids.is_empty() or not selected_route_id.is_empty() or current_node_id not in ["", start_id] or status in [RunStatus.VICTORY, RunStatus.DEFEAT]:
			push_error("尚未选择藏品时不能完成开始节点或进入支线");
			return true;
		var expected_available:Array[String] = [];
		if current_node_id.is_empty():
			expected_available = map.starting_node_ids.duplicate();
		if available_node_ids != expected_available:
			push_error("尚未选择藏品时只能开放或停留在开始节点");
			return true;
	if status == RunStatus.CHOOSING_COLLECTION:
		if selected_collection != null or current_node_id != start_id or collection_candidates.size() != definition.collection_option_count:
			push_error("藏品选择状态必须停留在开始节点且保存完整候选");
			return true;
		var candidate_ids:Dictionary = {};
		for collection in collection_candidates:
			if collection == null or not definition.collection_pool.has(collection) or collection.is_invalid() or candidate_ids.has(collection.collection_id):
				push_error("藏品候选必须来自配置池且不能重复");
				return true;
			candidate_ids[collection.collection_id] = true;
	elif not collection_candidates.is_empty():
		push_error("非藏品选择阶段不能保留领取候选");
		return true;
	var healed_ids:Dictionary = {};
	for node_id in _normal_victory_collection_nodes:
		var node:MapNodeDefinition = map.get_node_by_id(node_id);
		if selected_collection == null or selected_collection.effect_type != CollectionDefinition.EffectType.NORMAL_VICTORY_HEAL or node == null or get_node_type(node_id) != MapNodeDefinition.NodeType.BATTLE or healed_ids.has(node_id) or (node_id != current_node_id and not completed_node_ids.has(node_id)):
			push_error("战后藏品治疗记录必须对应已胜利的普通战斗节点");
			return true;
		healed_ids[node_id] = true;
	return false;


func _encounter_bindings_are_invalid()->bool:
	var expected_count:int = 0;
	var map:MapDefinition = definition.map_definition;
	for node in map.nodes:
		if not node_requires_encounter(node.node_id):
			continue;
		expected_count += 1;
		if not node_encounters.has(node.node_id) or not (node_encounters[node.node_id] is EncounterDefinition):
			push_error("战斗节点缺少本局遭遇绑定：%s" % node.node_id);
			return true;
		var encounter:EncounterDefinition = node_encounters[node.node_id];
		if encounter.is_invalid():
			push_error("本局遭遇绑定无效：%s" % node.node_id);
			return true;
		if node.random_encounter or node.node_type == MapNodeDefinition.NodeType.ROUTE_SLOT:
			var pool:Array[EncounterDefinition] = definition.boss_encounter_pool if get_node_type(node.node_id) == MapNodeDefinition.NodeType.BOSS else definition.normal_encounter_pool;
			if not pool.has(encounter):
				push_error("本局随机遭遇不属于相应候选池：%s" % node.node_id);
				return true;
		elif encounter != node.encounter_definition:
			push_error("固定节点的本局遭遇与静态定义不一致：%s" % node.node_id);
			return true;
	if node_encounters.size() != expected_count:
		push_error("本局遭遇绑定包含多余节点");
		return true;
	if map.is_branch_map:
		for route in map.get_route_ids():
			var ids:Array[String] = [];
			for node_id in map.get_route_node_ids(route):
				if get_node_type(node_id) == MapNodeDefinition.NodeType.BATTLE:
					ids.append(node_id);
			if ids.size() != 2:
				return true;
			if get_node_encounter(ids[0]).enemy_definition.combatant_id == get_node_encounter(ids[1]).enemy_definition.combatant_id:
				push_error("同一支线的两个普通敌人不能重复");
				return true;
	return false;


func _unexpected_state_is_invalid()->bool:
	var map:MapDefinition = definition.map_definition;
	if map.randomize_route_contents:
		if node_types.size() != 9 or node_unexpected_encounters.size() != 3:
			return true;
		for route in map.get_route_ids():
			var counts:Dictionary = {MapNodeDefinition.NodeType.BATTLE: 0, MapNodeDefinition.NodeType.UNEXPECTED: 0};
			for node_id in map.get_route_node_ids(route):
				var kind:int = get_node_type(node_id);
				if not counts.has(kind):
					return true;
				counts[kind] += 1;
				if kind == MapNodeDefinition.NodeType.UNEXPECTED:
					var content:UnexpectedEncounterDefinition = get_unexpected_encounter(node_id);
					if content == null or not definition.unexpected_encounter_pool.has(content):
						return true;
				elif node_unexpected_encounters.has(node_id):
					return true;
			if counts[MapNodeDefinition.NodeType.BATTLE] != 2 or counts[MapNodeDefinition.NodeType.UNEXPECTED] != 1:
				return true;
	else:
		if not node_types.is_empty() or not node_unexpected_encounters.is_empty():
			return true;
	for node_id in unexpected_candidates:
		var content:UnexpectedEncounterDefinition = get_unexpected_encounter(node_id);
		if content == null or (node_id != current_node_id and not completed_node_ids.has(node_id)):
			return true;
		var ids:Dictionary = {};
		for card in unexpected_candidates[node_id]:
			if not (card is CardDefinition) or not content.candidate_pool(definition.character_definition.reward_card_pool).has(card) or ids.has(card.card_id):
				return true;
			ids[card.card_id] = true;
		var first_option:UnexpectedEncounterOptionDefinition = content.first_card_option();
		if ids.size() != (first_option.candidate_count if first_option != null else 0):
			return true;
		if not unexpected_option_candidates.has(node_id):
			return true;
		var by_option:Dictionary = unexpected_option_candidates[node_id];
		var expected_count:int = 0;
		for option in content.options:
			if option.operation != UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
				continue;
			expected_count += 1;
			var choices:Array = by_option.get(option.option_id, []);
			if choices.size() != option.candidate_count or not choices.is_read_only():
				return true;
			var option_ids:Dictionary = {};
			for card in choices:
				if not (card is CardDefinition) or not option.candidate_pool(definition.character_definition.reward_card_pool).has(card) or option_ids.has(card.card_id):
					return true;
				option_ids[card.card_id] = true;
		if by_option.size() != expected_count:
			return true;
	if unexpected_option_candidates.size() != unexpected_candidates.size():
		return true;
	for node_id in unexpected_results:
		if not unexpected_candidates.has(node_id) or (node_id != current_node_id and not completed_node_ids.has(node_id)):
			return true;
	if status in [RunStatus.CHOOSING_UNEXPECTED, RunStatus.UNEXPECTED_RESULT]:
		if get_node_type(current_node_id) != MapNodeDefinition.NodeType.UNEXPECTED or not unexpected_candidates.has(current_node_id):
			return true;
		if unexpected_results.has(current_node_id) != (status == RunStatus.UNEXPECTED_RESULT):
			return true;
	return false;


## 会话新增状态独立校验；旧直接状态测试仍可使用原基础接口。
func _session_state_is_invalid()->bool:
	if status == RunStatus.IN_BATTLE:
		if active_battle_id.is_empty() or not node_requires_encounter(current_node_id) or processed_battle_results.has(active_battle_id) or reward_state != null:
			return true;
	elif not active_battle_id.is_empty():
		return true;
	if status == RunStatus.CHOOSING_REWARD:
		if reward_state == null or reward_state.remaining_rounds <= 0 or reward_state.total_rounds != definition.reward_selection_count or reward_state.node_id != current_node_id or get_node_type(current_node_id) != MapNodeDefinition.NodeType.BATTLE or not processed_battle_results.has(reward_state.battle_id):
			return true;
		if reward_state.is_invalid(definition.character_definition.reward_card_pool, definition.reward_option_count):
			return true;
	elif reward_state != null:
		return true;
	for battle_id in processed_battle_results:
		var result:Variant = processed_battle_results[battle_id];
		if not (result is Dictionary) or not result.is_read_only() or result.get("battle_id") != battle_id:
			return true;
		var node_id:String = result.get("node_id", "");
		if not node_requires_encounter(node_id) or (node_id != current_node_id and not completed_node_ids.has(node_id)):
			return true;
		var health:int = result.get("player_health", -1);
		var maximum:int = result.get("player_max_health", 0);
		if maximum <= 0 or health < 0 or health > maximum or (result.get("victory", false) and health == 0) or (not result.get("victory", false) and health != 0):
			return true;
	if reward_state != null and not processed_battle_results[reward_state.battle_id].get("victory", false):
		return true;
	for node_id in reward_history:
		var reward:RewardState = reward_history[node_id] as RewardState;
		if reward == null or reward.node_id != node_id or reward.remaining_rounds != 0 or reward.total_rounds != definition.reward_selection_count or not completed_node_ids.has(node_id) or get_node_type(node_id) != MapNodeDefinition.NodeType.BATTLE:
			return true;
		if reward.is_invalid(definition.character_definition.reward_card_pool, definition.reward_option_count) or not processed_battle_results.has(reward.battle_id) or not processed_battle_results[reward.battle_id].get("victory", false):
			return true;
	if not session_id.is_empty():
		if random == null:
			return true;
		if status == RunStatus.DRAFTING:
			if draft_candidates.is_empty() or not draft_candidates.is_read_only():
				return true;
			for card in draft_candidates:
				if not definition.character_definition.reward_card_pool.has(card) or card.rarity != get_draft_rarity():
					return true;
		elif not draft_candidates.is_empty():
			return true;
	return false;


## 分支进度只能是所选路径的前缀，防止换线、跳层和重新开启其他入口。
func _branch_progress_is_invalid()->bool:
	var map:MapDefinition = definition.map_definition;
	var start_id:String = map.starting_node_ids[0];
	if selected_route_id.is_empty():
		if completed_node_ids.is_empty():
			if current_node_id not in ["", start_id] or available_node_ids != ([start_id] if current_node_id.is_empty() else []):
				push_error("未进入开始节点时，只有开始节点可以开放");
				return true;
		elif completed_node_ids == [start_id]:
			if not current_node_id.is_empty() or available_node_ids != map.get_node_by_id(start_id).next_node_ids:
				push_error("开始节点完成后必须开放三个支线入口");
				return true;
		else:
			push_error("尚未选线却已经推进支线");
			return true;
		return false;

	if not map.get_route_ids().has(selected_route_id):
		push_error("选择的支线不存在");
		return true;
	var path:Array[String] = [start_id];
	path.append_array(map.get_route_node_ids(selected_route_id));
	path.append(map.get_node_by_id(path.back()).next_node_ids[0]);
	if completed_node_ids.is_empty() or completed_node_ids.size() > path.size():
		push_error("所选支线的完成记录长度无效");
		return true;
	for index in range(completed_node_ids.size()):
		if completed_node_ids[index] != path[index]:
			push_error("完成记录必须按所选支线顺序推进");
			return true;
	var next_index:int = completed_node_ids.size();
	if not current_node_id.is_empty() and (next_index >= path.size() or current_node_id != path[next_index]):
		push_error("当前节点不在所选支线的下一层");
		return true;
	var expected_available:Array[String] = [];
	if status not in [RunStatus.VICTORY, RunStatus.DEFEAT] and current_node_id.is_empty() and next_index < path.size():
		expected_available.append(path[next_index]);
	if available_node_ids != expected_available:
		push_error("选线后不能保留其他支线入口或跳过节点");
		return true;
	if status == RunStatus.VICTORY and completed_node_ids != path:
		push_error("分支地图胜利前必须完整走完所选五层路径");
		return true;
	return false;


func can_enter_node(node_id:String)->bool:
	if definition == null or status != RunStatus.IN_PROGRESS or not current_node_id.is_empty() or node_id.is_empty():
		return false;
	var map:MapDefinition = definition.map_definition;
	if map == null or not map.has_node(node_id) or completed_node_ids.has(node_id) or not available_node_ids.has(node_id):
		return false;
	if not definition.collection_pool.is_empty() and selected_collection == null and map.get_node_by_id(node_id).node_type != MapNodeDefinition.NodeType.START:
		return false;
	if map.is_branch_map:
		var node:MapNodeDefinition = map.get_node_by_id(node_id);
		if not node.route_id.is_empty():
			if not selected_route_id.is_empty():
				return node.route_id == selected_route_id;
			return completed_node_ids.has(map.starting_node_ids[0]) and map.get_node_by_id(map.starting_node_ids[0]).next_node_ids.has(node_id);
	return true;


func enter_node(node_id:String)->bool:
	if not can_enter_node(node_id):
		return false;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(node_id);
	if definition.map_definition.is_branch_map and selected_route_id.is_empty() and not node.route_id.is_empty():
		selected_route_id = node.route_id;
		available_node_ids.clear();
	else:
		available_node_ids.erase(node_id);
	current_node_id = node_id;
	return true;


func complete_current_node()->bool:
	if status != RunStatus.IN_PROGRESS or current_node_id.is_empty():
		return false;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(current_node_id);
	if node == null or completed_node_ids.has(current_node_id):
		return false;
	if node.node_type == MapNodeDefinition.NodeType.START and not definition.collection_pool.is_empty() and selected_collection == null:
		return false;
	if get_node_type(current_node_id) == MapNodeDefinition.NodeType.UNEXPECTED and not unexpected_results.has(current_node_id):
		return false;
	completed_node_ids.append(current_node_id);
	for next_id in node.next_node_ids:
		var next:MapNodeDefinition = definition.map_definition.get_node_by_id(next_id);
		if definition.map_definition.is_branch_map and not selected_route_id.is_empty() and not next.route_id.is_empty() and next.route_id != selected_route_id:
			continue;
		if not completed_node_ids.has(next_id) and not available_node_ids.has(next_id):
			available_node_ids.append(next_id);
	current_node_id = "";
	return true;


func add_card(card:CardDefinition)->bool:
	if status != RunStatus.IN_PROGRESS:
		return false;
	if card == null or card.is_invalid():
		push_error("需要添加的卡牌定义无效");
		return false;
	owned_cards.append(card);
	return true;


func heal(amount:int)->int:
	if status != RunStatus.IN_PROGRESS or amount <= 0:
		return 0;
	var actual:int = mini(amount, max_health - current_health);
	current_health += actual;
	return actual;


func _has_completed_boss()->bool:
	for node_id in completed_node_ids:
		var node:MapNodeDefinition = definition.map_definition.get_node_by_id(node_id);
		if node != null and node.node_type == MapNodeDefinition.NodeType.BOSS:
			return true;
	return false;


func mark_victory()->bool:
	if status != RunStatus.IN_PROGRESS or current_health <= 0 or not current_node_id.is_empty() or not _has_completed_boss():
		return false;
	available_node_ids.clear();
	status = RunStatus.VICTORY;
	return true;


## 保留失败战斗节点供结算查看；终局不再开放任何地图入口。
func mark_defeat()->bool:
	if status != RunStatus.IN_PROGRESS or current_health != 0 or definition == null:
		return false;
	var node:MapNodeDefinition = definition.map_definition.get_node_by_id(current_node_id);
	if node == null or not node_requires_encounter(current_node_id):
		return false;
	available_node_ids.clear();
	status = RunStatus.DEFEAT;
	return true;
