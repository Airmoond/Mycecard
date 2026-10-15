## 整局冒险开始前显示的主菜单页面。
##
## 负责显示主菜单内容、接收开始按钮输入，并通过start_requested信号报告
## “玩家希望开始一局新冒险”。GameFlowController以后接收该信号，创建全新的
## RunState并切换到地图页面。
##
## MainMenu属于视图与输入层，不创建或修改RunState，不加载地图，不启动战斗，
## 也不直接切换场景。页面只报告玩家意图，具体流程由外部控制器编排。
class_name MainMenu
extends Control


## 玩家首次按下开始按钮时发出。
##
## 该信号不携带参数，因为新冒险使用哪份RunDefinition由GameFlowController决定。
## 同一个MainMenu实例在生命周期内最多发出一次该信号。
signal start_requested


## 当前主菜单是否已经报告过开始请求。
##
## 这是防止快速连续点击产生重复RunState或重复页面切换的局部界面状态，
## 不属于整局冒险数据，也不会保存到RunState中。
var _start_request_sent:bool = false


## 主菜单中供玩家开始新冒险的按钮。
##
## 节点路径要求main_menu.tscn使用center_container/main_layout/start_button结构。
## 该引用只用于连接输入、禁用重复点击，不负责创建任何游戏状态。
@onready var start_button:Button = $center_container/main_layout/start_button


## 页面节点准备完成后连接开始按钮的pressed信号。
##
## 按钮只把输入交给_on_start_button_pressed处理，不直接调用流程控制器。
## 每个主菜单页面实例只会建立这一条本地信号连接。
func _ready()->void:
	start_button.pressed.connect(_on_start_button_pressed);#把按钮输入统一转交给当前View的私有处理方法


## 接收玩家按下开始按钮的输入，并且只报告一次开始请求。
##
## 已经报告过请求时直接忽略后续输入；首次请求会先保存防重复状态、禁用按钮，
## 再发出start_requested。该方法不创建RunState，也不切换或释放当前页面。
func _on_start_button_pressed()->void:
	if _start_request_sent:#页面切换完成前可能收到快速连续输入，需要保证信号只发出一次
		return;#已经报告的玩家意图不应再次触发新局创建

	_start_request_sent = true;#先提交本地防重复状态，阻止同一调用链中的再次进入
	start_button.disabled = true;#提供立即的界面反馈，并阻止玩家继续点击当前按钮
	start_requested.emit();#只报告“希望开始”，由GameFlowController决定如何创建和切换流程

## 新页面准备失败时，恢复尚未提交的新局请求。
func reset_start_request()->void:
	_start_request_sent = false
	start_button.disabled = false
