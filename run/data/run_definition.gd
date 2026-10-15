## 冒险的只读规则入口；局内随机结果与地图进度属于 RunState。
class_name RunDefinition
extends Resource

const DRAFT_RARITIES:Array[int] = [
	CardDefinition.CardRarity.LEGENDARY,
	CardDefinition.CardRarity.EPIC,
	CardDefinition.CardRarity.RARE
];

@export var run_id:String
@export var character_definition:CharacterDefinition
@export var map_definition:MapDefinition
@export var reward_option_count:int = 3
@export var reward_selection_count:int = 3

## 随机战斗节点使用的候选池；固定遭遇地图可不配置。
@export var normal_encounter_pool:Array[EncounterDefinition] = []
@export var boss_encounter_pool:Array[EncounterDefinition] = []

## 开始节点三选一；留空时保留无藏品的旧地图和数值评估条件。
@export var collection_pool:Array[CollectionDefinition] = []
@export var collection_option_count:int = 3

@export var unexpected_encounter_pool:Array[UnexpectedEncounterDefinition] = []


func is_invalid()->bool:
	if run_id.is_empty():
		push_error("冒险 ID 不能为空");
		return true;
	if character_definition == null or character_definition.is_invalid():
		push_error("冒险缺少合法角色定义");
		return true;
	if map_definition == null or map_definition.is_invalid():
		push_error("冒险缺少合法地图定义");
		return true;
	var reward_candidates:Array[CardDefinition] = CardPoolSampler.filter_pool(
		character_definition.reward_card_pool, CardPoolSampler.REWARD_RARITIES
	);
	if reward_option_count <= 0 or reward_option_count > reward_candidates.size():
		push_error("奖励选项数必须大于 0，且不能超过角色非传说卡池大小");
		return true;
	if reward_selection_count <= 0:
		push_error("奖励选择次数必须大于 0");
		return true;
	for rarity in DRAFT_RARITIES:
		if CardPoolSampler.filter_pool(character_definition.reward_card_pool, [rarity]).is_empty():
			push_error("开局选牌每个稀有度至少需要一张候选，缺少：%d" % rarity);
			return true;

	var needs_normal:bool = map_definition.randomize_route_contents;
	var needs_boss:bool = false;
	for node in map_definition.nodes:
		if node.random_encounter:
			needs_normal = needs_normal or node.node_type == MapNodeDefinition.NodeType.BATTLE;
			needs_boss = needs_boss or node.node_type == MapNodeDefinition.NodeType.BOSS;
	if needs_normal and _encounter_pool_is_invalid(normal_encounter_pool, 2 if map_definition.is_branch_map else 1, "普通敌人"):
		return true;
	if needs_boss and _encounter_pool_is_invalid(boss_encounter_pool, 1, "Boss"):
		return true;
	if needs_normal and needs_boss:
		var normal_ids:Dictionary = {};
		for encounter in normal_encounter_pool:
			normal_ids[encounter.enemy_definition.combatant_id] = true;
		for encounter in boss_encounter_pool:
			if normal_ids.has(encounter.enemy_definition.combatant_id):
				push_error("普通敌人池与 Boss 池不能包含同一种敌人");
				return true;
	if _collection_pool_is_invalid():
		return true;
	if map_definition.randomize_route_contents:
		if unexpected_encounter_pool.is_empty():
			push_error("随机路线需要不期而遇内容池");
			return true;
		var event_ids:Dictionary = {};
		for content in unexpected_encounter_pool:
			if content == null or content.is_invalid() or event_ids.has(content.encounter_id):
				push_error("不期而遇内容无效或ID重复");
				return true;
			event_ids[content.encounter_id] = true;
			for option in content.options:
				if option.operation == UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD and option.candidate_pool(character_definition.reward_card_pool).size() < option.candidate_count:
					push_error("不期而遇选牌需要至少三张相应稀有度卡牌");
					return true;
	return false;


func _collection_pool_is_invalid()->bool:
	if collection_pool.is_empty():
		return false;
	if collection_option_count != 3 or collection_pool.size() < collection_option_count:
		push_error("开局藏品必须三选一，且藏品池至少包含三件不同藏品");
		return true;
	var ids:Dictionary = {};
	for collection in collection_pool:
		if collection == null or collection.is_invalid():
			push_error("藏品池包含无效藏品");
			return true;
		if ids.has(collection.collection_id):
			push_error("藏品池不能重复配置同一藏品");
			return true;
		ids[collection.collection_id] = true;
	if map_definition.starting_node_ids.size() != 1:
		push_error("配置藏品的冒险必须有唯一开始节点");
		return true;
	var start:MapNodeDefinition = map_definition.get_node_by_id(map_definition.starting_node_ids[0]);
	if start.node_type != MapNodeDefinition.NodeType.START:
		push_error("藏品选择必须设置在地图的开始节点");
		return true;
	for node in map_definition.nodes:
		if node.node_type == MapNodeDefinition.NodeType.START and node != start:
			push_error("配置藏品的地图不能包含多个开始节点");
			return true;
	return false;


func _encounter_pool_is_invalid(pool:Array[EncounterDefinition], minimum:int, label:String)->bool:
	if pool.size() < minimum:
		push_error("%s随机池至少需要 %d 种敌人" % [label, minimum]);
		return true;
	var encounter_ids:Dictionary = {};
	var enemy_ids:Dictionary = {};
	for encounter in pool:
		if encounter == null or encounter.is_invalid():
			push_error("%s随机池包含无效遭遇" % label);
			return true;
		var enemy_id:String = encounter.enemy_definition.combatant_id;
		if encounter_ids.has(encounter.encounter_id) or enemy_ids.has(enemy_id):
			push_error("%s随机池不能重复配置遭遇或敌人" % label);
			return true;
		encounter_ids[encounter.encounter_id] = true;
		enemy_ids[enemy_id] = true;
	return false;
