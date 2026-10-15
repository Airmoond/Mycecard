## 共用主题资源；配色、字体和默认控件外观在Theme中直接编辑。
class_name FantasyTheme
extends RefCounted

const GOLD:Color = Color("c5a269")
const PAPER:Color = Color("ead6ae")
const INK:Color = Color("37271b")
const MUTED:Color = Color("baa37b")
const WOOD:Color = Color("3e2c1e")
const THEME:Theme = preload("res://ui/themes/fantasy_theme.tres")

static func font(body:bool = true)->Font:
	return THEME.default_font if body else THEME.get_font("font", "TitleLabel")

static func build_theme()->Theme:
	return THEME

static func wood_style(color:Color = WOOD, border:Color = GOLD, radius:int = 8)->StyleBoxFlat:
	var style:StyleBoxFlat = THEME.get_stylebox("normal", "Button").duplicate()
	style.bg_color = color
	style.border_color = border
	style.set_corner_radius_all(radius)
	return style

static func parchment_style()->StyleBoxFlat:
	return THEME.get_stylebox("panel", "ParchmentPanel").duplicate()

static func apply(root:Control)->void:
	root.theme = THEME

static func style_panel(panel:Control, parchment:bool = false)->void:
	panel.theme_type_variation = &"ParchmentPanel" if parchment else &"PanelContainer"

static func style_button(button:Button, prominent:bool = false)->void:
	button.flat = false
	button.theme_type_variation = &"ProminentButton" if prominent else &"Button"
