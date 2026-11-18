## 武器的静态数值、无视格挡开关与损坏规则，由武器牌的CardDefinition引用。
## 名称、费用和原画仍属于卡牌；强化与耐久损耗不能写回本资源。
class_name WeaponDefinition
extends Resource


## 普通武器损坏后消耗；“永恒”使用回手规则，不按卡名判断。
enum BreakDestination {
	EXHAUST,
	RETURN_TO_HAND
}

## 武器实例创建时的基础攻击力，不包含角色力量或本场强化，不能为负数。
@export var base_attack:int = 0;
## 武器实例创建时的最大耐久，必须大于零。
@export var base_max_durability:int = 1;
## 耐久耗尽或被替换时，原武器卡消耗或尝试回手的去向规则。
@export var break_destination:BreakDestination = BreakDestination.EXHAUST;

## 武器攻击绕过目标格挡且不削减格挡；仍正常计算力量、虚弱和易伤。
@export var ignores_block:bool = false;


## 每次有效武器攻击造成伤害后触发；0表示没有该项效果。
## 新力量不影响本次伤害，抽牌仍遵守禁抽和手牌上限。
@export var strength_on_attack:int = 0;
@export var draw_on_attack:int = 0;


## 在加载卡牌配置时检查数值与规则，不处理实际的装备或损坏。
func is_invalid()->bool:
	if base_attack < 0:
		push_error("武器基础攻击力不能小于0");
		return true;
	if base_max_durability <= 0:
		push_error("武器最大耐久必须大于0");
		return true;
	if not BreakDestination.values().has(break_destination):
		push_error("武器损坏去向无效");
		return true;
	if strength_on_attack < 0 or draw_on_attack < 0:
		push_error("武器攻击后的力量和抽牌数不能为负数");
		return true;
	return false;
