## 按CardInstance身份维护手牌控件，刷新不销毁仍在手里的牌。
class_name HandView
extends HBoxContainer

signal card_selected(card:CardInstance)
signal weapon_attack_requested

const CARD_SCENE:PackedScene = preload("res://cards/card_view.tscn")
const WEAPON_SCENE:PackedScene = preload("res://battle/weapons/weapon_attack_view.tscn")
var _cards:Dictionary = {}
var _display_keys:Dictionary = {}
var _weapon_button:Button
var _overlay:OverlayHost

func configure_overlay(host:OverlayHost)->void:
	_overlay = host
	for view:CardView in _cards.values():
		view.set_overlay_host(host)

func render(session:BattleSession, input_blocked:bool)->void:
	var retained:Dictionary = {}
	for card:CardInstance in session.battle_state.hand:
		var identity:int = card.get_instance_id()
		retained[identity] = true
		var view:CardView = _cards.get(identity)
		if not is_instance_valid(view):
			view = CARD_SCENE.instantiate()
			add_child(view)
			view.bind_card_instance(card)
			view.set_overlay_host(_overlay)
			view.card_selected.connect(_on_card_selected)
			_cards[identity] = view
		move_child(view, retained.size() - 1)
		var description:String = session.card_description(card)
		var playable:bool = not input_blocked and session.can_play_card(card)
		var key:Array = [card.definition.get_instance_id(), card.current_energy_cost, description, playable]
		if _display_keys.get(identity) != key:
			view.refresh_card_view()
			view.set_description(description)
			view.set_playable_visual(playable)
			_display_keys[identity] = key
	for identity:int in _cards.keys():
		if not retained.has(identity):
			var removed:CardView = _cards[identity]
			if removed.card_selected.is_connected(_on_card_selected):
				removed.card_selected.disconnect(_on_card_selected)
			remove_child(removed)
			removed.queue_free()
			_cards.erase(identity)
			_display_keys.erase(identity)
	if session.can_attack_with_weapon():
		if not is_instance_valid(_weapon_button):
			_weapon_button = WEAPON_SCENE.instantiate()
			add_child(_weapon_button)
			_weapon_button.pressed.connect(_on_weapon_attack)
		move_child(_weapon_button, get_child_count() - 1)
		_weapon_button.tooltip_text = session.weapon_attack_tooltip()
		_weapon_button.disabled = input_blocked
	elif is_instance_valid(_weapon_button):
		if _weapon_button.pressed.is_connected(_on_weapon_attack):
			_weapon_button.pressed.disconnect(_on_weapon_attack)
		remove_child(_weapon_button)
		_weapon_button.queue_free()
		_weapon_button = null
	fit_cards()

func clear()->void:
	for child:Node in get_children():
		if child is CardView and child.card_selected.is_connected(_on_card_selected):
			child.card_selected.disconnect(_on_card_selected)
		elif child == _weapon_button and _weapon_button.pressed.is_connected(_on_weapon_attack):
			_weapon_button.pressed.disconnect(_on_weapon_attack)
		remove_child(child)
		child.queue_free()
	_cards.clear()
	_display_keys.clear()
	_weapon_button = null

func card_view(card:CardInstance)->CardView:
	return _cards.get(card.get_instance_id()) if card != null else null

func prepare_snapshot(card:CardInstance)->Dictionary:
	var view:CardView = card_view(card)
	if not is_instance_valid(view):
		return {"snapshot": null, "rect": get_global_rect()}
	return {"snapshot": view.make_play_snapshot(), "rect": view.get_global_rect()}

func fit_cards()->void:
	if _cards.is_empty():
		return
	var extras:float = _weapon_button.get_combined_minimum_size().x if is_instance_valid(_weapon_button) else 0.0
	var spacing:int = get_theme_constant("separation")
	var room:float = size.x - extras - spacing * maxi(0, get_child_count() - 1)
	var width:float = minf(CardFace.BASE_SIZE.x, room / _cards.size())
	for card:CardView in _cards.values():
		card.set_display_size(Vector2(width, CardFace.BASE_SIZE.y * width / CardFace.BASE_SIZE.x))

func _on_card_selected(card:CardInstance)->void:
	card_selected.emit(card)

func _on_weapon_attack()->void:
	weapon_attack_requested.emit()
