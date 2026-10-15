## 页面创建先准备，验证成功后提交；准备阶段不接收玩家输入。
class_name PageRouter
extends Node

signal page_committed(previous:Control, current:Control)

var current_page:Control
var generation:int = 0
var _container:Control
var _prepared_modes:Dictionary = {}
var _prepared:Array[Control] = []
var _committing:bool = false

func configure(container:Control)->void:
	_container = container

func prepare(scene:PackedScene, expected_script:Script, initializer:Callable = Callable())->Control:
	if scene == null or not is_instance_valid(_container):
		push_error("PageRouter：缺少场景或页面容器。")
		return null
	var candidate:Node = scene.instantiate()
	if not candidate is Control or (expected_script != null and candidate.get_script() != expected_script):
		push_error("PageRouter：页面根节点类型不符合契约。")
		candidate.free()
		return null
	var page:Control = candidate as Control
	_prepared.append(page)
	_prepared_modes[page] = page.process_mode
	page.process_mode = Node.PROCESS_MODE_DISABLED
	page.hide()
	_container.add_child(page)
	if initializer.is_valid():
		var accepted:Variant = initializer.call(page)
		if accepted is bool and not accepted:
			push_error("PageRouter：页面准备失败，保留当前页面。")
			discard(page)
			return null
	return page

func commit(page:Control)->bool:
	if _committing or not is_instance_valid(page) or not _prepared.has(page) or page.get_parent() != _container or not page.is_inside_tree() or page.is_queued_for_deletion():
		return false
	if is_instance_valid(current_page) and current_page.get_parent() != _container:
		push_error("PageRouter：当前页面所有权异常，取消切换。")
		discard(page)
		return false
	var previous:Control = current_page if is_instance_valid(current_page) else null
	var restored_mode:Node.ProcessMode = _prepared_modes[page]
	# 移出旧页会同步触发退出信号，先更新身份并关闭提交入口。
	_committing = true
	current_page = page
	generation += 1
	_prepared_modes.erase(page)
	_prepared.erase(page)
	if previous != null:
		previous.process_mode = Node.PROCESS_MODE_DISABLED
		previous.hide()
		_container.remove_child(previous)
	page.process_mode = restored_mode
	page.show()
	if previous != null:
		previous.queue_free()
	_committing = false
	page_committed.emit(previous, page)
	return true

func discard(page:Control)->void:
	_prepared_modes.erase(page)
	_prepared.erase(page)
	if is_instance_valid(page):
		if page.get_parent() != null:
			page.get_parent().remove_child(page)
		page.queue_free()

func is_current(page:Node)->bool:
	return not _committing and is_instance_valid(page) and page == current_page and page.is_inside_tree() and not page.is_queued_for_deletion()

func _exit_tree()->void:
	_prepared.clear()
	_prepared_modes.clear()
	current_page = null
	_committing = false
