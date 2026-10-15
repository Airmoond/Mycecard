## 藏品只读定义；持有记录属于 RunState，战斗效果属于本场战斗状态。
class_name CollectionDefinition
extends Resource

enum EffectType { STARTING_STRENGTH, EARLY_TURN_BLOCK, NORMAL_VICTORY_HEAL }

@export var collection_id:String
@export var display_name:String
@export_multiline var description:String
@export var icon:Texture2D
@export var effect_type:EffectType = EffectType.STARTING_STRENGTH
@export var amount:int = 1
@export var turn_limit:int = 0


func is_invalid()->bool:
	if collection_id.is_empty() or display_name.is_empty() or description.is_empty():
		push_error("藏品 ID、名称和效果说明不能为空");
		return true;
	if icon == null:
		push_error("藏品必须配置图标：%s" % collection_id);
		return true;
	if not EffectType.values().has(effect_type) or amount <= 0:
		push_error("藏品效果类别无效或效果数值不是正数：%s" % collection_id);
		return true;
	if effect_type == EffectType.EARLY_TURN_BLOCK:
		if turn_limit <= 0:
			push_error("回合开始格挡藏品必须配置正数回合上限：%s" % collection_id);
			return true;
	elif turn_limit != 0:
		push_error("非限回合格挡藏品不能配置回合上限：%s" % collection_id);
		return true;
	return false;
