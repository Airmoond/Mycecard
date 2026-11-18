## 应用持有的浮层宿主；规则模块不依赖它。
class_name OverlayHost
extends Node

## 卡牌等非阻挡悬停预览的画布层级。
const LAYER_HOVER:int = 20
## 战斗数字、卡面残影及高亮反馈的画布层级。
const LAYER_BATTLE_FEEDBACK:int = 24
## 页面所属查看器与导航错误窗口的画布层级。
const LAYER_PAGE_MODAL:int = 100
## 允许跨页面显示的短提示画布层级。
const LAYER_TOAST:int = 140
## 应用声音设置的画布层级，高于页面模态窗口。
const LAYER_SETTINGS:int = 200

signal blocking_changed(blocked:bool)

## 应用拥有的悬停预览挂载容器。
var _hover_surface:Control
## 页面查看器与导航错误窗口的挂载容器。
var _modal_surface:Control
## 允许跨页面保留的终局短提示挂载容器。
var _toast_surface:Control
## 模态登记栈；每项保存视图、拥有者、关闭回调及打开前焦点。
var _modals:Array[Dictionary] = []
## 悬停预览到拥有者的映射，用于页面退出时清理。
var _hover_owners:Dictionary = {}
## 当前由应用持有的跨页短提示。
var _toast:Control
## 当前导航错误窗口引用，存在时不重复创建。
var _navigation_error:NavigationError
const NAVIGATION_ERROR_SCENE:PackedScene = preload("res://ui/navigation/navigation_error.tscn")

## 创建悬停、页面模态及短提示的独立画布容器。
func _ready()->void:
	_hover_surface = _make_surface("hover_layer", LAYER_HOVER)
	_modal_surface = _make_surface("modal_layer", LAYER_PAGE_MODAL)
	_toast_surface = _make_surface("toast_layer", LAYER_TOAST)

## 创建指定名称与层级的全屏画布容器，容器本身不拦截鼠标。
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

## 将有效预览挂入悬停层并绑定拥有者退出清理；存在阻挡模态时直接释放预览。
func attach_hover(preview:Control, owner:Node)->void:
	if not is_instance_valid(preview):
		return
	if has_blocking_modal():
		preview.queue_free()
		return
	_hover_surface.add_child(preview)
	_hover_owners[preview] = owner
	owner.tree_exiting.connect(release_hover.bind(preview), CONNECT_ONE_SHOT)

## 取消预览拥有者的退出连接及登记，再排队释放仍有效的预览。
func release_hover(preview:Control)->void:
	var owner:Node = _hover_owners.get(preview)
	var exit_callback:Callable = release_hover.bind(preview)
	if is_instance_valid(owner) and owner.tree_exiting.is_connected(exit_callback):
		owner.tree_exiting.disconnect(exit_callback)
	_hover_owners.erase(preview)
	if is_instance_valid(preview) and not preview.is_queued_for_deletion():
		preview.queue_free()

## 将页面查看器挂载到全屏模态层，并以其关闭方法登记页面所有权。
func attach_page_modal(modal:Control, owner:Node)->void:
	_modal_surface.add_child(modal)
	modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	register_modal(modal, owner, modal.close)

## 登记窗口、拥有者、关闭回调及先前焦点，连接退出清理并释放全部悬停预览。
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

## 取消指定窗口的模态及退出连接，尽可能恢复先前焦点并通知当前阻挡状态。
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

## 返回是否存在有效、可见且未排队释放的已登记模态窗口。
func has_blocking_modal()->bool:
	for record in _modals:
		var modal:Control = record["view"]
		if is_instance_valid(modal) and not modal.is_queued_for_deletion() and modal.is_visible_in_tree():
			return true
	return false

## 取消并释放指定拥有者登记的全部模态窗口。
func _release_owner(owner:Node)->void:
	for record in _modals.duplicate():
		if record["owner"] == owner:
			var modal:Control = record["view"]
			unregister_modal(modal)
			if is_instance_valid(modal) and not modal.is_queued_for_deletion():
				modal.queue_free()

## 释放所有悬停预览和当前短提示，不关闭已登记的模态窗口。
func clear_transient()->void:
	for preview in _hover_owners.keys():
		release_hover(preview)
	if is_instance_valid(_toast):
		_toast.queue_free()
	_toast = null

## 清除旧临时内容后显示不拦截输入的胜败短提示，并淡出释放。
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

## 处理首次 Esc 按下，仅调用最高可见画布层的模态关闭回调；同层优先最近登记的窗口。
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

## 沿父节点查找最近的画布层级；没有 [CanvasLayer] 祖先时返回 [code]0[/code]。
func _canvas_layer(view:Node)->int:
	var current:Node = view
	while current != null:
		if current is CanvasLayer:
			return current.layer
		current = current.get_parent()
	return 0

## 没有现存导航错误窗口时创建并登记重试与返回入口，将焦点移到重试按钮。
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

## 仅处理当前导航错误窗口，先隐藏、取消登记并释放，再调用有效的目标操作。
func _navigation_action(action:Callable, panel:NavigationError)->void:
	if not is_instance_valid(panel) or panel != _navigation_error:
		return
	_navigation_error = null
	panel.hide()
	unregister_modal(panel)
	panel.queue_free()
	if action.is_valid():
		action.call()
