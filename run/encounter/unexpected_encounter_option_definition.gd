## 选项的内容配置；现有操作可组合成新内容，无需修改流程或页面。
class_name UnexpectedEncounterOptionDefinition
extends Resource

enum Operation { LEAVE, HEAL, GAIN_CARD, REMOVE_CARD }
enum SelectionKind { NONE, CARD, DECK_CARD }

@export var option_id:String;
@export var label:String;
@export_multiline var result_text:String;
@export var operation:Operation = Operation.LEAVE;
@export var heal_amount:int = 0;
@export var health_cost:int = 0;
@export var card_rarities:Array[int] = [];
@export var excluded_card_ids:Array[String] = [];
@export var candidate_count:int = 3;
@export var disabled_reason:String = "";

func get_selection_kind()->SelectionKind:
	if operation == Operation.GAIN_CARD:
		return SelectionKind.CARD;
	if operation == Operation.REMOVE_CARD:
		return SelectionKind.DECK_CARD;
	return SelectionKind.NONE;

func candidate_pool(character_pool:Array[CardDefinition])->Array[CardDefinition]:
	var result:Array[CardDefinition] = [];
	for card in CardPoolSampler.filter_pool(character_pool, card_rarities):
		if card.card_id not in excluded_card_ids:
			result.append(card);
	return result;

func is_invalid()->bool:
	if option_id.is_empty() or label.is_empty() or result_text.is_empty() or not Operation.values().has(operation) or health_cost < 0:
		return true;
	if operation == Operation.HEAL:
		return heal_amount <= 0 or health_cost != 0 or not card_rarities.is_empty() or not excluded_card_ids.is_empty();
	if operation != Operation.GAIN_CARD:
		return heal_amount != 0 or health_cost != 0 or not card_rarities.is_empty() or not excluded_card_ids.is_empty();
	if heal_amount != 0 or candidate_count != 3 or card_rarities.is_empty():
		return true;
	var rarities:Dictionary = {};
	for rarity in card_rarities:
		if not CardDefinition.CardRarity.values().has(rarity) or rarities.has(rarity):
			return true;
		rarities[rarity] = true;
	var ids:Dictionary = {};
	for card_id in excluded_card_ids:
		if card_id.is_empty() or ids.has(card_id):
			return true;
		ids[card_id] = true;
	return false;
