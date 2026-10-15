## 藏品候选为本局已经抽取的只读资源；本页只提交一次选择意图。
class_name CollectionChoiceView
extends Control

signal collection_selected(collection:CollectionDefinition);
signal back_requested;

var collection_options:Array[CollectionDefinition] = [];
var choice_buttons:Array[Button] = [];
var _selection_reported:bool = false;
var _setup_generation:int = 0;

@onready var options_container:HBoxContainer = %options_container;
@onready var back_button:Button = %back_button;

func _ready()->void:
	back_button.pressed.connect(_on_back_pressed);

func setup(options:Array[CollectionDefinition])->bool:
	if options.size() != 3:
		push_error("开局藏品页面需要三个不同的候选");
		return false;
	var collection_ids:Dictionary = {};
	for collection in options:
		if collection == null or collection.collection_id.is_empty() or collection_ids.has(collection.collection_id):
			push_error("藏品候选包含空藏品或重复藏品");
			return false;
		collection_ids[collection.collection_id] = true;
	_setup_generation += 1;
	_selection_reported = false;
	collection_options = options.duplicate();
	back_button.disabled = false;
	for child in options_container.get_children():
		options_container.remove_child(child);
		child.queue_free();
	choice_buttons.clear();
	for collection in collection_options:
		_create_option(collection, _setup_generation);
	return true;

func _create_option(collection:CollectionDefinition, generation:int)->void:
	var panel:PanelContainer = PanelContainer.new();
	panel.name = "collection_%s" % collection.collection_id;
	panel.custom_minimum_size = Vector2(270.0, 334.0);
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL;
	var style:StyleBoxFlat = StyleBoxFlat.new();
	style.bg_color = Color(0.16, 0.105, 0.058, 0.97);
	style.border_color = Color(0.64, 0.5, 0.27);
	style.set_border_width_all(2);
	style.set_corner_radius_all(10);
	style.content_margin_left = 18.0;
	style.content_margin_right = 18.0;
	style.content_margin_top = 20.0;
	style.content_margin_bottom = 18.0;
	panel.add_theme_stylebox_override("panel", style);
	options_container.add_child(panel);
	var layout:VBoxContainer = VBoxContainer.new();
	layout.add_theme_constant_override("separation", 12);
	panel.add_child(layout);
	var icon_view:TextureRect = TextureRect.new();
	icon_view.name = "icon";
	icon_view.custom_minimum_size = Vector2(0.0, 88.0);
	icon_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE;
	icon_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED;
	icon_view.texture = collection.icon;
	layout.add_child(icon_view);
	var name_label:Label = Label.new();
	name_label.name = "collection_name";
	name_label.text = collection.display_name;
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER;
	name_label.add_theme_font_size_override("font_size", 25);
	name_label.add_theme_color_override("font_color", Color(0.99, 0.85, 0.58));
	layout.add_child(name_label);
	var description_label:Label = Label.new();
	description_label.name = "description";
	description_label.text = collection.description;
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART;
	description_label.custom_minimum_size = Vector2(0.0, 87.0);
	description_label.size_flags_vertical = Control.SIZE_EXPAND_FILL;
	description_label.add_theme_font_size_override("font_size", 19);
	description_label.add_theme_color_override("font_color", Color(0.94, 0.91, 0.84));
	layout.add_child(description_label);
	var button:Button = Button.new();
	button.name = "choose_button";
	button.text = "选择%s" % collection.display_name;
	button.custom_minimum_size = Vector2(0.0, 44.0);
	button.add_theme_font_size_override("font_size", 19);
	button.pressed.connect(_on_collection_selected.bind(collection, generation));
	layout.add_child(button);
	choice_buttons.append(button);

func _on_collection_selected(collection:CollectionDefinition, generation:int)->void:
	if _selection_reported or generation != _setup_generation or not is_inside_tree() or is_queued_for_deletion():
		return;
	if not collection_options.has(collection):
		return;
	_selection_reported = true;
	_disable_buttons();
	collection_selected.emit(collection);

func _on_back_pressed()->void:
	if _selection_reported or not is_inside_tree() or is_queued_for_deletion():
		return;
	_selection_reported = true;
	_disable_buttons();
	back_requested.emit();

func _disable_buttons()->void:
	for button in choice_buttons:
		button.disabled = true;
	back_button.disabled = true;
