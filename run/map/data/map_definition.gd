## 地图拓扑是只读资源；分支选择和随机遭遇由 RunState 保存。
class_name MapDefinition
extends Resource

@export var map_id:String
@export var nodes:Array[MapNodeDefinition] = []
@export var starting_node_ids:Array[String] = []

## 第五阶段地图固定为开始 → 三条战斗、战斗、休整支线 → 共用 Boss。
## 默认关闭，以兼容已有固定遭遇的线性地图。
@export var is_branch_map:bool = false

## 第六阶段只随机九个中间位置的内容，连接与头尾保持固定。
@export var randomize_route_contents:bool = false


func get_node_by_id(node_id:String)->MapNodeDefinition:
	for node in nodes:
		if node != null and node.node_id == node_id:
			return node;
	return null;


func has_node(node_id:String)->bool:
	return get_node_by_id(node_id) != null;


func get_route_ids()->Array[String]:
	var result:Array[String] = [];
	if not is_branch_map or starting_node_ids.size() != 1:
		return result;
	var start:MapNodeDefinition = get_node_by_id(starting_node_ids[0]);
	if start == null:
		return result;
	for entry_id in start.next_node_ids:
		var entry:MapNodeDefinition = get_node_by_id(entry_id);
		if entry != null and not entry.route_id.is_empty() and not result.has(entry.route_id):
			result.append(entry.route_id);
	return result;


## 仅返回支线的三个节点，不包含共同的开始或 Boss。
func get_route_node_ids(route_id:String)->Array[String]:
	var result:Array[String] = [];
	if not is_branch_map or route_id.is_empty() or starting_node_ids.size() != 1:
		return result;
	var start:MapNodeDefinition = get_node_by_id(starting_node_ids[0]);
	if start == null:
		return result;
	for entry_id in start.next_node_ids:
		var current:MapNodeDefinition = get_node_by_id(entry_id);
		if current == null or current.route_id != route_id:
			continue;
		while current != null and current.route_id == route_id and not result.has(current.node_id):
			result.append(current.node_id);
			if current.next_node_ids.size() != 1:
				break;
			current = get_node_by_id(current.next_node_ids[0]);
		break;
	return result;


func is_invalid()->bool:
	if randomize_route_contents and not is_branch_map:
		push_error("随机支线内容必须使用三路线地图");
		return true;
	if map_id.is_empty() or nodes.is_empty() or starting_node_ids.is_empty():
		push_error("地图 ID、节点和起点不能为空");
		return true;
	var node_ids:Dictionary = {};
	var boss_count:int = 0;
	for node in nodes:
		if node == null or node.is_invalid():
			push_error("地图包含无效节点");
			return true;
		if (node.node_type == MapNodeDefinition.NodeType.ROUTE_SLOT and not randomize_route_contents) or node.node_type == MapNodeDefinition.NodeType.UNEXPECTED:
			push_error("不期而遇实际类型仅由随机支线位置在局内绑定");
			return true;
		if node_ids.has(node.node_id):
			push_error("地图节点 ID 重复：%s" % node.node_id);
			return true;
		node_ids[node.node_id] = true;
		if node.node_type == MapNodeDefinition.NodeType.BOSS:
			boss_count += 1;
	if boss_count == 0:
		push_error("地图缺少 Boss 节点");
		return true;
	var starting_ids:Dictionary = {};
	for starting_id in starting_node_ids:
		if not node_ids.has(starting_id) or starting_ids.has(starting_id):
			push_error("地图起点不存在或重复：%s" % starting_id);
			return true;
		starting_ids[starting_id] = true;
	for node in nodes:
		for next_id in node.next_node_ids:
			if next_id == node.node_id or not node_ids.has(next_id):
				push_error("地图连接指向自身或不存在的节点：%s → %s" % [node.node_id, next_id]);
				return true;
	if not _all_nodes_are_reachable():
		push_error("地图存在无法从起点到达的节点");
		return true;
	if is_branch_map and _branch_structure_is_invalid(boss_count):
		return true;
	return false;


func _branch_structure_is_invalid(boss_count:int)->bool:
	if nodes.size() != 11 or starting_node_ids.size() != 1 or boss_count != 1:
		push_error("分支地图必须包含 11 个节点、一个开始和一个最终 Boss");
		return true;
	var start:MapNodeDefinition = get_node_by_id(starting_node_ids[0]);
	if start.node_type != MapNodeDefinition.NodeType.START or start.next_node_ids.size() != 3:
		push_error("分支地图开始节点必须连接三条支线");
		return true;
	var routes:Dictionary = {};
	var visited:Dictionary = {};
	visited[start.node_id] = true;
	var boss_id:String = "";
	for entry_id in start.next_node_ids:
		var current:MapNodeDefinition = get_node_by_id(entry_id);
		var route:String = current.route_id;
		if route.is_empty() or routes.has(route):
			push_error("三条支线必须使用不同且非空的 route_id");
			return true;
		routes[route] = true;
		for depth in range(3):
			var expected_type:int = MapNodeDefinition.NodeType.ROUTE_SLOT if randomize_route_contents else (MapNodeDefinition.NodeType.REST if depth == 2 else MapNodeDefinition.NodeType.BATTLE);
			if current == null or visited.has(current.node_id) or current.route_id != route or current.node_type != expected_type or current.next_node_ids.size() != 1:
				push_error("每条支线必须独立按战斗 → 战斗 → 休整连接");
				return true;
			if not randomize_route_contents and depth < 2 and not current.random_encounter:
				push_error("分支地图的普通战斗必须使用本局随机遭遇");
				return true;
			visited[current.node_id] = true;
			current = get_node_by_id(current.next_node_ids[0]);
		if current == null or current.node_type != MapNodeDefinition.NodeType.BOSS or not current.route_id.is_empty() or not current.random_encounter or not current.next_node_ids.is_empty():
			push_error("每条休整支线必须汇合到无后继的随机最终 Boss");
			return true;
		if not boss_id.is_empty() and boss_id != current.node_id:
			push_error("三条支线必须汇合到同一个 Boss 节点");
			return true;
		boss_id = current.node_id;
	visited[boss_id] = true;
	if visited.size() != nodes.size():
		push_error("分支地图存在多余节点、环路或死路");
		return true;
	return false;


func _all_nodes_are_reachable()->bool:
	var pending:Array[String] = starting_node_ids.duplicate();
	var visited:Dictionary = {};
	var index:int = 0;
	while index < pending.size():
		var current_id:String = pending[index];
		index += 1;
		if visited.has(current_id):
			continue;
		var current:MapNodeDefinition = get_node_by_id(current_id);
		if current == null:
			return false;
		visited[current_id] = true;
		pending.append_array(current.next_node_ids);
	return visited.size() == nodes.size();
