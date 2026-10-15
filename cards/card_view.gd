## 手牌外层保留稳定输入矩形，只对共用卡面做140ms悬停变换。
extends Control
class_name CardView

const PLAYABLE_MODULATE:Color = Color.WHITE
const UNPLAYABLE_MODULATE:Color = Color(0.55, 0.55, 0.55, 0.65)
const CARD_FACE_SCENE:PackedScene = preload("res://cards/card_face.tscn")
const HOVER_PREVIEW_SIZE:Vector2 = Vector2(270, 378)
signal card_selected(selected_card:CardInstance)
var card_instance:CardInstance
var _hover_tween:Tween
var _hovered:bool = false
var _hover_layer:CanvasLayer
var _hover_preview:CardFace
var _overlay_host:OverlayHost

func set_overlay_host(host:OverlayHost)->void:
	if _overlay_host != host:
		_close_hover_preview()
	_overlay_host = host
@onready var card_face:CardFace = $card_face

func _ready()->void:
	custom_minimum_size = CardFace.BASE_SIZE
	size = custom_minimum_size
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	resized.connect(_sync_face_size)

func _sync_face_size()->void:
	if not is_node_ready():
		return
	card_face.set_display_size(size)
	card_face.pivot_offset = Vector2(size.x * 0.5, size.y)
	if not _hovered:
		card_face.position = Vector2.ZERO
	else:
		_place_hover_preview()

## 手中牌多时由战场布局调整占位与卡面，实际点击仍位于原占位矩形。
func set_display_size(value:Vector2)->void:
	custom_minimum_size = value
	size = value
	_sync_face_size()

func bind_card_instance(new_card_instance:CardInstance)->void:
	card_instance = new_card_instance
	refresh_card_view()

func refresh_card_view()->void:
	card_face.show_card(card_instance.definition, card_instance.current_energy_cost)
	tooltip_text = card_face.tooltip_text
	_refresh_hover_preview()

func set_description(text:String)->void:
	card_face.set_description(text)
	tooltip_text = card_face.tooltip_text
	_refresh_hover_preview()

func _get_tooltip(_at_position:Vector2)->String:
	return "" if is_instance_valid(_hover_preview) else tooltip_text

func set_playable_visual(is_playable:bool)->void:
	modulate = PLAYABLE_MODULATE if is_playable else UNPLAYABLE_MODULATE

func _set_hovered(value:bool)->void:
	_hovered = value
	if is_instance_valid(_hover_tween):
		_hover_tween.kill()
	z_index = 8 if value else 0
	card_face.pivot_offset = Vector2(size.x * 0.5, size.y)
	_hover_tween = create_tween().set_parallel(true)
	_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(card_face, "position", Vector2(0, -16) if value else Vector2.ZERO, 0.14)
	_hover_tween.tween_property(card_face, "scale", Vector2(1.06, 1.06) if value else Vector2.ONE, 0.14)
	if value and card_instance != null:
		_open_hover_preview()
	else:
		_close_hover_preview()

## 独立画布保持小窗口长规则可读；展示层忽略鼠标，不改变原手牌点击范围。
func _open_hover_preview()->void:
	if is_instance_valid(_hover_preview):
		return
	if is_instance_valid(_overlay_host) and _overlay_host.has_blocking_modal():
		return
	_hover_preview = CARD_FACE_SCENE.instantiate()
	if is_instance_valid(_overlay_host):
		_overlay_host.attach_hover(_hover_preview, self)
	else:
		_hover_layer = CanvasLayer.new()
		_hover_layer.layer = 20
		add_child(_hover_layer)
		_hover_layer.add_child(_hover_preview)
	var window_size:Vector2 = get_viewport_rect().size
	var factor:float = minf(1.0, minf(window_size.x * 0.32 / HOVER_PREVIEW_SIZE.x, window_size.y * 0.60 / HOVER_PREVIEW_SIZE.y))
	_hover_preview.set_display_size(HOVER_PREVIEW_SIZE * factor)
	_refresh_hover_preview()
	_place_hover_preview()
	_hover_preview.modulate.a = 0.0
	create_tween().tween_property(_hover_preview, "modulate:a", 1.0, 0.14)

func _refresh_hover_preview()->void:
	if not is_instance_valid(_hover_preview) or card_instance == null:
		return
	_hover_preview.show_card(card_instance.definition, card_instance.current_energy_cost)
	_hover_preview.set_description(card_face.description_label.text)

func _place_hover_preview()->void:
	if not is_instance_valid(_hover_preview):
		return
	var card_rect:Rect2 = get_global_rect()
	var window_size:Vector2 = get_viewport_rect().size
	_hover_preview.position = Vector2(
		clampf(card_rect.get_center().x - _hover_preview.size.x * 0.5, 10.0, window_size.x - _hover_preview.size.x - 10.0),
		clampf(card_rect.position.y - _hover_preview.size.y - 18.0, 10.0, window_size.y - _hover_preview.size.y - 10.0)
	)

func _close_hover_preview()->void:
	if is_instance_valid(_hover_preview) and is_instance_valid(_overlay_host):
		_overlay_host.release_hover(_hover_preview)
	if is_instance_valid(_hover_layer):
		_hover_layer.queue_free()
	_hover_layer = null
	_hover_preview = null

func _exit_tree()->void:
	_close_hover_preview()

## 合法出牌后由独立表现层挂载；快照不持有旧CardView或修改实例。
func make_play_snapshot()->Control:
	var copy:CardFace = CARD_FACE_SCENE.instantiate()
	var definition:CardDefinition = card_instance.definition
	var cost:int = card_instance.current_energy_cost
	var description:String = card_face.description_label.text
	var display_size:Vector2 = card_face.size
	copy.ready.connect(func()->void:
		copy.set_display_size(display_size)
		copy.show_card(definition, cost)
		copy.set_description(description)
	, CONNECT_ONE_SHOT)
	return copy

func _gui_input(event:InputEvent)->void:
	var mouse_event:InputEventMouseButton = event as InputEventMouseButton
	if mouse_event == null or mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	if card_instance == null:
		push_error("当前卡牌界面尚未绑定卡牌实例，无法报告点击")
		return
	card_selected.emit(card_instance)
