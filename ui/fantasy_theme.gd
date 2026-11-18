## 共用主题资源；配色、字体和默认控件外观在Theme中直接编辑。
class_name FantasyTheme
extends RefCounted

## 界面金色强调与默认边框颜色。
const GOLD:Color = Color("c5a269")
## 羊皮纸文本或底色所用的浅色调。
const PAPER:Color = Color("ead6ae")
## 深色正文墨色。
const INK:Color = Color("37271b")
## 次要文字使用的柔和色调。
const MUTED:Color = Color("baa37b")
## 木质面板与按钮的默认背景颜色。
const WOOD:Color = Color("3e2c1e")
## 所有页面共用的主题资源；需要局部修改样式时应复制具体样式。
const THEME:Theme = preload("res://ui/themes/fantasy_theme.tres")

## 返回共享主题的正文字体；[param body] 为 [code]false[/code] 时返回标题字体。
static func font(body:bool = true)->Font:
	return THEME.default_font if body else THEME.get_font("font", "TitleLabel")

## 返回共享主题资源本身，不创建副本。
static func build_theme()->Theme:
	return THEME

## 复制按钮的基础样式，再设置背景、边框和圆角，返回可独立修改的样式。
static func wood_style(color:Color = WOOD, border:Color = GOLD, radius:int = 8)->StyleBoxFlat:
	var style:StyleBoxFlat = THEME.get_stylebox("normal", "Button").duplicate()
	style.bg_color = color
	style.border_color = border
	style.set_corner_radius_all(radius)
	return style

## 返回羊皮纸面板样式的独立副本，不修改共享主题。
static func parchment_style()->StyleBoxFlat:
	return THEME.get_stylebox("panel", "ParchmentPanel").duplicate()

## 将共享主题赋给指定根控件。
static func apply(root:Control)->void:
	root.theme = THEME

## 为面板选择羊皮纸或普通面板主题变体。
static func style_panel(panel:Control, parchment:bool = false)->void:
	panel.theme_type_variation = &"ParchmentPanel" if parchment else &"PanelContainer"

## 取消扁平模式，并按是否突出显示选择按钮主题变体。
static func style_button(button:Button, prominent:bool = false)->void:
	button.flat = false
	button.theme_type_variation = &"ProminentButton" if prominent else &"Button"
