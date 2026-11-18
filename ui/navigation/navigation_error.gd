## 导航失败的显示页，只报告重试或返回意图，不写入冒险规则。
class_name NavigationError
extends Control

signal retry_requested;
signal menu_requested;

@onready var retry_button:Button = %retry_button;
@onready var menu_button:Button = %menu_button;

## 将重试与返回按钮连接为对应的页面意图信号，不自行重试规则命令。
func _ready()->void:
	## 将重试按钮点击转发为重试意图，不在错误页执行业务命令。
	retry_button.pressed.connect(func()->void: retry_requested.emit());
	## 将返回按钮点击转发为菜单意图，实际切页由外部处理。
	menu_button.pressed.connect(func()->void: menu_requested.emit());
