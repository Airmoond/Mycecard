## 持续能力的只读定义；角色是否拥有能力由CombatantState保存。
class_name PowerDefinition
extends Resource

enum PowerType { RETAIN_BLOCK, TURN_START_HEALTH_FOR_BLOCK }

## 持续能力的规则类型，决定去重方式及触发时机。
@export var power_type:PowerType = PowerType.RETAIN_BLOCK;
## 角色状态及敌人意图中显示的能力名称。
@export var display_name:String;
## 能力的完整效果说明。
@export_multiline var description:String;


## 仅TURN_START_HEALTH_FOR_BLOCK使用；每份能力独立先失血、再获得格挡。
@export var health_loss:int = 0;
@export var block_gain:int = 0;


## 配置入口验证种类与显示内容；运行时施加能力不重复验证。
func is_invalid()->bool:
	if not PowerType.values().has(power_type):
		push_error("能力类型无效");
		return true;
	if display_name.is_empty() or description.is_empty():
		push_error("能力需要名称和说明");
		return true;
	if power_type == PowerType.TURN_START_HEALTH_FOR_BLOCK and (health_loss <= 0 or block_gain <= 0):
		push_error("回合开始失血换格挡能力的两个数值必须为正数");
		return true;
	return false;
