## 导航失败的显示页，只报告重试或返回意图，不写入冒险规则。
class_name NavigationError
extends Control

signal retry_requested;
signal menu_requested;

@onready var retry_button:Button = %retry_button;
@onready var menu_button:Button = %menu_button;

func _ready()->void:
	retry_button.pressed.connect(func()->void: retry_requested.emit());
	menu_button.pressed.connect(func()->void: menu_requested.emit());
