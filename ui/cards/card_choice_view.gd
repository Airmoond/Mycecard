## 显示一张静态奖励卡牌，并报告玩家对它的选择。
##
## CardChoiceView直接读取CardDefinition中的名称、基础费用、原画和描述。
## 它属于视图与输入层，不创建CardInstance、不执行卡牌效果，也不把卡牌加入RunState。
class_name CardChoiceView
extends Button


## 奖励卡允许玩家选择时使用的正常显示颜色。
##
## Color.WHITE不会改变根Button及其名称、费用、原画和描述子节点的原始颜色。
const INTERACTABLE_MODULATE:Color = Color.WHITE


## 奖励卡当前不可选择时使用的灰暗半透明颜色。
##
## 该颜色通过根节点的modulate同时影响卡牌背景及全部显示子节点，
## 让玩家能够直观看出卡牌现在不能继续选择。
const DISABLED_MODULATE:Color = Color(0.65,0.65,0.65,0.8)


## 玩家首次点击当前已经绑定且允许交互的奖励卡时发出。
##
## card_definition是当前组件显示的只读卡牌定义；
## 该信号只报告玩家选择，不代表奖励已经加入本局牌组。
signal card_selected(card_definition:CardDefinition)


## 当前组件正在显示的静态卡牌定义。
##
## 通过setup完成绑定。该资源只能读取，不能在奖励页面中修改其任何字段。
var card_definition:CardDefinition


## 当前这次setup之后是否已经报告过选择。
##
## 防止页面切换完成前快速重复点击同一张奖励卡。
var _selection_reported:bool = false
var display_size:Vector2 = CardFace.BASE_SIZE


## 与手牌共用卡面；此处只处理静态定义与选牌输入。
@onready var card_face:CardFace = $card_face


## 连接根Button的点击信号，并保持组件初始不可交互。
func _ready()->void:
	set_display_size(display_size);
	pressed.connect(_on_pressed);#把根Button的点击统一交给当前组件的私有处理方法
	set_interactable(false);#绑定CardDefinition前保持禁用，并同步显示灰暗外观

## 仅调整本次展示的卡面和占位；不会改变候选或选择状态。
func set_display_size(value:Vector2)->void:
	display_size = value
	custom_minimum_size = value
	size = value
	if is_node_ready():
		card_face.set_display_size(value)


## 显示已经通过配置入口验证的候选卡；进入场景树后调用。
func setup(new_card_definition:CardDefinition)->void:
	card_definition = new_card_definition;
	_selection_reported = false;
	_refresh_visual();
	set_interactable(false);


## 根据外层奖励页面的决定设置当前卡牌是否允许选择。
##
## 只有enabled为true、组件已经绑定CardDefinition，并且本次setup之后尚未报告过
## 选择时才会启用根Button；其他情况统一禁用。方法还会同步更新根节点的modulate，
## 使费用、名称、原画和描述与交互状态保持一致。它不修改CardDefinition，
## 也不代表玩家已经获得这张卡牌。
func set_interactable(enabled:bool)->void:
	var can_interact:bool = (
		enabled
		and card_definition != null
		and not _selection_reported
	);#外层授权、有效绑定和本轮尚未选择必须同时满足
	disabled = not can_interact;#Button使用disabled表达是否拒绝玩家输入和采用哪个主题状态
	modulate = (
		INTERACTABLE_MODULATE
		if can_interact
		else DISABLED_MODULATE
	);#通过根节点颜色让背景、文字和原画同步呈现正常或灰暗状态


## 候选卡始终显示基础费用和静态说明。
func _refresh_visual()->void:
	card_face.show_card(card_definition, card_definition.base_energy_cost);
	tooltip_text = card_face.tooltip_text;


## 接收根Button的首次有效点击并报告选择。
##
## 尚未绑定卡牌时推送错误；按钮不可交互或本次setup已经报告过选择时忽略输入。
## 首次有效点击会先保存防重复状态并禁用自身，再发出card_selected信号。
## 该方法只报告玩家意图，不调用RunState.add_card，也不修改静态卡牌资源。
func _on_pressed()->void:
	if card_definition == null:#空绑定无法提供可信的奖励卡身份
		push_error("尚未绑定奖励卡牌定义，无法报告奖励卡选择");#报告组件未完成setup
		return;#不能发出携带空CardDefinition的选择信号
	if disabled:#外层奖励页面当前没有开放这张卡的选择权限
		return;#禁用状态下忽略输入，不报告玩家选择
	if _selection_reported:#页面切换完成前可能出现快速连续输入
		return;#同一次setup周期最多报告一次选择

	_selection_reported = true;#先提交本地防重复状态，阻止当前调用链再次选择
	set_interactable(false);#通过统一入口立即禁用按钮，并同步刷新整张卡牌的灰暗外观
	card_selected.emit(card_definition);#只报告静态定义，由流程层决定是否加入RunState
