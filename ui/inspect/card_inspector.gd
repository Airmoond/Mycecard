## 只读卡牌浏览窗口；只排列展示副本，不改变牌组、牌堆或实例状态。
class_name CardInspector
extends Control

signal closed;

const CARD_FACE_SCENE:PackedScene = preload("res://cards/card_face.tscn");
const TILE_WIDTH:float = 210.0;
const FACE_WIDTH:float = 188.0;
const COLUMN_SEPARATION:float = 16.0;

var displayed_definitions:Array[CardDefinition] = [];
var displayed_instances:Array[CardInstance] = [];
var card_faces:Array[CardFace] = [];
var detail_labels:Array[Label] = [];
var _title:String = "卡牌";
var _instance_mode:bool = false;
var _closing:bool = false;

@onready var title_label:Label = %title_label;
@onready var empty_label:Label = %empty_label;
@onready var card_grid:GridContainer = %card_grid;
@onready var scroll_container:ScrollContainer = %scroll_container;
@onready var close_button:Button = %close_button;

func _ready()->void:
	close_button.pressed.connect(close);
	scroll_container.resized.connect(_update_columns);
	_rebuild_cards();
	_focus_close_button.call_deferred();

func _focus_close_button()->void:
	if _closing or not is_inside_tree() or is_queued_for_deletion():
		return;
	if is_instance_valid(close_button) and close_button.is_inside_tree() and not close_button.is_queued_for_deletion():
		close_button.grab_focus();

## title 传入“牌组”等名称，窗口自行追加实际张数。
func setup_definitions(cards:Array[CardDefinition], title:String)->bool:
	if _closing or title.strip_edges().is_empty():
		return false;
	for definition in cards:
		if definition == null or definition.is_invalid():
			return false;
	var indices:Array[int] = _definition_indices(cards);
	var definitions:Array[CardDefinition] = [];
	for index in indices:
		definitions.append(cards[index]);
	var instances:Array[CardInstance] = [];
	definitions.make_read_only();
	instances.make_read_only();
	displayed_definitions = definitions;
	displayed_instances = instances;
	_title = title.strip_edges();
	_instance_mode = false;
	if is_node_ready():
		_rebuild_cards();
	return true;

## 费用与武器信息取自每个真实实例；同名牌仍分别显示。
func setup_instances(cards:Array[CardInstance], title:String)->bool:
	if _closing or title.strip_edges().is_empty():
		return false;
	for instance in cards:
		if instance == null or instance.is_invalid_instance():
			return false;
		if instance.definition.card_type == CardDefinition.CardType.WEAPON and instance.weapon == null:
			return false;
	var indices:Array[int] = _instance_indices(cards);
	var definitions:Array[CardDefinition] = [];
	var instances:Array[CardInstance] = [];
	for index in indices:
		definitions.append(cards[index].definition);
		instances.append(cards[index]);
	definitions.make_read_only();
	instances.make_read_only();
	displayed_definitions = definitions;
	displayed_instances = instances;
	_title = title.strip_edges();
	_instance_mode = true;
	if is_node_ready():
		_rebuild_cards();
	return true;

## 按名称、稳定卡牌 ID、原下标排序，只排序独立的下标列表。
func _definition_indices(cards:Array[CardDefinition])->Array[int]:
	var indices:Array[int] = [];
	for index in range(cards.size()):
		indices.append(index);
	indices.sort_custom(func(left:int, right:int)->bool:
		var left_definition:CardDefinition = cards[left];
		var right_definition:CardDefinition = cards[right];
		if left_definition.card_name != right_definition.card_name:
			return left_definition.card_name < right_definition.card_name;
		if left_definition.card_id != right_definition.card_id:
			return left_definition.card_id < right_definition.card_id;
		return left < right;
	);
	return indices;

## 实例按可见状态与对象稳定 ID 排序，与来源牌堆的排列无关。
## 同名牌的临时费用或武器强化不能泄露它们的相对抽取顺序。
func _instance_indices(cards:Array[CardInstance])->Array[int]:
	var indices:Array[int] = [];
	for index in range(cards.size()):
		indices.append(index);
	indices.sort_custom(func(left_index:int, right_index:int)->bool:
		var left:CardInstance = cards[left_index];
		var right:CardInstance = cards[right_index];
		if left.definition.card_name != right.definition.card_name:
			return left.definition.card_name < right.definition.card_name;
		if left.definition.card_id != right.definition.card_id:
			return left.definition.card_id < right.definition.card_id;
		if left.current_energy_cost != right.current_energy_cost:
			return left.current_energy_cost < right.current_energy_cost;
		if left.weapon == null and right.weapon != null:
			return true;
		if left.weapon != null and right.weapon == null:
			return false;
		if left.weapon != null and right.weapon != null:
			if left.weapon.current_attack != right.weapon.current_attack:
				return left.weapon.current_attack < right.weapon.current_attack;
			if left.weapon.current_durability != right.weapon.current_durability:
				return left.weapon.current_durability < right.weapon.current_durability;
			if left.weapon.max_durability != right.weapon.max_durability:
				return left.weapon.max_durability < right.weapon.max_durability;
		return left.get_instance_id() < right.get_instance_id();
	);
	return indices;

func _rebuild_cards()->void:
	for child in card_grid.get_children():
		card_grid.remove_child(child);
		child.queue_free();
	card_faces.clear();
	detail_labels.clear();
	title_label.text = "%s：%d张" % [_title, displayed_definitions.size()];
	empty_label.visible = displayed_definitions.is_empty();
	scroll_container.visible = not displayed_definitions.is_empty();
	scroll_container.scroll_vertical = 0;
	for index in range(displayed_definitions.size()):
		_add_card(index);
	_update_columns();

func _add_card(index:int)->void:
	var definition:CardDefinition = displayed_definitions[index];
	var energy_cost:int = definition.base_energy_cost;
	var description:String = definition.format_description();
	if _instance_mode:
		var instance:CardInstance = displayed_instances[index];
		energy_cost = instance.current_energy_cost;
		if instance.weapon != null:
			description += _weapon_description(instance.weapon, definition.weapon_definition);
	var full_text:String = "%s\n费用：%d\n%s" % [definition.card_name, energy_cost, description];
	var panel:PanelContainer = PanelContainer.new();
	panel.custom_minimum_size.x = TILE_WIDTH;
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER;
	panel.size_flags_vertical = Control.SIZE_FILL;
	panel.tooltip_text = full_text;
	var style:StyleBoxFlat = StyleBoxFlat.new();
	style.bg_color = Color(0.13, 0.085, 0.045, 0.96);
	style.border_color = Color(0.60, 0.44, 0.22, 0.8);
	style.set_border_width_all(1);
	style.set_corner_radius_all(6);
	style.content_margin_left = 10;
	style.content_margin_top = 10;
	style.content_margin_right = 10;
	style.content_margin_bottom = 12;
	panel.add_theme_stylebox_override("panel", style);
	card_grid.add_child(panel);
	var layout:VBoxContainer = VBoxContainer.new();
	layout.add_theme_constant_override("separation", 8);
	panel.add_child(layout);
	var full_name:Label = Label.new();
	full_name.text = definition.card_name;
	full_name.add_theme_font_size_override("font_size", 19);
	full_name.add_theme_color_override("font_color", Color(1, 0.89, 0.7));
	full_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER;
	full_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART;
	full_name.mouse_filter = Control.MOUSE_FILTER_IGNORE;
	layout.add_child(full_name);
	var face_center:CenterContainer = CenterContainer.new();
	face_center.mouse_filter = Control.MOUSE_FILTER_IGNORE;
	layout.add_child(face_center);
	var face:CardFace = CARD_FACE_SCENE.instantiate() as CardFace;
	_configure_face(face);
	face_center.add_child(face);
	face.show_card(definition, energy_cost);
	face.set_description(description);
	face.tooltip_text = full_text;
	card_faces.append(face);
	var details:Label = Label.new();
	details.text = description;
	details.custom_minimum_size.x = FACE_WIDTH;
	details.add_theme_font_size_override("font_size", 16);
	details.add_theme_color_override("font_color", Color(0.94, 0.93, 0.9));
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART;
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE;
	layout.add_child(details);
	detail_labels.append(details);

## 只放大该窗口中的卡面实例，不改共用场景或其他卡面。
func _configure_face(face:CardFace)->void:
	face.set_display_size(Vector2(FACE_WIDTH, CardFace.BASE_SIZE.y * FACE_WIDTH / CardFace.BASE_SIZE.x));

func _weapon_description(weapon:WeaponInstance, definition:WeaponDefinition)->String:
	var attack_bonus:int = weapon.current_attack - definition.base_attack;
	var durability_bonus:int = weapon.max_durability - definition.base_max_durability;
	return "\n当前武器：攻击%d，耐久%d/%d。\n本场强化：攻击%+d，最大耐久%+d。" % [
		weapon.current_attack, weapon.current_durability, weapon.max_durability,
		attack_bonus, durability_bonus
	];

func _update_columns()->void:
	if not is_node_ready() or _closing:
		return;
	var available_width:float = maxf(scroll_container.size.x - 18.0, TILE_WIDTH);
	var columns:int = int(floor((available_width + COLUMN_SEPARATION) / (TILE_WIDTH + COLUMN_SEPARATION)));
	card_grid.columns = clampi(columns, 1, 6);

func _unhandled_key_input(event:InputEvent)->void:
	if _closing:
		return;
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled();
		close();

func close()->void:
	if _closing:
		return;
	_closing = true;
	hide();
	set_process_unhandled_key_input(false);
	closed.emit();
	queue_free();
