## 将页面操作交给独立BattleSession，连接显示与实际反馈。
## 旧公开启动/结果接口和测试入口继续转发，规则仅由Session实现。
class_name BattleController
extends Node

signal battle_finished(victory:bool, remaining_player_health:int, remaining_player_max_health:int)
var session:BattleSession
var presentation:BattlePresentation
var _battle_result_reported:bool = false
var _battle_id:String = ""
var _node_id:String = ""
var _rng:RandomNumberGenerator
var _executing:bool = false
var _events:Array[BattleEvent] = []
@onready var battle_view:BattleView = get_parent() as BattleView

var battle_state:BattleState:
	get: return session.battle_state if session != null else null
var action_queue:ActionQueue:
	get: return session.action_queue if session != null else null
var selected_collection:CollectionDefinition:
	get: return session.selected_collection if session != null else null
var player_view:CombatantView:
	get: return battle_view.player_view
var enemy_view:CombatantView:
	get: return battle_view.enemy_view
var energy_label:Label:
	get: return battle_view.energy_label
var draw_pile_label:Button:
	get: return battle_view.draw_pile_label
var discard_pile_label:Button:
	get: return battle_view.discard_pile_label
var exhaust_pile_label:Button:
	get: return battle_view.exhaust_pile_label
var weapon_label:Label:
	get: return battle_view.weapon_label
var hand_area:HandView:
	get: return battle_view.hand_area
var end_turn_button:Button:
	get: return battle_view.end_turn_button
var collection_button:Button:
	get: return battle_view.collection_button
var _collection_inspector:CollectionInspector:
	get: return battle_view._collection_inspector
var _card_inspector:CardInspector:
	get: return battle_view._card_inspector

func _ready()->void:
	presentation = BattlePresentation.new()
	add_child(presentation)
	battle_view.card_selected.connect(_on_card_selected)
	battle_view.weapon_attack_requested.connect(_on_weapon_attack_requested)
	battle_view.end_turn_requested.connect(_on_end_turn_button_pressed)
	battle_view.ui_feedback.connect(presentation.play_feedback)

func configure_context(battle_id:String, node_id:String, rng:RandomNumberGenerator = null)->void:
	_battle_id = battle_id
	_node_id = node_id
	_rng = rng

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

func start_battle(encounter:EncounterDefinition, player:CombatantDefinition, deck:Array[CardDefinition], health:int, max_health:int, collection:CollectionDefinition = null)->bool:
	return prepare_battle(encounter, player, deck, health, max_health, collection) and activate_battle()

func get_battle_session()->BattleSession:
	return session

func get_battle_result()->BattleResult:
	return session.get_result() if session != null else null

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

func _on_weapon_attack_requested()->void:
	if not is_inside_tree() or session == null or _has_inspector():
		return
	_executing = true
	session.attack_with_weapon()
	_executing = false
	_flush_actual_results()
	_refresh_battle_view()

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

func _on_actual_result(event:BattleEvent)->void:
	if _battle_result_reported:
		return
	if _executing:
		_events.append(event)
	else:
		_present_actual_result(event)

func _flush_actual_results()->void:
	for event:BattleEvent in _events:
		_present_actual_result(event)
	_events.clear()

func _present_actual_result(event:BattleEvent)->void:
	var anchor:Control
	match event.target_id:
		&"player": anchor = player_view
		&"enemy": anchor = enemy_view
		&"energy": anchor = energy_label
		_: anchor = weapon_label
	presentation.present_event(event, anchor.get_global_rect())

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

func _check_battle_result()->bool:
	if session == null:
		return false
	var finished:bool = session.check_battle_result()
	_refresh_battle_view()
	return finished

func _card_is_playable(card:CardInstance)->bool:
	return session != null and not _has_inspector() and session.can_play_card(card)

func _meets_effect_requirements(card:CardInstance)->bool:
	return session != null and session._meets_effect_requirements(card)

func _queue_card_effect(card:CardInstance)->bool:
	return session._queue_card_effect(card)

## 旧回归入口；Session仍校验阶段，不能重复开始已在进行的玩家回合。
func _start_player_turn()->void:
	if session != null and session.is_active():
		session._start_player_turn()
		_refresh_battle_view()

func _build_enemy_intent_text(_action:EnemyActionDefinition)->String:
	return session.enemy_intent_text()

func _has_inspector()->bool:
	return battle_view.input_is_blocked()

func _has_collection_inspector()->bool:
	return battle_view._has_collection_inspector()

func _can_inspect()->bool:
	return battle_view._can_inspect()

func _can_inspect_collection()->bool:
	return battle_view._can_inspect_collection()

func _on_collection_button_pressed()->void:
	battle_view._on_collection_button_pressed()

func _on_pile_button_pressed(pile_name:String)->void:
	battle_view._on_pile_button_pressed(pile_name)

func _exit_tree()->void:
	if session != null:
		session.dispose()
