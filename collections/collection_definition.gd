## 藏品只读定义；持有记录属于 RunState，战斗效果属于本场战斗状态。
class_name CollectionDefinition
extends Resource

enum EffectType { STARTING_STRENGTH, EARLY_TURN_BLOCK, NORMAL_VICTORY_HEAL }

## 藏品的稳定标识，用于候选去重与配置验证。
@export var collection_id:String
## 显示给玩家的藏品名称。
@export var display_name:String
## 显示给玩家的完整藏品效果说明。
@export_multiline var description:String
## 藏品选择页和查看器使用的图标，必须配置。
@export var icon:Texture2D
## 决定藏品在战斗开始、回合开始或普通胜利后生效的规则类型。
@export var effect_type:EffectType = EffectType.STARTING_STRENGTH
## 藏品效果的正数数值，按类型表示力量、格挡或治疗量。
@export var amount:int = 1
## 回合开始格挡效果允许触发的前若干回合；其他效果必须为 [code]0[/code]。
@export var turn_limit:int = 0


## 检查藏品基础信息、图标、效果数值与回合限制；发现首个错误时报告并返回 [code]true[/code]。
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
