## 描述起始牌组中一种卡牌及其配置数量的静态资源。
##
## 每个DeckEntryDefinition引用一份CardDefinition，并用count表示这种卡牌需要
## 放入起始牌组的数量。CharacterDefinition保存多个条目，RunState将其展开为实际牌组，
## 每场战斗再根据实际牌组创建彼此独立的CardInstance。
##
## 该资源在战斗过程中必须视为只读数据。它不创建CardInstance，不记录卡牌所在牌堆，
## 也不直接修改BattleState中的抽牌堆、手牌或弃牌堆。
class_name DeckEntryDefinition
extends Resource


## 当前牌组条目引用的静态卡牌定义。
##
## 多个运行时CardInstance可以共享这份定义，但控制器必须为count中的每一张牌分别
## 创建一个新的CardInstance。该字段不能为空，并且引用的CardDefinition必须合法。
@export var card_definition:CardDefinition


## 这种卡牌需要加入起始牌组的数量。
##
## 该数值必须大于0。它只描述静态牌组配置，不代表战斗中任何牌堆的当前数量。
@export var count:int = 1


## 检查当前牌组条目是否包含非法静态数据。
##
## card_definition为空、卡牌定义本身非法或count小于等于0时，推送对应错误并返回true。
## 所有字段均合法时返回false。该方法只检查数据，不会修复资源或创建CardInstance。
func is_invalid()->bool:
	if card_definition == null:#牌组条目必须明确指定需要创建的卡牌种类
		push_error("Invalid card_definition! 牌组条目的卡牌定义为空");#报告缺少静态卡牌来源
		return true;#没有卡牌定义就不能生成运行时卡牌实例
	if card_definition.is_invalid():#条目不能引用字段不完整或效果非法的卡牌定义
		push_error("Invalid card_definition! 牌组条目引用的卡牌定义无效");#补充牌组条目这一层的错误上下文
		return true;#非法卡牌不能进入任何遭遇的起始牌组
	if count <= 0:#至少需要配置一张卡牌，这个条目才有实际意义
		push_error("Invalid count! 牌组条目的卡牌数量必须大于0");#报告零数量或负数量配置
		return true;#非法数量不能用于控制器的实例创建循环

	return false;#卡牌定义与配置数量均合法，当前牌组条目可以使用
