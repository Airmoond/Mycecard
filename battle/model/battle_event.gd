## 已执行的一段真实结果；消费者不得据此改变规则。
class_name BattleEvent
extends RefCounted

## 产生此实际结果的战斗标识。
var battle_id:String
## 本场战斗内递增的事件序号，用于保留逐段结算顺序。
var sequence:int
## 结果的逻辑来源标识，通常为玩家、敌人或战斗初始化。
var source_id:StringName
## 表现目标标识，用于定位玩家、敌人、能量或武器区域。
var target_id:StringName
## 实际结果的类型标识，例如伤害、格挡、治疗或能量变化。
var kind:StringName
## 此事件报告的实际数值；具体含义与正负约定由事件类型决定。
var amount:int
