## 单场独立装饰层：只使用位置与文字快照，不保留旧手牌或角色节点，不决定规则。
class_name BattlePresentation
extends Node

var enabled:bool = true
var session_id:String = ""
var observed_results:Array[Dictionary] = []
var _sequence:int = 0
var _session_number:int = 0
var _layer:CanvasLayer
var _surface:Control
var _audio:GameAudioManager
var _overlay_host:OverlayHost

func _ready()->void:
	session_id = "battle_%d" % get_instance_id()
	_layer = CanvasLayer.new()
	_layer.name = "battle_feedback_layer"
	_layer.layer = OverlayHost.LAYER_BATTLE_FEEDBACK
	add_child(_layer)
	_surface = Control.new()
	_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_surface)
	if _audio == null:
		_audio = get_tree().get_first_node_in_group("game_audio") as GameAudioManager
	begin_session()

## 同一控制器重新建立战斗时立即撤销上一场的装饰，旧效果不漂到新战斗。
func begin_session()->void:
	_session_number += 1
	session_id = "battle_%d_%d" % [get_instance_id(), _session_number]
	_sequence = 0
	observed_results.clear()
	for child:Node in _surface.get_children():
		child.free()

## 每个效果结果有独立顺序标识，同一复合行为的失血、治疗、格挡分别报告。
func present_result(kind:StringName, amount:int, rect:Rect2)->void:
	_sequence += 1
	var event_id:String = "%s:%d:%s" % [session_id, _sequence, kind]
	observed_results.append({"kind":kind, "amount":amount, "event_id":event_id})
	if observed_results.size() > 128:
		observed_results.pop_front()
	if not enabled:
		return
	var sound:StringName = kind
	if kind in [&"energy", &"weapon_equip", &"weapon_attack", &"health_loss"]:
		sound = &""
	if is_instance_valid(_audio) and not sound.is_empty():
		_audio.play_sfx(sound, event_id)
	if amount == 0 or rect.size == Vector2.ZERO:
		return
	var color:Color = Color("f5cb78")
	var text:String = ""
	match kind:
		&"strike_hit", &"health_loss":
			color = Color("fba290")
			text = "−%d" % amount
		&"block_hit":
			color = Color("c2e7ff")
			text = "格挡 −%d" % amount
		&"block_gain":
			color = Color("9ce0f7")
			text = "格挡 +%d" % amount
		&"heal_gain":
			color = Color("b7e5ad")
			text = "+%d" % amount
		&"energy":
			color = Color("92d8ff")
			text = "能量 %s%d" % ["+" if amount > 0 else "", amount]
		&"weapon_break":
			text = "武器损坏"
		&"weapon_equip":
			text = "装备武器"
		&"weapon_attack":
			text = "武器攻击"
		_:
			return
	_float_text(text, color, rect)
	_flash(rect, color)

## 展示消费模型逐段实际事件，并保留来源用于验证与问题定位。
func present_event(event:BattleEvent, rect:Rect2)->void:
	present_result(event.kind, event.amount, rect)
	if not observed_results.is_empty():
		observed_results[-1].merge({"battle_id":event.battle_id, "sequence":event.sequence, "source_id":event.source_id, "target_id":event.target_id})

func play_feedback(sound_id:StringName)->void:
	_sequence += 1
	if enabled and is_instance_valid(_audio):
		_audio.play_sfx(sound_id, "%s:%d:%s" % [session_id, _sequence, sound_id])

func reject(reason:String, rect:Rect2)->void:
	play_feedback(&"ui_invalid")
	if enabled:
		_float_text(reason, Color("e3b897"), rect)

## 已接受出牌的独立卡面残影；原CardView可在同步刷新中立即释放。
func animate_card(snapshot:Control, start_rect:Rect2, target_rect:Rect2)->void:
	play_feedback(&"card_play")
	if snapshot == null:
		return
	if not enabled:
		snapshot.free()
		return
	_surface.add_child(snapshot)
	snapshot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if snapshot is CardFace:
		snapshot.set_display_size(start_rect.size)
	snapshot.position = start_rect.position
	snapshot.size = start_rect.size
	snapshot.pivot_offset = snapshot.size * 0.5
	var tween:Tween = snapshot.create_tween().set_parallel(true)
	tween.tween_property(snapshot, "position", target_rect.get_center() - start_rect.size * 0.5, 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(snapshot, "scale", Vector2(0.35, 0.35), 0.24)
	tween.tween_property(snapshot, "modulate:a", 0.0, 0.24)
	tween.chain().tween_callback(snapshot.queue_free)

func _float_text(text:String, color:Color, rect:Rect2)->void:
	var label:Label = Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color("20180fee"))
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_font_size_override("font_size", 24)
	label.position = rect.get_center() - Vector2(130, 36) + Vector2(0, (_sequence % 3) * 17)
	label.size = Vector2(260, 55)
	_surface.add_child(label)
	var tween:Tween = label.create_tween().set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 35, 0.52)
	tween.tween_property(label, "modulate:a", 0.0, 0.52).set_delay(0.1)
	tween.chain().tween_callback(label.queue_free)

func _flash(rect:Rect2, color:Color)->void:
	var panel:Panel = Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.position = rect.position
	panel.size = rect.size
	var style:StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(color, 0.11)
	style.border_color = Color(color, 0.65)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	_surface.add_child(panel)
	var tween:Tween = panel.create_tween()
	tween.tween_property(panel, "modulate:a", 0.0, 0.18)
	tween.tween_callback(panel.queue_free)

## 应用浮层拥有跨页短提示，战斗页面不持有其生命周期。
func configure_services(audio:GameAudioManager, host:OverlayHost)->void:
	_audio = audio
	_overlay_host = host

func finish(victory:bool)->void:
	play_feedback(&"victory" if victory else &"defeat")
	if enabled and is_instance_valid(_overlay_host):
		_overlay_host.show_terminal(victory)
