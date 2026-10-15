## 一份卡面覆盖手牌、构筑、奖励、事件选牌与浏览；静态资源始终只读。
class_name CardFace
extends Control

const BASE_SIZE:Vector2 = Vector2(180, 252)
const TYPE_NAMES:Array[String] = ["攻击", "技能", "能力", "武器"]
const RARITY_COLORS:Array[Color] = [Color.WHITE, Color("3b82f6"), Color("a855f7"), Color("ffa500")]

@onready var cost_label:Label = $cost_label
@onready var name_label:Label = $name_label
@onready var artwork:TextureRect = $artwork
@onready var description_label:CardDescriptionLabel = $description_label
@onready var rarity_gem:Polygon2D = $rarity_gem
@onready var missing_art:Label = $missing_art
var _display_size:Vector2 = BASE_SIZE
var _base_rects:Dictionary = {}
var _base_fonts:Dictionary = {}
var _base_polygons:Dictionary = {}
@export var description_base_font_size:int = 12

func _ready()->void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_base_rects[child] = Rect2(child.position, child.size)
			if child is Label:
				_base_fonts[child] = child.get_theme_font_size("font_size")
		elif child is Polygon2D:
			_base_polygons[child] = {"position":child.position, "scale":child.scale}
	set_display_size(_display_size)

## 外层只需提供显示尺寸；子节点坐标和字号统一缩放，浏览窗口不再逐项猜尺寸。
func set_display_size(value:Vector2)->void:
	_display_size = value
	custom_minimum_size = value
	size = value
	if not is_node_ready():
		return
	var factor:Vector2 = value / BASE_SIZE
	for child in get_children():
		if child is Control and _base_rects.has(child):
			var bounds:Rect2 = _base_rects[child]
			child.position = bounds.position * factor
			child.size = bounds.size * factor
			if child is Label:
				var base_size:int = _base_fonts[child]
				child.add_theme_font_size_override("font_size", maxi(7, roundi(base_size * factor.x)))
		elif child is Polygon2D:
			child.scale = _base_polygons[child]["scale"] * factor
			child.position = _base_polygons[child]["position"] * factor
	description_label.set_base_font_size(maxi(8, roundi(description_base_font_size * factor.x)))

## 显示实际费用，基础规则文案可由控制器稍后更新成伤害预览。
func show_card(definition:CardDefinition, energy_cost:int)->void:
	cost_label.text = str(energy_cost)
	name_label.text = definition.card_name
	artwork.texture = definition.artwork
	missing_art.visible = definition.artwork == null
	$cardtype_label.text = TYPE_NAMES[definition.card_type]
	$expansion_type_label.text = "标"
	$expansion_type_label.tooltip_text = "标准扩展包"
	rarity_gem.color = RARITY_COLORS[definition.rarity]
	for child in get_children():
		if child is Label or child is RichTextLabel:
			var style:StyleBoxFlat = child.get_theme_stylebox("normal").duplicate()
			# 颜色元数据保留，卡面只用中央宝石显示稀有度，避免所有文字另套彩框。
			style.border_color = RARITY_COLORS[definition.rarity]
			child.add_theme_stylebox_override("normal", style)
	set_description(definition.format_description())

func set_description(value:String)->void:
	description_label.set_description(value)
	tooltip_text = "标准扩展包\n" + value
