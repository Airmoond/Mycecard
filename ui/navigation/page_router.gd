## 页面创建先准备，验证成功后提交；准备阶段不接收玩家输入。
class_name PageRouter
extends Node

signal page_committed(previous:Control, current:Control)

## 最近成功提交的当前页面；切换时在旧页退出回调前更新身份。
var current_page:Control
## 成功提交页面的次数，可用于识别页面切换代次。
var generation:int = 0
## 页面准备与提交共同使用的容器，候选不能在两步之间换父节点。
var _container:Control
## 各候选准备前的处理模式，提交时据此恢复。
var _prepared_modes:Dictionary = {}
## 已经隐藏挂载、尚未提交或丢弃的候选页面。
var _prepared:Array[Control] = []
## 是否正在切换页面，期间拒绝重入提交与页面来源验证。
var _committing:bool = false

## 设置所有准备页与当前页共同使用的挂载容器。
func configure(container:Control)->void:
	_container = container

## 实例化并校验页面根脚本，将页面隐藏、禁用处理并挂载后调用可选初始化。
##
## 初始化明确返回 [code]false[/code] 时丢弃候选并保留当前页；失败返回 [code]null[/code]，成功返回待提交页面。
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

## 将有效待提交页面设为当前页，恢复其显示与处理模式，并移除及排队释放旧页。
##
## 提交期间拒绝重入；候选不合法或当前页所有权异常时返回 [code]false[/code]。
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

## 取消候选登记，将页面移出原父节点并排队释放，不替换当前页面。
func discard(page:Control)->void:
	_prepared_modes.erase(page)
	_prepared.erase(page)
	if is_instance_valid(page):
		if page.get_parent() != null:
			page.get_parent().remove_child(page)
		page.queue_free()

## 返回页面是否为已完成提交、仍在场景树且未排队释放的当前来源；提交期间返回 [code]false[/code]。
func is_current(page:Node)->bool:
	return not _committing and is_instance_valid(page) and page == current_page and page.is_inside_tree() and not page.is_queued_for_deletion()

## 退出场景树时清除候选登记、当前页面引用及提交标记。
func _exit_tree()->void:
	_prepared.clear()
	_prepared_modes.clear()
	current_page = null
	_committing = false
