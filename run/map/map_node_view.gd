## 一项可复用地图节点。仅显示状态和报告点击，不改变地图或局内数据。
class_name MapNodeView
extends Control


enum NodeState { LOCKED, AVAILABLE, COMPLETED, CURRENT }

signal pressed(node_id:String);

var node_definition:MapNodeDefinition;
var current_state:NodeState = NodeState.LOCKED;
var _press_reported:bool = false;
var _display_name:String = "";
var _type_label:String = "";
var _route_selected:bool = false;
var _route_excluded:bool = false;

@onready var node_button:Button = $node_button;

func _ready()->void:
	node_button.pressed.connect(_on_node_button_pressed);
	node_button.disabled = true;

func setup(new_node_definition:MapNodeDefinition, new_state:NodeState)->void:
	node_definition = new_node_definition;
	current_state = new_state;
	_press_reported = false;
	_display_name = node_definition.display_name;
	_type_label = "地图节点";
	_route_selected = false;
	_route_excluded = false;
	_refresh_visual();
	set_interactable(false);

## 战斗名称来自同一局的已抽取遭遇，非静态模板或页面重新抽取。
func set_display_details(display_name:String, type_label:String, route_selected:bool,
		route_excluded:bool, tooltip:String)->void:
	_display_name = display_name;
	_type_label = type_label;
	_route_selected = route_selected;
	_route_excluded = route_excluded;
	node_button.tooltip_text = tooltip;
	_refresh_visual();

func set_interactable(enabled:bool)->void:
	node_button.disabled = not (enabled and node_definition != null
		and current_state == NodeState.AVAILABLE and not _press_reported);

func _refresh_visual()->void:
	var state_text:String = "尚未解锁";
	var border_color:Color = Color(0.53, 0.44, 0.28, 0.75);
	var background:Color = Color(0.18, 0.15, 0.1, 0.82);
	var font_color:Color = Color(0.84, 0.79, 0.67);
	match current_state:
		NodeState.AVAILABLE:
			state_text = "可进入";
			border_color = Color(1.0, 0.78, 0.33);
			background = Color(0.27, 0.2, 0.08, 0.94);
			font_color = Color(1.0, 0.94, 0.74);
		NodeState.COMPLETED:
			state_text = "已完成";
			border_color = Color(0.45, 0.74, 0.5);
			background = Color(0.13, 0.22, 0.13, 0.88);
			font_color = Color(0.85, 0.97, 0.83);
		NodeState.CURRENT:
			state_text = "当前位置";
			border_color = Color(1.0, 0.78, 0.33);
			background = Color(0.27, 0.2, 0.08, 0.94);
	if _route_excluded:
		state_text = "未选路线";
		border_color = Color(0.4, 0.36, 0.28, 0.45);
		background = Color(0.19, 0.17, 0.12, 0.55);
		font_color = Color(0.61, 0.56, 0.47);
	elif _route_selected and current_state == NodeState.LOCKED:
		border_color = Color(0.79, 0.61, 0.28, 0.9);
		font_color = Color(0.93, 0.86, 0.68);
	node_button.text = "%s\n%s\n[%s]" % [_type_label, _display_name, state_text];
	node_button.add_theme_color_override("font_color", font_color);
	node_button.add_theme_color_override("font_disabled_color", font_color);
	node_button.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.81));
	node_button.add_theme_color_override("font_pressed_color", Color(1.0, 0.97, 0.81));
	var style:StyleBoxFlat = _make_style(background, border_color, 2);
	node_button.add_theme_stylebox_override("normal", style);
	node_button.add_theme_stylebox_override("disabled", style);
	node_button.add_theme_stylebox_override("hover", _make_style(background.lightened(0.1), border_color.lightened(0.12), 3));
	node_button.add_theme_stylebox_override("pressed", _make_style(background.darkened(0.1), border_color, 3));
	node_button.add_theme_stylebox_override("focus", _make_style(Color(0.0, 0.0, 0.0, 0.0), Color(1.0, 0.89, 0.52), 3));

func _make_style(background:Color, border_color:Color, border_width:int)->StyleBoxFlat:
	var style:StyleBoxFlat = StyleBoxFlat.new();
	style.bg_color = background;
	style.border_color = border_color;
	style.set_border_width_all(border_width);
	style.set_corner_radius_all(7);
	style.content_margin_left = 5.0;
	style.content_margin_right = 5.0;
	style.content_margin_top = 4.0;
	style.content_margin_bottom = 4.0;
	return style;

func _on_node_button_pressed()->void:
	if node_definition == null:
		push_error("尚未绑定地图节点定义，无法报告节点点击");
		return;
	if node_button.disabled or _press_reported:
		return;
	_press_reported = true;
	node_button.disabled = true;
	pressed.emit(node_definition.node_id);
