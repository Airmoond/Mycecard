## 只读的藏品说明窗口；关闭时释放自身，不改变持有或战斗状态。
class_name CollectionInspector
extends Control

signal closed;

## 此只读窗口正在展示的藏品定义，可以为空。
var collection:CollectionDefinition;
## 是否已经报告关闭，用于阻止重复关闭通知。
var _closing:bool = false;

@onready var icon_view:TextureRect = %icon_view;
@onready var name_label:Label = %name_label;
@onready var description_label:Label = %description_label;
@onready var close_button:Button = %close_button;

## 连接关闭按钮，并延迟将键盘焦点移到按钮。
func _ready()->void:
	close_button.pressed.connect(close);
	_focus_close_button.call_deferred();

## 窗口仍有效且尚未关闭时，为有效的关闭按钮取得焦点。
func _focus_close_button()->void:
	if _closing or not is_inside_tree() or is_queued_for_deletion():
		return;
	if is_instance_valid(close_button) and close_button.is_inside_tree() and not close_button.is_queued_for_deletion():
		close_button.grab_focus();

## 显示指定藏品的图标、名称和说明；为空时显示尚未获得藏品的引导。
func setup(new_collection:CollectionDefinition)->void:
	collection = new_collection;
	if collection == null:
		icon_view.visible = false;
		name_label.text = "尚未获得藏品";
		description_label.text = "进入地图的开始节点，选择一件藏品。";
		return;
	icon_view.visible = true;
	icon_view.texture = collection.icon;
	name_label.text = collection.display_name;
	description_label.text = collection.description;

## 接收未处理的 Esc 按下，标记输入已处理并关闭窗口。
func _unhandled_key_input(event:InputEvent)->void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled();
		close();

## 只发出一次关闭通知并排队释放自身，不修改藏品持有状态。
func close()->void:
	if _closing:
		return;
	_closing = true;
	closed.emit();
	queue_free();
