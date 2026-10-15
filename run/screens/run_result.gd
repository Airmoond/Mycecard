## 一局冒险结束后显示胜利或失败结果的结算页面。
##
## GameFlowController以后实例化该页面，并通过setup传入本局是否胜利。
## 页面负责显示对应结果文字、接收“再次启程”按钮输入，再通过restart_requested
## 信号报告“玩家希望离开结算并返回主菜单”。
##
## RunResult属于视图与输入层，不读取或修改RunState，不复用旧局内数据，
## 也不直接清理旧局或切换页面；返回主菜单的流程由GameFlowController编排。
class_name RunResult
extends Control


## 胜利结算时显示给玩家的固定文字。
const VICTORY_TEXT:String = "恭喜，强敌已被战胜，你的旅途还在继续！"


## 失败结算时显示给玩家的固定文字。
const DEFEAT_TEXT:String = "遭遇强敌落败，旅程暂时告一段落..."


## 玩家在已经完成页面设置后首次按下“再次启程”按钮时发出。
##
## 该信号不携带旧RunState或胜负结果；GameFlowController收到请求后清理旧状态
## 并返回主菜单。同一个页面实例最多发出一次该信号。
signal restart_requested


## 当前结算页面是否已经通过setup取得并显示了真实胜负结果。
##
## 这是局部界面准备状态，不属于整局冒险数据。setup完成前重新开始按钮保持禁用。
var _is_setup:bool = false


## 当前页面是否已经报告过重新开始请求。
##
## 用于防止快速连续点击导致GameFlowController重复清理状态或切换页面。
var _restart_request_sent:bool = false


## 显示整局胜利或失败结算文字的标签。
##
## 节点路径要求run_result.tscn使用center_container/main_layout/result_label结构。
@onready var result_label:Label = $center_container/main_layout/result_label


## 供玩家请求离开结算页面并返回主菜单的“再次启程”按钮。
##
## 节点路径要求run_result.tscn使用center_container/main_layout/restart_button结构。
## 该按钮只报告输入，不负责释放旧RunState或创建新状态。
@onready var restart_button:Button = $center_container/main_layout/restart_button


## 页面节点准备完成后连接“再次启程”按钮，并等待外部流程传入真实结果。
##
## 初始禁用按钮可以防止setup调用前产生没有结果上下文的返回请求。
func _ready()->void:
	restart_button.pressed.connect(_on_restart_button_pressed);#把按钮输入统一转交给当前View的私有处理方法
	restart_button.disabled = true;#外部流程调用setup显示真实结果后才允许玩家返回主菜单


## 使用整局胜负结果设置当前结算页面。
##
## victory为true时显示“强敌已被战胜，旅途继续...”，为false时显示
## “遭遇强敌落败，旅程结束...”。每次设置都会恢复按钮与防重复状态。
##
## 该方法应在页面进入场景树、@onready节点引用准备完成后调用。
## 它只更新界面，不改变RunState.status，也不决定下一局使用哪份RunDefinition。
func setup(victory:bool)->void:
	if victory:#流程控制器报告当前整局已经取得胜利
		result_label.text = VICTORY_TEXT;#显示胜利结算文字
	else:#false表示玩家已经在本局冒险中失败
		result_label.text = DEFEAT_TEXT;#显示失败结算文字

	_is_setup = true;#真实结算内容已经显示，页面现在可以接受重新开始输入
	_restart_request_sent = false;#重置当前页面实例的防重复请求状态
	restart_button.disabled = false;#允许玩家在阅读结果后请求返回主菜单


## 接收玩家按下“再次启程”按钮的输入，并且只报告一次请求。
##
## 页面尚未完成setup或已经报告过请求时忽略输入；首次有效输入会先保存防重复
## 状态、禁用按钮，再发出restart_requested。该方法不直接创建或清理RunState。
func _on_restart_button_pressed()->void:
	if not _is_setup:#没有真实胜负结果时不能离开一个尚未准备完成的结算页面
		return;#保持按钮与流程状态不变，不发出缺少上下文的请求
	if _restart_request_sent:#页面替换完成前可能收到快速连续输入
		return;#已经报告过的玩家意图不能再次触发新局创建

	_restart_request_sent = true;#先提交本地防重复状态，阻止同一调用链中的再次进入
	restart_button.disabled = true;#提供立即的界面反馈，并阻止玩家继续点击当前按钮
	restart_requested.emit();#只报告“希望再次启程”，由GameFlowController返回主菜单
