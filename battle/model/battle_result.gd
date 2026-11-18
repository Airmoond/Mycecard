## 单次战斗的提交结果，携带所属战斗与地图节点身份。
class_name BattleResult
extends RefCounted

## 生成此结果的战斗身份，整局会话据此拒绝重复或过期提交。
var battle_id:String
## 此战斗所属的地图节点身份。
var node_id:String
## 是否为玩家胜利；双方同时死亡时规则按玩家失败生成结果。
var victory:bool
## 本场全部已结算效果后的玩家剩余生命。
var player_health:int
## 本场结束时的玩家实际最大生命，供整局状态继续使用。
var player_max_health:int
