## 一次普通战斗的奖励进度；候选属于当前轮，界面重建不能重新抽取。
class_name RewardState
extends RefCounted

var node_id:String = "";
var battle_id:String = "";
var total_rounds:int = 0;
var round_index:int = 0;
var remaining_rounds:int = 0;
var candidates:Array[CardDefinition] = [];
var selections:Array[Dictionary] = [];

func _init(source_node:String = "", source_battle:String = "", rounds:int = 0)->void:
	node_id = source_node;
	battle_id = source_battle;
	total_rounds = rounds;
	remaining_rounds = rounds;

func set_candidates(options:Array[CardDefinition])->void:
	candidates = options.duplicate();
	candidates.make_read_only();

func record_selection(card:CardDefinition)->void:
	var selection:Dictionary = {"round_index": round_index, "card": card, "skipped": card == null};
	selection.make_read_only();
	selections.append(selection);
	round_index += 1;
	remaining_rounds -= 1;

func is_invalid(pool:Array[CardDefinition], option_count:int)->bool:
	if node_id.is_empty() or battle_id.is_empty() or total_rounds <= 0 or remaining_rounds < 0 or round_index < 0 or round_index + remaining_rounds != total_rounds or selections.size() != round_index:
		return true;
	for index in range(selections.size()):
		var selection:Dictionary = selections[index];
		var card:CardDefinition = selection.get("card") as CardDefinition;
		if selection.get("round_index", -1) != index or not selection.is_read_only() or selection.get("skipped") != (card == null):
			return true;
		if card != null and (not pool.has(card) or card.rarity not in CardPoolSampler.REWARD_RARITIES):
			return true;
	if remaining_rounds == 0:
		return not candidates.is_empty();
	if candidates.size() != option_count or not candidates.is_read_only():
		return true;
	var ids:Dictionary = {};
	for card in candidates:
		if card == null or not pool.has(card) or card.rarity not in CardPoolSampler.REWARD_RARITIES or ids.has(card.card_id):
			return true;
		ids[card.card_id] = true;
	return false;
