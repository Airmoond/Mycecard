## 只展示本局内容与固定候选；确认结果交给流程层一次提交。
class_name UnexpectedEncounterView
extends Control

const CARD_SCENE:PackedScene = preload("res://ui/cards/card_choice_view.tscn");
# 每页一行完整卡面，让小窗口也能同时看到翻页和返回入口。
const PAGE_SIZE:int = 3;

signal option_selected(option_id:String, card:CardDefinition, deck_index:int);
signal continue_requested;

var run_state:RunState;
var option_buttons:Dictionary = {};
var card_views:Array[CardChoiceView] = [];
@onready var title_label:Label = %title_label;
@onready var story_label:Label = %story_label;
@onready var status_label:Label = %status_label;
@onready var content_container:VBoxContainer = %content_container;
@onready var artwork_view:TextureRect = %artwork_view;
@onready var _scroll:ScrollContainer = %scroll;
@onready var _layout:VBoxContainer = %layout;
@onready var _heading_label:Label = %heading_label;
@onready var _reading_panel:PanelContainer = %reading_panel;
@onready var _reading_row:HBoxContainer = %reading_row;
@onready var _illustration_frame:PanelContainer = %illustration_frame;
var _paper_style:StyleBoxFlat;
var _compact:bool = false;
var _submitted:bool = false;
var _generation:int = 0;
var _page_index:int = 0;
var _mode:String = "";
var _selection_kind:int = UnexpectedEncounterOptionDefinition.SelectionKind.NONE;
var _base_font_sizes:Dictionary = {};

func _ready()->void:
	_paper_style = _reading_panel.get_theme_stylebox("panel").duplicate();
	_reading_panel.add_theme_stylebox_override("panel", _paper_style);
	for label:Label in [_heading_label, title_label, story_label, status_label]:
		_base_font_sizes[label] = label.get_theme_font_size("font_size");
	resized.connect(_fit_layout);
	_fit_layout();

## 只缩放展示，不重建固定候选或改变页面提交代次。
func _fit_layout()->void:
	if _scroll == null:
		return;
	_compact = size.y < 680;
	_scroll.offset_left = 40;
	_scroll.offset_right = -40;
	_scroll.offset_top = 20 if _compact else 28;
	_scroll.offset_bottom = -20 if _compact else -28;
	_layout.add_theme_constant_override("separation", 10 if _compact else 14);
	content_container.add_theme_constant_override("separation", 10);
	_heading_label.add_theme_font_size_override("font_size", maxi(8, roundi(float(_base_font_sizes[_heading_label]) * (0.9 if _compact else 1.0))));
	title_label.add_theme_font_size_override("font_size", maxi(8, roundi(float(_base_font_sizes[title_label]) * (28.0 / 34.0 if _compact else 1.0))));
	story_label.add_theme_font_size_override("font_size", maxi(8, roundi(float(_base_font_sizes[story_label]) * (18.0 / 21.0 if _compact else 1.0))));
	status_label.add_theme_font_size_override("font_size", maxi(8, roundi(float(_base_font_sizes[status_label]) * (16.0 / 18.0 if _compact else 1.0))));
	_paper_style.content_margin_top = 8 if _compact else 12;
	_paper_style.content_margin_bottom = 8 if _compact else 12;
	_reading_row.add_theme_constant_override("separation", 18 if _compact else 24);
	_illustration_frame.custom_minimum_size = Vector2(280, 150) if _compact else Vector2(330, 180);
	for button:Button in option_buttons.values():
		_fit_button(button);
	_fit_cards();

func _fit_button(button:Button)->void:
	button.custom_minimum_size.y = 44 if _compact else 48;
	button.add_theme_font_size_override("font_size", 18 if _compact else 20);

func _fit_cards()->void:
	var width:float = 160.0 if _compact else 180.0;
	for view in card_views:
		view.set_display_size(Vector2(width, width * CardFace.BASE_SIZE.y / CardFace.BASE_SIZE.x));

func _set_reading_visible(value:bool)->void:
	_reading_panel.visible = value;
	_heading_label.visible = value;
	_scroll.scroll_vertical = 0;

func _label(value:String, font_size:int)->Label:
	var label:Label = Label.new();
	label.text = value;
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER;
	label.add_theme_font_size_override("font_size", font_size);
	return label;

func setup(state:RunState)->bool:
	if state == null or state.status not in [RunState.RunStatus.CHOOSING_UNEXPECTED, RunState.RunStatus.UNEXPECTED_RESULT]:
		return false;
	run_state = state;
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	if content == null:
		return false;
	title_label.text = content.display_name;
	story_label.text = content.story;
	artwork_view.texture = content.artwork;
	_illustration_frame.visible = content.artwork != null;
	status_label.text = "生命：%d / %d　　牌组：%d张" % [state.current_health, state.max_health, state.owned_cards.size()];
	_submitted = false;
	if state.status == RunState.RunStatus.UNEXPECTED_RESULT:
		_show_result();
	else:
		_show_options();
	return true;

func _clear_content()->void:
	_generation += 1;
	for child in content_container.get_children():
		content_container.remove_child(child);
		child.queue_free();
	option_buttons.clear();
	card_views.clear();

func _button(id:String, text:String, callback:Callable, enabled:bool = true, parent:Container = null)->void:
	var button:Button = Button.new();
	button.name = "option_%s" % id;
	button.text = text;
	_fit_button(button);
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL;
	button.disabled = not enabled;
	button.pressed.connect(callback);
	(content_container if parent == null else parent).add_child(button);
	option_buttons[id] = button;

func _show_options()->void:
	_clear_content();
	_set_reading_visible(true);
	_mode = "";
	_selection_kind = UnexpectedEncounterOptionDefinition.SelectionKind.NONE;
	for option:Dictionary in UnexpectedEncounterExecutor.get_option_view_data(run_state):
		var text:String = option.label;
		if not option.enabled and not option.disabled_reason.is_empty():
			text += "\n（%s）" % option.disabled_reason;
		_button(option.option_id, text, _on_option.bind(option.option_id, _generation), option.enabled);

func _on_option(id:String, generation:int)->void:
	if not _can_submit(generation):
		return;
	for option:Dictionary in UnexpectedEncounterExecutor.get_option_view_data(run_state):
		if option.option_id != id or not option.enabled:
			continue;
		_selection_kind = option.selection_kind;
		if _selection_kind != UnexpectedEncounterOptionDefinition.SelectionKind.NONE:
			_mode = id;
			_page_index = 0;
			_show_cards();
		else:
			_submit(id, null, -1, generation);
		return;

func _show_cards()->void:
	_clear_content();
	_set_reading_visible(false);
	var definitions:Array[CardDefinition] = UnexpectedEncounterExecutor.get_candidates(run_state, _mode);
	var instructions:Label = _label("选择一张要删除的卡牌" if _selection_kind == UnexpectedEncounterOptionDefinition.SelectionKind.DECK_CARD else "选择一张卡牌加入牌组", 22);
	content_container.add_child(instructions);
	var grid:GridContainer = GridContainer.new();
	grid.columns = 3;
	grid.add_theme_constant_override("h_separation", 20);
	grid.add_theme_constant_override("v_separation", 14);
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER;
	content_container.add_child(grid);
	for index in range(_page_index * PAGE_SIZE, mini((_page_index + 1) * PAGE_SIZE, definitions.size())):
		var view:CardChoiceView = CARD_SCENE.instantiate();
		grid.add_child(view);
		view.setup(definitions[index]);
		view.set_interactable(true);
		view.card_selected.connect(_on_card_selected.bind(index, _generation));
		card_views.append(view);
	if definitions.size() > PAGE_SIZE:
		content_container.add_child(_label("第%d / %d页" % [_page_index + 1, ceili(float(definitions.size()) / PAGE_SIZE)], 18));
		var navigation:HBoxContainer = HBoxContainer.new();
		navigation.add_theme_constant_override("separation", 16);
		content_container.add_child(navigation);
		_button("prev", "上一页", _change_page.bind(-1, _generation), _page_index > 0, navigation);
		_button("next", "下一页", _change_page.bind(1, _generation), (_page_index + 1) * PAGE_SIZE < definitions.size(), navigation);
	_button("back", "返回选项 · 尚未支付或改变牌组", _back_to_options.bind(_generation));
	_fit_cards();

func _change_page(delta:int, generation:int)->void:
	if not _can_submit(generation):
		return;
	var count:int = UnexpectedEncounterExecutor.get_candidates(run_state, _mode).size();
	var next:int = _page_index + delta;
	if next < 0 or next * PAGE_SIZE >= count:
		return;
	_page_index = next;
	_show_cards();

func _back_to_options(generation:int)->void:
	if _can_submit(generation):
		_show_options();

func _on_card_selected(card:CardDefinition, index:int, generation:int)->void:
	_submit(_mode, card, index if _selection_kind == UnexpectedEncounterOptionDefinition.SelectionKind.DECK_CARD else -1, generation);

func _can_submit(generation:int)->bool:
	return not _submitted and generation == _generation and is_inside_tree() and not is_queued_for_deletion();

func _submit(id:String, card:CardDefinition, index:int, generation:int)->void:
	if not _can_submit(generation):
		return;
	_submitted = true;
	_disable_controls();
	option_selected.emit(id, card, index);

func _disable_controls()->void:
	for button:Button in option_buttons.values():
		button.disabled = true;
	for view in card_views:
		view.set_interactable(false);

func _show_result()->void:
	_clear_content();
	_set_reading_visible(true);
	var result:Dictionary = UnexpectedEncounterExecutor.get_result_view_data(run_state);
	var summary:Label = _label(result.template.format(result), 25);
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART;
	content_container.add_child(summary);
	_button("continue", "继续旅程", _on_continue.bind(_generation));

func _on_continue(generation:int)->void:
	if not _can_submit(generation):
		return;
	_submitted = true;
	_disable_controls();
	continue_requested.emit();
