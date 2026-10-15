## 应用持有的浮层宿主；规则模块不依赖它。
class_name OverlayHost
extends Node

const LAYER_HOVER:int = 20
const LAYER_BATTLE_FEEDBACK:int = 24
const LAYER_PAGE_MODAL:int = 100
const LAYER_TOAST:int = 140
const LAYER_SETTINGS:int = 200

signal blocking_changed(blocked:bool)

var _hover_surface:Control
var _modal_surface:Control
var _toast_surface:Control
var _modals:Array[Dictionary] = []
var _hover_owners:Dictionary = {}
var _toast:Control
var _navigation_error:NavigationError
const NAVIGATION_ERROR_SCENE:PackedScene = preload("res://ui/navigation/navigation_error.tscn")

func _ready()->void:
	_hover_surface = _make_surface("hover_layer", LAYER_HOVER)
	_modal_surface = _make_surface("modal_layer", LAYER_PAGE_MODAL)
	_toast_surface = _make_surface("toast_layer", LAYER_TOAST)

func _make_surface(title:String, order:int)->Control:
	var layer:CanvasLayer = CanvasLayer.new()
	layer.name = title
	layer.layer = order
	add_child(layer)
	var surface:Control = Control.new()
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return surface

func attach_hover(preview:Control, owner:Node)->void:
	if not is_instance_valid(preview):
		return
	if has_blocking_modal():
		preview.queue_free()
		return
	_hover_surface.add_child(preview)
	_hover_owners[preview] = owner
	owner.tree_exiting.connect(release_hover.bind(preview), CONNECT_ONE_SHOT)

func release_hover(preview:Control)->void:
	var owner:Node = _hover_owners.get(preview)
	var exit_callback:Callable = release_hover.bind(preview)
	if is_instance_valid(owner) and owner.tree_exiting.is_connected(exit_callback):
		owner.tree_exiting.disconnect(exit_callback)
	_hover_owners.erase(preview)
	if is_instance_valid(preview) and not preview.is_queued_for_deletion():
		preview.queue_free()

func attach_page_modal(modal:Control, owner:Node)->void:
	_modal_surface.add_child(modal)
	modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	register_modal(modal, owner, modal.close)

func register_modal(modal:Control, owner:Node, close_callback:Callable)->void:
	unregister_modal(modal)
	var focus:Control = get_viewport().gui_get_focus_owner()
	_modals.append({"view":modal, "owner":owner, "close":close_callback, "focus":focus})
	var on_modal_exit:Callable = unregister_modal.bind(modal)
	if not modal.tree_exiting.is_connected(on_modal_exit):
		modal.tree_exiting.connect(on_modal_exit, CONNECT_ONE_SHOT)
	var on_owner_exit:Callable = _release_owner.bind(owner)
	if not owner.tree_exiting.is_connected(on_owner_exit):
		owner.tree_exiting.connect(on_owner_exit, CONNECT_ONE_SHOT)
	for preview in _hover_owners.keys():
		release_hover(preview)
	blocking_changed.emit(true)

func unregister_modal(modal:Control)->void:
	var restored:Control
	for index in range(_modals.size() - 1, -1, -1):
		if _modals[index]["view"] == modal:
			if is_instance_valid(_modals[index]["focus"]):
				restored = _modals[index]["focus"]
			var owner:Node = _modals[index]["owner"]
			_modals.remove_at(index)
			var callback:Callable = unregister_modal.bind(modal)
			if is_instance_valid(modal) and modal.tree_exiting.is_connected(callback):
				modal.tree_exiting.disconnect(callback)
			var has_owned_modal:bool = false
			for record:Dictionary in _modals:
				if record["owner"] == owner:
					has_owned_modal = true
			var on_owner_exit:Callable = _release_owner.bind(owner)
			if not has_owned_modal and is_instance_valid(owner) and owner.tree_exiting.is_connected(on_owner_exit):
				owner.tree_exiting.disconnect(on_owner_exit)
	if is_instance_valid(restored) and restored.is_inside_tree() and not restored.is_queued_for_deletion() and restored.is_visible_in_tree():
		restored.grab_focus()
	blocking_changed.emit(has_blocking_modal())

func has_blocking_modal()->bool:
	for record in _modals:
		var modal:Control = record["view"]
		if is_instance_valid(modal) and not modal.is_queued_for_deletion() and modal.is_visible_in_tree():
			return true
	return false

func _release_owner(owner:Node)->void:
	for record in _modals.duplicate():
		if record["owner"] == owner:
			var modal:Control = record["view"]
			unregister_modal(modal)
			if is_instance_valid(modal) and not modal.is_queued_for_deletion():
				modal.queue_free()

func clear_transient()->void:
	for preview in _hover_owners.keys():
		release_hover(preview)
	if is_instance_valid(_toast):
		_toast.queue_free()
	_toast = null

func show_terminal(victory:bool)->void:
	clear_transient()
	var panel:PanelContainer = PanelContainer.new()
	panel.name = "terminal_toast"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.position = Vector2(18, maxf(18, get_viewport().get_visible_rect().size.y - 62))
	panel.size = Vector2(210, 42)
	panel.theme = FantasyTheme.build_theme()
	_toast_surface.add_child(panel)
	_toast = panel
	var label:Label = Label.new()
	label.text = "战斗胜利" if victory else "战斗失败"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	panel.add_child(label)
	var tween:Tween = panel.create_tween()
	tween.tween_property(panel, "modulate:a", 0, 0.5)
	tween.tween_callback(panel.queue_free)

func _input(event:InputEvent)->void:
	if not event is InputEventKey or not event.pressed or event.echo or event.keycode != KEY_ESCAPE:
		return
	var top_index:int = -1
	var top_layer:int = -2147483648
	# 显示层级优先；同层后打开的窗口优先，不能关闭被设置遮住的下层页面。
	for index in range(_modals.size()):
		var modal:Control = _modals[index]["view"]
		if is_instance_valid(modal) and modal.is_visible_in_tree() and not modal.is_queued_for_deletion():
			var layer:int = _canvas_layer(modal)
			if layer >= top_layer:
				top_layer = layer
				top_index = index
	if top_index >= 0:
		var close_callback:Callable = _modals[top_index]["close"]
		if close_callback.is_valid():
			close_callback.call()
		get_viewport().set_input_as_handled()

func _canvas_layer(view:Node)->int:
	var current:Node = view
	while current != null:
		if current is CanvasLayer:
			return current.layer
		current = current.get_parent()
	return 0

func show_navigation_error(retry:Callable, menu:Callable)->void:
	if is_instance_valid(_navigation_error):
		return
	var panel:NavigationError = NAVIGATION_ERROR_SCENE.instantiate()
	_navigation_error = panel
	_modal_surface.add_child(panel)
	register_modal(panel, self, _navigation_action.bind(retry, panel))
	panel.retry_requested.connect(_navigation_action.bind(retry, panel))
	panel.menu_requested.connect(_navigation_action.bind(menu, panel))
	panel.retry_button.grab_focus()

func _navigation_action(action:Callable, panel:NavigationError)->void:
	if not is_instance_valid(panel) or panel != _navigation_error:
		return
	_navigation_error = null
	panel.hide()
	unregister_modal(panel)
	panel.queue_free()
	if action.is_valid():
		action.call()
