## 将页面操作交给独立BattleSession，连接显示与实际反馈。
class_name BattleController
extends Node

signal battle_finished(victory:bool, remaining_player_health:int, remaining_player_max_health:int)
## 当前控制器持有的战斗规则会话，准备成功后才替换旧会话。
var session:BattleSession
## 负责本场动画、音效和实际结果反馈的表现节点。
var presentation:BattlePresentation
## 是否已向流程层报告本场结果，防止重复结算通知。
var _battle_result_reported:bool = false
## 下一次准备战斗时传入会话的唯一战斗标识。
var _battle_id:String = ""
## 下一次准备战斗时传入会话的所属地图节点标识。
var _node_id:String = ""
## 下一次战斗使用的随机源；为空时沿用会话自行创建的随机源。
var _rng:RandomNumberGenerator
## 是否正在同步执行规则命令；期间的表现事件先进入缓存。
var _executing:bool = false
## 当前命令执行期间产生、尚未展示的实际事件，按发生顺序保存。
var _events:Array[BattleEvent] = []
## 拥有此控制器的战斗视图。
@onready var battle_view:BattleView = get_parent() as BattleView

## 当前会话的战斗状态；尚未准备会话时为 [code]null[/code]。
var battle_state:BattleState:
	get: return session.battle_state if session != null else null
## 转发战斗视图的玩家控件引用，供表现及既有调用者定位。
var player_view:CombatantView:
	get: return battle_view.player_view
## 转发战斗视图的敌人控件引用，供表现及既有调用者定位。
var enemy_view:CombatantView:
	get: return battle_view.enemy_view
## 战斗视图的能量显示控件，也是能量事件的表现锚点。
var energy_label:Label:
	get: return battle_view.energy_label
## 战斗视图的装备信息控件，也是武器事件的表现锚点。
var weapon_label:Label:
	get: return battle_view.weapon_label
## 战斗视图持有的增量手牌组件，控制器通过它制作独立出牌快照。
var hand_area:HandView:
	get: return battle_view.hand_area
## 创建战斗表现节点，并将视图的操作意图与界面反馈连接到对应处理方法。
func _ready()->void:
	presentation = BattlePresentation.new()
	add_child(presentation)
	battle_view.card_selected.connect(_on_card_selected)
	battle_view.weapon_attack_requested.connect(_on_weapon_attack_requested)
	battle_view.end_turn_requested.connect(_on_end_turn_button_pressed)
	battle_view.ui_feedback.connect(presentation.play_feedback)

## 保存战斗身份、所属地图节点和可选随机源，供下一次准备战斗使用。
func configure_context(battle_id:String, node_id:String, rng:RandomNumberGenerator = null)->void:
	_battle_id = battle_id
	_node_id = node_id
	_rng = rng

## 为战斗视图和表现层设置共享音频及浮层服务。
func configure_services(audio:GameAudioManager, overlay:OverlayHost)->void:
	battle_view.configure_overlay(overlay)
	presentation.configure_services(audio, overlay)

## 未提交的页面只构建SETUP状态；不抽牌、推进回合或播放进入反馈。
func prepare_battle(encounter:EncounterDefinition, player:CombatantDefinition, deck:Array[CardDefinition], health:int, max_health:int, collection:CollectionDefinition = null)->bool:
	if not is_node_ready() or not is_instance_valid(battle_view):
		push_error("BattleController尚未准备完成，无法开始战斗")
		return false
	var prepared:BattleSession = BattleSession.new()
	prepared.configure_context(_battle_id, _node_id, _rng)
	if not prepared.prepare(encounter, player, deck, health, max_health, collection):
		return false
	if session != null:
		session.dispose()
	session = prepared
	session.actual_result.connect(_on_actual_result)
	_battle_result_reported = false
	_events.clear()
	battle_view.bind_session(session)
	return true

## 激活已准备但尚未开始的会话，展示首回合实际结果并刷新视图。
##
## 缺少会话或会话已经激活时返回 [code]false[/code]。
func activate_battle()->bool:
	if session == null or session.is_active():
		return false
	presentation.begin_session()
	_executing = true
	var accepted:bool = session.activate()
	_executing = false
	_flush_actual_results()
	_refresh_battle_view()
	return accepted

## 依次准备并激活战斗，返回两步是否均成功；准备失败时不激活会话。
func start_battle(encounter:EncounterDefinition, player:CombatantDefinition, deck:Array[CardDefinition], health:int, max_health:int, collection:CollectionDefinition = null)->bool:
	return prepare_battle(encounter, player, deck, health, max_health, collection) and activate_battle()

## 返回当前会话已生成的结果；没有会话或战斗尚未结束时为 [code]null[/code]。
func get_battle_result()->BattleResult:
	return session.get_result() if session != null else null

## 验证出牌请求并提前制作卡面快照；接受后播放出牌动画，再展示实际结果和刷新状态。
func _on_card_selected(card:CardInstance)->void:
	if not is_inside_tree() or session == null or _has_inspector():
		return
	var failure:StringName = session.card_play_failure(card)
	if failure != &"":
		if failure in [&"not_enough_energy", &"no_weapon", &"max_health_cost"]:
			presentation.reject(BattleDisplay.failure_text(failure), hand_area.get_global_rect())
		return
	# 独立快照在规则命令之前准备，接受后才进入表现层。
	var prepared:Dictionary = hand_area.prepare_snapshot(card)
	_executing = true
	var accepted:bool = session.play_card(card)
	_executing = false
	if accepted:
		var destination:Control = enemy_view if card.definition.card_type == CardDefinition.CardType.ATTACK else player_view
		presentation.animate_card(prepared.snapshot, prepared.rect, destination.get_global_rect())
	elif prepared.snapshot != null:
		prepared.snapshot.free()
	_flush_actual_results()
	_refresh_battle_view()

## 在页面有效且输入未被浮层阻挡时提交武器攻击，再展示实际结果并刷新视图。
func _on_weapon_attack_requested()->void:
	if not is_inside_tree() or session == null or _has_inspector():
		return
	_executing = true
	session.attack_with_weapon()
	_executing = false
	_flush_actual_results()
	_refresh_battle_view()

## 提交结束回合请求；可结束时播放反馈，并在同步结算后刷新战斗显示。
func _on_end_turn_button_pressed()->void:
	if not is_inside_tree() or session == null or _has_inspector():
		return
	if session.can_end_turn():
		presentation.play_feedback(&"end_turn")
	_executing = true
	session.end_turn()
	_executing = false
	_flush_actual_results()
	_refresh_battle_view()

## 接收模型的实际事件；命令执行中先缓存，其他时间立即交给表现层。
func _on_actual_result(event:BattleEvent)->void:
	if _battle_result_reported:
		return
	if _executing:
		_events.append(event)
	else:
		_present_actual_result(event)

## 按接收顺序展示缓存的实际事件，然后清空缓存。
func _flush_actual_results()->void:
	for event:BattleEvent in _events:
		_present_actual_result(event)
	_events.clear()

## 按事件目标选择角色、能量或武器的显示区域，并交给表现层展示。
func _present_actual_result(event:BattleEvent)->void:
	var anchor:Control
	match event.target_id:
		&"player": anchor = player_view
		&"enemy": anchor = enemy_view
		&"energy": anchor = energy_label
		_: anchor = weapon_label
	presentation.present_event(event, anchor.get_global_rect())

## 刷新战斗显示；首次发现结果时关闭查看器、播放终局反馈并发出结束信号。
func _refresh_battle_view()->void:
	if session == null:
		return
	var result:BattleResult = session.get_result()
	if result != null:
		battle_view._clear_inspectors()
	battle_view.render()
	if result == null or _battle_result_reported:
		return
	_battle_result_reported = true
	presentation.finish(result.victory)
	battle_finished.emit(result.victory, result.player_health, result.player_max_health)

## 返回战斗视图是否因查看器或共享模态窗口而阻挡输入。
func _has_inspector()->bool:
	return battle_view.input_is_blocked()

## 退出场景树时释放当前会话的事件连接并停止接受战斗命令。
func _exit_tree()->void:
	if session != null:
		session.dispose()
