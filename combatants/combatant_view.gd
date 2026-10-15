## 负责显示一名战斗角色的界面。
##
## 该脚本将CombatantState中的名称、生命和格挡等运行时数据同步到UI节点，
## 不负责修改角色状态、处理战斗规则或判断角色是否存活。
extends Control
class_name CombatantView

## 当前界面正在显示的角色运行时状态。
##
## 通过bind_combatant_state方法完成绑定；界面只读取该对象中的数据，
## 不应将UI节点中的显示值反向作为真实战斗数据。
var combatant_state:CombatantState;

## 用于显示角色原画的纹理节点。
@onready var artwork:TextureRect = $main_layout/artwork;

## 用于显示角色名称的文本节点。
@onready var name_label:Label = $main_layout/name_label;

## 用于直观显示角色当前生命与最大生命的进度条。
@onready var health_bar:ProgressBar = $main_layout/health_bar;

## 用于以文字形式显示角色当前生命与最大生命。
@onready var health_label:Label = $main_layout/health_label;

## 用于显示角色当前格挡值。
@onready var block_label:Label = $main_layout/block_label;

## 玩家与敌人共用的力量、虚弱与易伤显示。
@onready var strength_label:Label = $main_layout/strength_label;
@onready var weak_label:Label = $main_layout/weak_label;
@onready var vulnerable_label:Label = $main_layout/vulnerable_label;

## 显示本场持续能力名称，悬停时显示规则说明。
@onready var power_label:Label = $main_layout/power_label;

## 用于显示敌人下一步行动意图。
@onready var intent_label:Label = $main_layout/enemy_intent_label;


## 绑定已经从角色定义初始化的状态；死亡角色也可以显示。
func bind_combatant_state(new_combatant_state:CombatantState)->void:
	combatant_state = new_combatant_state;
	refresh_combatant_view();


## 根据当前绑定的CombatantState刷新角色名称、原画、生命、格挡和状态显示。
##
## 名称和原画来自已经验证的静态角色定义，
## 当前生命和格挡来自运行时状态。
## 该方法只读取数据并更新界面，不修改CombatantDefinition或CombatantState。
func refresh_combatant_view()->void:
	name_label.text = combatant_state.definition.display_name;
	artwork.texture = combatant_state.definition.artwork;
	health_bar.max_value = combatant_state.max_health;
	health_bar.value = combatant_state.current_health;
	health_label.text = "%d / %d" % [combatant_state.current_health, combatant_state.max_health];
	block_label.text = "格挡：%d" % combatant_state.current_block;#当前格挡始终读取运行时真实状态
	block_label.visible = combatant_state.current_block > 0;#格挡为0时隐藏标签
	strength_label.text = "力量：%d" % combatant_state.strength;
	strength_label.visible = combatant_state.strength != 0;
	weak_label.text = "虚弱：%d 回合" % combatant_state.weak_turns;
	weak_label.visible = combatant_state.weak_turns > 0;
	vulnerable_label.text = "易伤：%d 回合" % combatant_state.vulnerable_turns;
	vulnerable_label.visible = combatant_state.vulnerable_turns > 0;
	var power_names:PackedStringArray = [];
	var power_descriptions:PackedStringArray = [];
	for power in combatant_state.powers:
		power_names.append(power.display_name);
		power_descriptions.append("%s：%s" % [power.display_name, power.description]);
	power_label.text = "能力：" + "、".join(power_names);
	power_label.tooltip_text = "\n".join(power_descriptions);
	power_label.visible = not power_names.is_empty();


## 设置当前界面显示的敌人行动意图文字。
##
## intent_text为空时清空并隐藏意图标签；不为空时更新文字并显示标签。
## 该方法只负责更新界面，不会执行意图所描述的攻击、格挡或其他行动。
## 应在当前节点进入场景树、@onready节点引用准备完成后调用。
func set_intent(intent_text:String)->void:
	if intent_text.is_empty():#传入空文本时不应继续显示旧的敌人意图
		intent_label.text = "";#清除标签中原有的意图文字
		intent_label.tooltip_text = "";
		intent_label.hide();#隐藏当前没有内容的意图标签
		return;#空文本的处理已经完成，提前结束方法
	intent_label.text = intent_text;#使用传入文本更新敌人意图
	intent_label.tooltip_text = intent_text;
	intent_label.show();#确保带有内容的意图标签显示出来


## 节点进入场景树并且@onready节点引用准备完成后，设置界面的初始显示状态。
##
## 初始状态下隐藏格挡、状态和敌人意图标签。
## 该方法不会创建CombatantState，也不会擅自绑定玩家或敌人。
func _ready()->void:
	FantasyTheme.apply(self);
	name_label.add_theme_font_override("font", FantasyTheme.font(false));
	for label:Label in [block_label, strength_label, weak_label, vulnerable_label, intent_label]:
		label.mouse_filter = Control.MOUSE_FILTER_PASS;
	block_label.tooltip_text = "格挡先抵消受到的伤害；持有者的回合开始时清空。";
	strength_label.tooltip_text = "每点力量提高每段攻击伤害；本场战斗结束后清空。";
	weak_label.tooltip_text = "攻击伤害降低25%，每段向下取整；显示剩余回合。";
	vulnerable_label.tooltip_text = "受到的攻击伤害提高50%，每段向下取整；显示剩余回合。";
	block_label.hide();#尚未绑定角色状态时，不显示默认格挡文字
	strength_label.hide();
	weak_label.hide();
	vulnerable_label.hide();
	power_label.hide();
	intent_label.hide();#尚未设置敌人意图时，不显示默认意图文字
