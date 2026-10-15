## 地图只读取本局已生成的遭遇与进度，不在刷新或缩放时重新随机。
class_name MapView
extends Control

const MAP_NODE_VIEW_SCENE:PackedScene = preload("res://run/map/map_node_view.tscn");
const COLLECTION_INSPECTOR_SCENE:PackedScene = preload("res://ui/inspect/collection_inspector.tscn");
const CARD_INSPECTOR_SCENE:PackedScene = preload("res://ui/inspect/card_inspector.tscn");
const DESIGN_SIZE:Vector2 = Vector2(1024.0, 600.0);
const NODE_SIZE:Vector2 = Vector2(145.0, 86.0);
const CONNECTION_WIDTH:float = 3.0;
const CONNECTION_COLOR:Color = Color(0.45, 0.33, 0.18, 0.65);
const ACTIVE_CONNECTION_COLOR:Color = Color(0.9, 0.68, 0.28, 1.0);
const COMPLETED_CONNECTION_COLOR:Color = Color(0.38, 0.62, 0.42, 1.0);
const EXCLUDED_CONNECTION_COLOR:Color = Color(0.42, 0.38, 0.31, 0.28);

signal node_selected(node_id:String);

var map_definition:MapDefinition;
var run_state:RunState;
var _node_views:Dictionary = {};
var _selection_reported:bool = false;
var _layout_scale:float = 1.0;
var _layout_origin:Vector2 = Vector2.ZERO;
var _layout_queued:bool = false;
var _collection_inspector:CollectionInspector;
var _card_inspector:CardInspector;
var _overlay_host:OverlayHost;

@onready var connection_layer:Control = $connection_layer;
@onready var node_layer:Control = $node_layer;
@onready var annotation_layer:Control = $annotation_layer;
@onready var health_label:Label = $top_bar/health_label;
## 保留旧节点与字段名，牌组数量现在同时是查看按钮。
@onready var deck_label:Button = $top_bar/deck_label;
@onready var deck_button:Button = $top_bar/deck_label;
@onready var collection_button:Button = $top_bar/collection_button;
@onready var route_hint:Label = $route_hint;

func _ready()->void:
	resized.connect(_queue_layout);
	collection_button.pressed.connect(_open_collection_inspector);
	deck_button.pressed.connect(_open_deck_inspector);

func setup(new_map_definition:MapDefinition, new_run_state:RunState)->bool:
	if new_map_definition == null or new_run_state == null:
		push_error("地图页面缺少地图定义或局内状态");
		return false;
	if new_run_state.definition.map_definition != new_map_definition:
		push_error("局内状态与需要显示的地图不一致");
		return false;
	map_definition = new_map_definition;
	run_state = new_run_state;
	refresh_map();
	return true;

func refresh_map()->void:
	if map_definition == null or run_state == null:
		return;
	_clear_dynamic_content();
	_selection_reported = false;
	_refresh_run_info();
	_create_node_views();
	_layout_map();
	_refresh_inspector_interactions();

func _clear_dynamic_content()->void:
	for layer:Control in [connection_layer, node_layer, annotation_layer]:
		for child in layer.get_children():
			layer.remove_child(child);
			child.queue_free();
	_node_views.clear();

func _refresh_run_info()->void:
	health_label.text = "生命：%d / %d" % [run_state.current_health, run_state.max_health];
	deck_label.text = "牌组：%d张" % run_state.owned_cards.size();
	collection_button.text = "藏品";
	collection_button.icon = null;
	collection_button.tooltip_text = "查看本局藏品";
	if run_state.selected_collection != null:
		collection_button.text = "藏品：%s" % run_state.selected_collection.display_name;
		collection_button.icon = run_state.selected_collection.icon;
		collection_button.tooltip_text = run_state.selected_collection.description;
	if not map_definition.is_branch_map:
		route_hint.text = "选择下一处可进入的地图节点";
		return;

func _route_name(route_id:String)->String:
	match route_id:
		"a": return "上方";
		"b": return "中间";
		"c": return "下方";
	return route_id;

func _create_node_views()->void:
	for node_definition in map_definition.nodes:
		var view:MapNodeView = MAP_NODE_VIEW_SCENE.instantiate();
		node_layer.add_child(view);
		view.setup(node_definition, _get_node_visual_state(node_definition.node_id));
		view.set_display_details(
			run_state.get_node_display_name(node_definition.node_id),
			_node_type_name(node_definition),
			not node_definition.route_id.is_empty() and node_definition.route_id == run_state.selected_route_id,
			_is_excluded_route(node_definition),
			_node_tooltip(node_definition)
		);
		view.pressed.connect(_on_map_node_pressed);
		view.set_interactable(run_state.can_enter_node(node_definition.node_id) and not _has_inspector());
		_node_views[node_definition.node_id] = view;

func _node_type_name(node_definition:MapNodeDefinition)->String:
	match run_state.get_node_type(node_definition.node_id):
		MapNodeDefinition.NodeType.START: return "出发";
		MapNodeDefinition.NodeType.BATTLE: return "普通战斗";
		MapNodeDefinition.NodeType.REST: return "休整";
		MapNodeDefinition.NodeType.UNEXPECTED: return "不期而遇";
		MapNodeDefinition.NodeType.BOSS: return "最终 Boss";
	return "地图节点";

func _node_tooltip(node_definition:MapNodeDefinition)->String:
	var text:String = run_state.get_node_display_name(node_definition.node_id);
	var encounter:EncounterDefinition = run_state.get_node_encounter(node_definition.node_id);
	if encounter != null:
		text += "\n生命：%d" % encounter.enemy_definition.max_health;
	if run_state.get_node_type(node_definition.node_id) == MapNodeDefinition.NodeType.REST:
		text += "\n恢复 %d 点生命，最多恢复至当前生命上限" % node_definition.heal_amount;
	var content:UnexpectedEncounterDefinition = run_state.get_unexpected_encounter(node_definition.node_id);
	if content != null:
		text += "\n进入后作出选择，确认后继续旅程";
	if _is_excluded_route(node_definition):
		text += "\n本局已选择另一条路线";
	return text;

func _get_node_visual_state(node_id:String)->MapNodeView.NodeState:
	if run_state.completed_node_ids.has(node_id):
		return MapNodeView.NodeState.COMPLETED;
	if run_state.current_node_id == node_id:
		return MapNodeView.NodeState.CURRENT;
	if run_state.can_enter_node(node_id):
		return MapNodeView.NodeState.AVAILABLE;
	return MapNodeView.NodeState.LOCKED;

func _is_excluded_route(node_definition:MapNodeDefinition)->bool:
	return (
		not run_state.selected_route_id.is_empty()
		and not node_definition.route_id.is_empty()
		and node_definition.route_id != run_state.selected_route_id
	);

## 节点坐标是设计画布上的中心；画布始终等比缩放到卷轴正文区域。
## 缩放仅移动现有组件和重画连线，保留按钮、点击防重与随机遭遇。
func _layout_map()->void:
	_layout_queued = false;
	if _node_views.is_empty() or size.x <= 0.0 or size.y <= 0.0:
		return;
	var usable_height:float = maxf(size.y - 114.0, 1.0);
	_layout_scale = minf(size.x * 0.76 / DESIGN_SIZE.x, usable_height / DESIGN_SIZE.y);
	_layout_origin = Vector2((size.x - DESIGN_SIZE.x * _layout_scale) * 0.5,
		63.0 + (usable_height - DESIGN_SIZE.y * _layout_scale) * 0.5);
	route_hint.offset_left = -size.x * 0.46;
	route_hint.offset_right = size.x * 0.46;
	route_hint.add_theme_font_size_override("font_size", clampi(roundi(size.x / 64.0), 12, 18));
	for node_definition in map_definition.nodes:
		var view:MapNodeView = _node_views[node_definition.node_id];
		view.size = NODE_SIZE;
		view.scale = Vector2.ONE * _layout_scale;
		view.position = _design_point(node_definition.map_position) - NODE_SIZE * _layout_scale * 0.5;
	_create_connection_lines();
	_create_annotations();

func _queue_layout()->void:
	if _layout_queued or not is_node_ready():
		return;
	_layout_queued = true;
	_layout_map.call_deferred();

func _design_point(point:Vector2)->Vector2:
	return _layout_origin + point * _layout_scale;

func _create_connection_lines()->void:
	for old_line in connection_layer.get_children():
		connection_layer.remove_child(old_line);
		old_line.queue_free();
	for source in map_definition.nodes:
		var source_view:MapNodeView = _node_views[source.node_id];
		for target_node_id in source.next_node_ids:
			var target_definition:MapNodeDefinition = map_definition.get_node_by_id(target_node_id);
			var target_view:MapNodeView = _node_views[target_node_id];
			var line:Line2D = Line2D.new();
			line.name = "connection_%s_to_%s" % [source.node_id, target_node_id];
			line.width = CONNECTION_WIDTH * _layout_scale;
			line.default_color = _connection_color(source, target_definition);
			line.antialiased = true;
			var direction:Vector2 = _get_node_view_center(target_view) - _get_node_view_center(source_view);
			line.add_point(_node_edge_point(source_view, direction));
			line.add_point(_node_edge_point(target_view, -direction));
			connection_layer.add_child(line);

func _connection_color(source:MapNodeDefinition, target:MapNodeDefinition)->Color:
	if _is_excluded_route(source) or _is_excluded_route(target):
		return EXCLUDED_CONNECTION_COLOR;
	if run_state.completed_node_ids.has(source.node_id):
		if run_state.completed_node_ids.has(target.node_id):
			return COMPLETED_CONNECTION_COLOR;
		if run_state.can_enter_node(target.node_id):
			return ACTIVE_CONNECTION_COLOR;
	if not run_state.selected_route_id.is_empty():
		if source.route_id == run_state.selected_route_id or target.route_id == run_state.selected_route_id:
			return ACTIVE_CONNECTION_COLOR;
	return CONNECTION_COLOR;

func _get_node_view_center(node_view:MapNodeView)->Vector2:
	return node_view.position + node_view.size * node_view.scale * 0.5;

func _node_edge_point(view:MapNodeView, direction:Vector2)->Vector2:
	var center:Vector2 = _get_node_view_center(view);
	if direction == Vector2.ZERO:
		return center;
	var half_size:Vector2 = view.size * view.scale * 0.5;
	var factor:float = minf(half_size.x / maxf(absf(direction.x), 0.001),
		half_size.y / maxf(absf(direction.y), 0.001));
	return center + direction * factor;

func _create_annotations()->void:
	for old_annotation in annotation_layer.get_children():
		annotation_layer.remove_child(old_annotation);
		old_annotation.queue_free();
	if not map_definition.is_branch_map:
		return;
	var captions:Array[String] = ["起点", "第一战", "第二战", "休整", "最终 Boss"];
	if map_definition.randomize_route_contents:
		captions = ["起点", "第一处", "第二处", "第三处", "最终 Boss"];
	for index in range(captions.size()):
		var label:Label = Label.new();
		label.text = captions[index];
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER;
		label.add_theme_font_size_override("font_size", 19);
		label.add_theme_color_override("font_color", Color(0.3, 0.2, 0.1));
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE;
		label.size = Vector2(145.0, 30.0);
		label.scale = Vector2.ONE * _layout_scale;
		label.position = _design_point(Vector2(110.0 + 200.0 * index, 64.0)) - Vector2(72.5, 0.0) * _layout_scale;
		annotation_layer.add_child(label);

func _on_map_node_pressed(node_id:String)->void:
	if _selection_reported or _has_inspector() or not is_inside_tree() or is_queued_for_deletion():
		return;
	if run_state == null:
		push_error("尚未绑定局内状态，无法报告地图节点选择");
		return;
	if not run_state.can_enter_node(node_id):
		push_error("玩家选择了当前不可进入的地图节点：%s" % node_id);
		return;
	_selection_reported = true;
	_refresh_inspector_interactions();
	node_selected.emit(node_id);

## 查看窗口共用一组锁定条件；数量刷新和地图重建也不能恢复背景输入。
func _has_inspector()->bool:
	return is_instance_valid(_collection_inspector) or is_instance_valid(_card_inspector) or (_overlay_host != null and _overlay_host.has_blocking_modal());

func _can_open_inspector()->bool:
	return run_state != null and not _selection_reported and not _has_inspector() and is_inside_tree() and not is_queued_for_deletion();

func _refresh_inspector_interactions()->void:
	var blocked:bool = run_state == null or _selection_reported or _has_inspector() or not is_inside_tree() or is_queued_for_deletion();
	collection_button.disabled = blocked;
	deck_button.disabled = blocked;
	for node_id:String in _node_views:
		var view:MapNodeView = _node_views[node_id];
		view.set_interactable(not blocked and run_state.can_enter_node(node_id));

## 整局牌组按拥有张数展示，同名卡的多份资源引用保留；不读取战斗实例。
func _open_deck_inspector()->void:
	if not _can_open_inspector():
		return;
	_card_inspector = CARD_INSPECTOR_SCENE.instantiate();
	if _overlay_host != null:
		_overlay_host.attach_page_modal(_card_inspector, self);
	else:
		add_child(_card_inspector);
	var definitions:Array[CardDefinition] = run_state.owned_cards.duplicate();
	if not _card_inspector.setup_definitions(definitions, "牌组"):
		_card_inspector.get_parent().remove_child(_card_inspector);
		_card_inspector.queue_free();
		_card_inspector = null;
		_refresh_inspector_interactions();
		push_error("本局牌组查看窗口设置失败");
		return;
	_card_inspector.closed.connect(_on_card_inspector_closed.bind(_card_inspector));
	_refresh_inspector_interactions();

func _on_card_inspector_closed(source:CardInspector = null)->void:
	if source != null and source != _card_inspector:
		return;
	_card_inspector = null;
	_refresh_inspector_interactions();

func _open_collection_inspector()->void:
	if not _can_open_inspector():
		return;
	_collection_inspector = COLLECTION_INSPECTOR_SCENE.instantiate();
	if _overlay_host != null:
		_overlay_host.attach_page_modal(_collection_inspector, self);
	else:
		add_child(_collection_inspector);
	_collection_inspector.setup(run_state.selected_collection);
	_collection_inspector.closed.connect(_on_collection_inspector_closed.bind(_collection_inspector));
	_refresh_inspector_interactions();

func _on_collection_inspector_closed(source:CollectionInspector = null)->void:
	if source != null and source != _collection_inspector:
		return;
	_collection_inspector = null;
	_refresh_inspector_interactions();

func configure_overlay(host:OverlayHost)->void:
	_overlay_host = host
	if host != null and not host.blocking_changed.is_connected(_on_overlay_blocking_changed):
		host.blocking_changed.connect(_on_overlay_blocking_changed)

func _on_overlay_blocking_changed(_blocked:bool)->void:
	if is_inside_tree() and not is_queued_for_deletion():
		_refresh_inspector_interactions()
