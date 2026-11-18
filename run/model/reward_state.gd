## 一次普通战斗的奖励进度；候选属于当前轮，界面重建不能重新抽取。
class_name RewardState
extends RefCounted

## 产生此奖励的普通战斗节点标识。
var node_id:String = "";
## 产生此奖励的战斗标识，用于关联已提交的胜利结果。
var battle_id:String = "";
## 本场奖励需要完成的领取或跳过总轮数。
var total_rounds:int = 0;
## 当前轮的从零开始的索引，也等于已经记录的选择次数。
var round_index:int = 0;
## 尚未领取或跳过的奖励轮数。
var remaining_rounds:int = 0;
## 当前轮已抽取的只读候选；页面重建时复用，不重新抽取。
var candidates:Array[CardDefinition] = [];
## 按轮次保存的只读选择记录，包含卡牌及是否跳过。
var selections:Array[Dictionary] = [];

## 记录奖励所属节点、战斗与总轮数，并将剩余轮数初始化为总轮数。
func _init(source_node:String = "", source_battle:String = "", rounds:int = 0)->void:
	node_id = source_node;
	battle_id = source_battle;
	total_rounds = rounds;
	remaining_rounds = rounds;

## 复制本轮卡牌候选并将候选数组设为只读，不修改调用者的数组。
func set_candidates(options:Array[CardDefinition])->void:
	candidates = options.duplicate();
	candidates.make_read_only();

## 记录当前轮选择并推进轮次；[param card] 为 [code]null[/code] 表示跳过本轮。
func record_selection(card:CardDefinition)->void:
	var selection:Dictionary = {"round_index": round_index, "card": card, "skipped": card == null};
	selection.make_read_only();
	selections.append(selection);
	round_index += 1;
	remaining_rounds -= 1;

## 检查奖励身份、轮次、选择记录和候选是否与指定卡池及候选数量一致，返回是否无效。
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
