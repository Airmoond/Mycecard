## 一张武器牌在本场战斗中的独立数值，由对应CardInstance持有。
## 卡牌回手时保留这个对象，下一场战斗才创建新对象。
class_name WeaponInstance
extends RefCounted


## 此武器实例引用的只读静态定义。
var definition:WeaponDefinition;

## 包含武器自身强化，不包含角色力量等攻击结算修正。
var current_attack:int;
## 本场强化后的最大耐久，回手重装时仍保留。
var max_durability:int;
## 当前剩余耐久；装备时恢复至本场最大值，每次武器攻击消耗一点。
var current_durability:int;


## 由CardInstance在卡牌定义验证通过后创建，无需再次验证同一份配置。
func _init(weapon_definition:WeaponDefinition)->void:
	definition = weapon_definition;
	current_attack = definition.base_attack;
	max_durability = definition.base_max_durability;
	restore_durability();


## 装备时恢复到本场当前最大耐久，不重置攻击力或已增加的最大耐久。
func restore_durability()->void:
	current_durability = max_durability;


## 强化只修改本场实例；增加最大耐久时，当前耐久也增加相同数值。
## 正数由效果定义验证，这里不重复检查或恢复到满耐久。
func enhance(attack_bonus:int, durability_bonus:int)->void:
	current_attack += attack_bonus;
	max_durability += durability_bonus;
	current_durability += durability_bonus;
