## 不期而遇的共享只读内容；候选、选择及结果保存在本局节点状态。
class_name UnexpectedEncounterDefinition
extends Resource

enum Kind { CAMP, ALTAR, FOUNTAIN }

## 不期而遇内容的稳定标识，不同地图位置仍各自保存局内状态。
@export var encounter_id:String
## 显示在地图和事件页面中的内容名称。
@export var display_name:String
## 显示在事件选项前的故事文本。
@export_multiline var story:String
## 事件页面使用的插图，可以为空。
@export var artwork:Texture2D
## 按显示顺序保存的只读选项定义，必须包含离开选项。
@export var options:Array[UnexpectedEncounterOptionDefinition] = [];
## 旧内容分类和测试读取的兼容元数据；正式操作只读取 options。
@export var kind:Kind
@export var heal_amount:int = 0
@export var health_cost:int = 0

## 检查内容标识、名称、故事及选项有效性；选项标识重复或没有离开选项时也返回 [code]true[/code]。
func is_invalid()->bool:
	if encounter_id.is_empty() or display_name.is_empty() or story.is_empty() or options.is_empty():
		return true;
	var ids:Dictionary = {};
	var has_leave:bool = false;
	for option in options:
		if option == null or option.is_invalid() or ids.has(option.option_id):
			return true;
		ids[option.option_id] = true;
		has_leave = has_leave or option.operation == UnexpectedEncounterOptionDefinition.Operation.LEAVE;
	return not has_leave;

## 返回标识匹配的选项定义；没有匹配项时返回 [code]null[/code]。
func get_option(option_id:String)->UnexpectedEncounterOptionDefinition:
	for option in options:
		if option.option_id == option_id:
			return option;
	return null;

## 返回配置顺序中的第一个获得卡牌选项；没有此类选项时返回 [code]null[/code]。
func first_card_option()->UnexpectedEncounterOptionDefinition:
	for option in options:
		if option.operation == UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
			return option;
	return null;

## 返回首个获得卡牌选项允许的稀有度副本；没有此类选项时返回空数组。
func card_rarities()->Array[int]:
	var option:UnexpectedEncounterOptionDefinition = first_card_option();
	return option.card_rarities.duplicate() if option != null else [];

## 返回首个获得卡牌选项从角色卡池筛出的候选；没有此类选项时返回空数组。
func candidate_pool(character_pool:Array[CardDefinition])->Array[CardDefinition]:
	var option:UnexpectedEncounterOptionDefinition = first_card_option();
	return option.candidate_pool(character_pool) if option != null else [];
