## 显示一组静态卡牌奖励选项，并报告玩家最终选择的奖励卡。
##
## RunSession从CharacterDefinition.reward_card_pool中无放回抽取并保存候选卡牌，流程层通过
## setup传入本页面。RewardView为每个CardDefinition创建一个CardChoiceView，
## 管理整组卡牌的交互状态，并把首次有效选择继续报告给流程控制器。
##
## RewardView属于视图与输入层。它不随机抽取奖励、不创建CardInstance，
## 不调用RunState.add_card，也不修改任何CardDefinition静态资源。
class_name RewardView
extends Control


## 每个奖励候选使用的可复用卡牌界面场景模板。
##
## refresh_options会为reward_options中的每个CardDefinition分别实例化一个组件。
const REWARD_CARD_VIEW_SCENE:PackedScene = preload(
	"res://ui/cards/card_choice_view.tscn"
)


## 玩家首次选择当前页面中的一张有效奖励卡时发出。
##
## card_definition是被选择的只读静态卡牌定义。该信号只报告玩家意图，
## GameFlowController收到后交给RunSession校验候选与步骤并提交真实奖励。
signal reward_selected(card_definition:CardDefinition)
signal reward_skipped;


## 当前页面正在展示的全部静态奖励候选。
##
## setup会复制传入数组的结构；其中每个CardDefinition仍是原来的只读资源引用。
## 默认冒险传入三张不同卡牌，但页面本身不写死数量，以支持其他奖励规则复用。
var reward_options:Array[CardDefinition] = []


## 当前页面动态创建的全部CardChoiceView组件。
##
## 数组只用于统一禁用和清理界面，不属于真实奖励数据，也不能代替reward_options。
var _reward_card_views:Array[CardChoiceView] = []


## 当前这次setup之后是否已经向外报告过奖励选择。
##
## 单张CardChoiceView会阻止自身重复点击；该页面级标记进一步阻止玩家快速点击
## 两张不同卡牌，导致同一次奖励流程发出多个reward_selected信号。
var _selection_reported:bool = false
var _view_generation:int = 0;

@onready var skip_button:Button = $center_container/main_layout/skip_button;

func _ready()->void:
	skip_button.disabled = true;
	skip_button.pressed.connect(_on_skip_pressed);


## 动态CardChoiceView组件的横向排列容器。
##
## 场景中必须存在center_container/main_layout/options_container路径。
@onready var options_container:HBoxContainer = (
	$center_container/main_layout/options_container
)


## 绑定候选列表；配置入口负责卡牌内容，这里只确认本页候选非空且不重复。
func setup(new_options:Array[CardDefinition])->bool:
	if new_options.is_empty():
		push_error("奖励候选数组为空");
		return false;
	var card_ids:Dictionary = {};
	for card in new_options:
		if card == null or card_ids.has(card.card_id):
			push_error("奖励候选包含空卡牌或重复卡牌");
			return false;
		card_ids[card.card_id] = true;
	reward_options = new_options.duplicate();
	_selection_reported = false;
	skip_button.disabled = false;
	refresh_options();
	return true;


## 重建已绑定的候选卡界面。
func refresh_options()->void:
	_view_generation += 1;
	_clear_reward_card_views();
	for card_definition in reward_options:
		_reward_card_views.append(_create_reward_card_view(card_definition));


## 候选视图由本页面创建并统一释放。
func _clear_reward_card_views()->void:
	for reward_card_view in _reward_card_views:
		options_container.remove_child(reward_card_view);
		reward_card_view.queue_free();
	_reward_card_views.clear();


## 实例化共用的候选卡组件，并连接选择信号。
func _create_reward_card_view(card_definition:CardDefinition)->CardChoiceView:
	var view:CardChoiceView = REWARD_CARD_VIEW_SCENE.instantiate();
	view.name = "reward_card_%s" % card_definition.card_id;
	options_container.add_child(view);
	view.setup(card_definition);
	view.card_selected.connect(_on_card_selected.bind(_view_generation));
	view.set_interactable(not _selection_reported);
	return view;


## 本轮只能提交一次，且只能选择当前候选中的卡牌。
func _on_card_selected(card_definition:CardDefinition, generation:int = -1)->void:
	if _selection_reported or not reward_options.has(card_definition) or not is_inside_tree() or is_queued_for_deletion() or (generation >= 0 and generation != _view_generation):
		return;
	_lock_selection();
	reward_selected.emit(card_definition);


func _on_skip_pressed()->void:
	if _selection_reported or reward_options.is_empty() or not is_inside_tree() or is_queued_for_deletion():
		return;
	_lock_selection();
	reward_skipped.emit();


func _lock_selection()->void:
	_selection_reported = true;
	skip_button.disabled = true;
	for view in _reward_card_views:
		view.set_interactable(false);
