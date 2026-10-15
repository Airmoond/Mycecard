## 不期而遇的共享只读内容；候选、选择及结果保存在本局节点状态。
class_name UnexpectedEncounterDefinition
extends Resource

enum Kind { CAMP, ALTAR, FOUNTAIN }

@export var encounter_id:String
@export var display_name:String
@export_multiline var story:String
@export var artwork:Texture2D
@export var options:Array[UnexpectedEncounterOptionDefinition] = [];
## 旧内容分类和测试读取的兼容元数据；正式操作只读取 options。
@export var kind:Kind
@export var heal_amount:int = 0
@export var health_cost:int = 0

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

func get_option(option_id:String)->UnexpectedEncounterOptionDefinition:
	for option in options:
		if option.option_id == option_id:
			return option;
	return null;

func first_card_option()->UnexpectedEncounterOptionDefinition:
	for option in options:
		if option.operation == UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
			return option;
	return null;

func card_rarities()->Array[int]:
	var option:UnexpectedEncounterOptionDefinition = first_card_option();
	return option.card_rarities.duplicate() if option != null else [];

func candidate_pool(character_pool:Array[CardDefinition])->Array[CardDefinition]:
	var option:UnexpectedEncounterOptionDefinition = first_card_option();
	return option.candidate_pool(character_pool) if option != null else [];
