## 静态地图节点；随机遭遇和冒险进度只保存在 RunState。
class_name MapNodeDefinition
extends Resource


## 保持旧资源中的三种枚举数值，START 追加在末尾。
enum NodeType { BATTLE, REST, BOSS, START, ROUTE_SLOT, UNEXPECTED }

@export var node_id:String
@export var display_name:String
@export var node_type:NodeType
@export var map_position:Vector2
@export var next_node_ids:Array[String] = []

## 同一支线的三个节点使用相同 ID；开始和最终 Boss 留空。
@export var route_id:String = ""

## 固定遭遇用于旧地图；随机节点改由 RunDefinition 的对应池提供。
@export var encounter_definition:EncounterDefinition
@export var random_encounter:bool = false
@export var heal_amount:int = 0


func requires_encounter()->bool:
	return node_type in [NodeType.BATTLE, NodeType.BOSS];


func is_invalid()->bool:
	if node_id.is_empty() or display_name.is_empty():
		push_error("地图节点 ID 和显示名称不能为空");
		return true;
	if not NodeType.values().has(node_type):
		push_error("地图节点类型无效：%s" % node_id);
		return true;
	if not map_position.is_finite():
		push_error("地图节点坐标无效：%s" % node_id);
		return true;
	var next_ids:Dictionary = {};
	for next_id in next_node_ids:
		if next_id.is_empty() or next_ids.has(next_id):
			push_error("地图后继 ID 为空或重复：%s" % node_id);
			return true;
		next_ids[next_id] = true;
	if requires_encounter():
		if heal_amount != 0:
			push_error("战斗节点不能同时提供休整治疗：%s" % node_id);
			return true;
		if random_encounter:
			if encounter_definition != null:
				push_error("随机节点不能同时指定固定遭遇：%s" % node_id);
				return true;
		elif encounter_definition == null or encounter_definition.is_invalid():
			push_error("固定战斗节点缺少合法遭遇：%s" % node_id);
			return true;
	else:
		if random_encounter or encounter_definition != null:
			push_error("非战斗节点不能配置遭遇：%s" % node_id);
			return true;
		if node_type == NodeType.REST and heal_amount <= 0:
			push_error("休整治疗量必须大于 0：%s" % node_id);
			return true;
		if node_type == NodeType.START and (heal_amount != 0 or not route_id.is_empty()):
			push_error("开始节点不能提供治疗或属于某条支线");
			return true;
		if node_type in [NodeType.ROUTE_SLOT, NodeType.UNEXPECTED] and heal_amount != 0:
			push_error("不期而遇与随机位置不能携带旧休整治疗");
			return true;
	return false;
