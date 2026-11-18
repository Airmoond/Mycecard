## 选项的内容配置；现有操作可组合成新内容，无需修改流程或页面。
class_name UnexpectedEncounterOptionDefinition
extends Resource

enum Operation { LEAVE, HEAL, GAIN_CARD, REMOVE_CARD }
enum SelectionKind { NONE, CARD, DECK_CARD }

## 同一不期而遇内唯一的选项标识，用于候选和结果关联。
@export var option_id:String;
## 事件页面显示的选项按钮文本。
@export var label:String;
## 结果文案模板，由视图填入实际治疗、支付及卡牌名称。
@export_multiline var result_text:String;
## 选择此选项后执行的局部规则操作。
@export var operation:Operation = Operation.LEAVE;
## 治疗操作请求恢复的生命量，实际恢复不超过本局上限。
@export var heal_amount:int = 0;
## 获得卡牌前支付的生命费用；支付后必须仍有生命。
@export var health_cost:int = 0;
## 获得卡牌操作允许的候选稀有度。
@export var card_rarities:Array[int] = [];
## 从获得卡牌候选池中排除的稳定卡牌标识。
@export var excluded_card_ids:Array[String] = [];
## 获得卡牌时抽取的候选数，当前配置要求为 [code]3[/code]。
@export var candidate_count:int = 3;
## 选项不可用时显示的解释文本。
@export var disabled_reason:String = "";

## 根据选项操作返回无需选牌、选择候选卡牌或选择已有牌组卡牌的输入类型。
func get_selection_kind()->SelectionKind:
	if operation == Operation.GAIN_CARD:
		return SelectionKind.CARD;
	if operation == Operation.REMOVE_CARD:
		return SelectionKind.DECK_CARD;
	return SelectionKind.NONE;

## 从角色卡池按允许稀有度及排除标识筛选获得卡牌的候选池，不进行随机抽样。
func candidate_pool(character_pool:Array[CardDefinition])->Array[CardDefinition]:
	var result:Array[CardDefinition] = [];
	for card in CardPoolSampler.filter_pool(character_pool, card_rarities):
		if card.card_id not in excluded_card_ids:
			result.append(card);
	return result;

## 检查选项基础字段与操作专属配置；费用、候选数量或筛选配置不符合操作要求时返回 [code]true[/code]。
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
