## 开局选牌视图：稳定分页展示全部候选，右侧展示逐张实际牌组。
## 只报告单次选择，由流程层加牌并切换下一轮。
class_name StartingDraftView
extends Control

const CARDS_PER_PAGE:int = 6;
const CARD_SCENE:PackedScene = preload("res://ui/cards/card_choice_view.tscn");
const DECK_ROW_SCENE:PackedScene = preload("res://run/draft/deck_card_row.tscn");
const RARITY_NAMES:Dictionary = {
	CardDefinition.CardRarity.LEGENDARY: "传说",
	CardDefinition.CardRarity.EPIC: "史诗",
	CardDefinition.CardRarity.RARE: "稀有"
};

signal card_selected(card:CardDefinition);
signal back_requested;

var candidates:Array[CardDefinition] = [];
var page_index:int = 0;
var _selection_reported:bool = false;
var _card_views:Array[CardChoiceView] = [];

@onready var title_label:Label = %title_label;
@onready var card_grid:GridContainer = %card_grid;
@onready var deck_list:VBoxContainer = %deck_list;
@onready var deck_title:Label = %deck_title;
@onready var page_label:Label = %page_label;
@onready var previous_button:Button = %previous_button;
@onready var next_button:Button = %next_button;
@onready var back_button:Button = %back_button;


func _ready()->void:
	previous_button.pressed.connect(_change_page.bind(-1));
	next_button.pressed.connect(_change_page.bind(1));
	back_button.pressed.connect(_on_back_pressed);
	resized.connect(_resize_cards);


## 调用方传入已验证的非空同稀有度候选；本页面每轮创建一次。
func setup(rarity:int, options:Array[CardDefinition], owned_cards:Array[CardDefinition])->void:
	candidates = options.duplicate();
	title_label.text = "选择1张%s卡牌，以组建你的初始牌组！" % RARITY_NAMES[rarity];
	deck_title.text = "当前牌组（%d张）" % owned_cards.size();
	for card in owned_cards:
		var row:Label = DECK_ROW_SCENE.instantiate();
		row.text = card.card_name;
		deck_list.add_child(row);
	_refresh_page();


func get_page_count()->int:
	return ceili(float(candidates.size()) / CARDS_PER_PAGE);


func _change_page(direction:int)->void:
	var next_index:int = page_index + direction;
	if _selection_reported or next_index < 0 or next_index >= get_page_count():
		return;
	page_index = next_index;
	_refresh_page();


## 移除旧组件时同时停止它们的输入；源候选数组顺序始终不变。
func _refresh_page()->void:
	for view in _card_views:
		view.set_interactable(false);
		card_grid.remove_child(view);
		view.queue_free();
	_card_views.clear();
	var first:int = page_index * CARDS_PER_PAGE;
	for index in range(first, mini(first + CARDS_PER_PAGE, candidates.size())):
		var view:CardChoiceView = CARD_SCENE.instantiate();
		card_grid.add_child(view);
		view.setup(candidates[index]);
		view.card_selected.connect(_on_card_selected);
		view.set_interactable(true);
		_card_views.append(view);
	page_label.text = "%d / %d" % [page_index + 1, get_page_count()];
	previous_button.disabled = page_index == 0;
	next_button.disabled = page_index == get_page_count() - 1;
	_resize_cards();
	_resize_cards.call_deferred();

## 六张卡维持两行三列，按窗口可用空间缩放，而非裁去下方文案。
func _resize_cards()->void:
	if not is_node_ready():
		return;
	var width_limit:float = maxf(132.0, (size.x - 400.0 - 48.0) / 3.0);
	var height_limit:float = maxf(185.0, (size.y - 226.0) / 2.0);
	var card_width:float = minf(CardFace.BASE_SIZE.x, minf(width_limit, height_limit * CardFace.BASE_SIZE.x / CardFace.BASE_SIZE.y));
	var card_size:Vector2 = Vector2(card_width, card_width * CardFace.BASE_SIZE.y / CardFace.BASE_SIZE.x);
	for view:CardChoiceView in _card_views:
		view.set_display_size(card_size);


func _on_card_selected(card:CardDefinition)->void:
	if _selection_reported:
		return;
	_selection_reported = true;
	for view in _card_views:
		view.set_interactable(false);
	previous_button.disabled = true;
	next_button.disabled = true;
	back_button.disabled = true;
	card_selected.emit(card);


func _on_back_pressed()->void:
	if _selection_reported:
		return;
	_selection_reported = true;
	back_requested.emit();
