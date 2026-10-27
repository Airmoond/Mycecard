## 描述一场单敌人战斗中的敌人与基础规则。
##
## EncounterDefinition保存遭遇ID、敌人定义、每回合能量、每回合抽牌数和
## 手牌上限。玩家定义、实际牌组与当前生命由外部游戏流程单独传给BattleController，
## 因此同一份遭遇可以服务于不同玩家或不同局内牌组。
##
## 该资源在战斗过程中必须视为只读数据。它不保存当前生命、格挡、能量、回合、
## 牌堆或敌人行动下标，也不直接创建或修改任何运行时状态。
class_name EncounterDefinition
extends Resource


## 程序内部使用的稳定唯一遭遇ID，例如cave_crawler_encounter。
##
## 该ID用于识别和切换遭遇，不应随着显示文字或语言变化而改变，且不能为空。
@export var encounter_id:String


## 本场遭遇使用的敌人静态定义。
##
## 用于创建新的EnemyState，并提供敌人基础数据与固定行动模式；不能为空且必须合法。
@export var enemy_definition:EnemyDefinition


## 玩家每个回合开始时恢复的基础能量。
##
## 该数值必须大于或等于0；0能量遭遇仍然属于合法配置。
@export var energy_per_turn:int = 3


## 玩家每个回合开始时尝试抽取的卡牌数量。
##
## 该数值必须大于0，并且不能超过max_hand_size。
@export var cards_per_turn:int = 5


## 玩家在本场遭遇中能够持有的最大手牌数量。
##
## 该数值必须大于0，并作为BattleState处理普通抽牌和抽牌效果时的统一上限。
@export var max_hand_size:int = 10


## 检查当前遭遇定义是否包含无法安全创建战斗的静态数据。
##
## 遭遇ID为空、敌人定义为空或非法，或者任意战斗规则参数非法时，
## 推送对应错误并返回true。所有字段均合法时返回false。
## 该方法只检查遭遇自身的数据，不验证外部传入的玩家、牌组或当前生命。
func is_invalid()->bool:
	if encounter_id.is_empty():#每场遭遇都必须拥有稳定的内部识别ID
		push_error("Invalid encounter_id! 遭遇ID为空");#报告缺少遭遇身份配置
		return true;#无法识别的遭遇不能作为战斗入口
	if enemy_definition == null:#敌人定义负责提供生命、原画和行动模式
		push_error("Invalid enemy_definition! 遭遇的敌人定义为空");#报告缺少敌人静态数据
		return true;#没有敌人时无法创建本阶段的单敌人战斗
	if enemy_definition.is_invalid():#敌人基础数据和全部行动都必须完整合法
		push_error("Invalid enemy_definition! 遭遇的敌人定义无效");#补充遭遇配置层的错误上下文
		return true;#非法敌人定义不能用于EnemyState初始化
	if energy_per_turn < 0:#0能量合法，但负数无法表达正常回合资源
		push_error("Invalid energy_per_turn! 每回合能量不能小于0");#报告非法能量规则
		return true;#非法能量不能传入BattleState
	if cards_per_turn <= 0:#每个玩家回合必须配置正数抽牌数量
		push_error("Invalid cards_per_turn! 每回合抽牌数必须大于0");#报告无法开始回合的抽牌规则
		return true;#非正数抽牌量不属于当前阶段的合法遭遇
	if max_hand_size <= 0:#手牌上限必须能够容纳至少一张卡牌
		push_error("Invalid max_hand_size! 手牌上限必须大于0");#报告非法手牌规则
		return true;#非正数上限会破坏正常抽牌流程
	if cards_per_turn > max_hand_size:#基础回合抽牌量不能从一开始就超过手牌容量
		push_error("Invalid cards_per_turn! 每回合抽牌数不能超过手牌上限");#报告互相冲突的遭遇规则
		return true;#拒绝无法完整满足的基础回合配置

	return false;#敌人引用与全部单场战斗规则均合法，当前遭遇可以使用
