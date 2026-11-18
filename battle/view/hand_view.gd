## 按CardInstance身份维护手牌控件，刷新不销毁仍在手里的牌。
class_name HandView
extends HBoxContainer

signal card_selected(card:CardInstance)
signal weapon_attack_requested

const CARD_SCENE:PackedScene = preload("res://cards/card_view.tscn")
const WEAPON_SCENE:PackedScene = preload("res://battle/weapons/weapon_attack_view.tscn")
## 以卡牌实例标识为键的手牌控件表，用于跨刷新保留同一张牌的控件。
var _cards:Dictionary = {}
## 各卡牌上次显示的定义、费用、描述和可用状态，避免重复刷新未变化内容。
var _display_keys:Dictionary = {}
## 当前可用的武器攻击按钮；不可攻击时移除并清除引用。
var _weapon_button:Button
## 手牌悬停预览共用的浮层服务。
var _overlay:OverlayHost

## 保存共享浮层服务，并为现有手牌控件更新悬停预览的挂载服务。
func configure_overlay(host:OverlayHost)->void:
	_overlay = host
	for view:CardView in _cards.values():
		view.set_overlay_host(host)

## 按会话手牌的实例身份复用控件，只更新变化的显示内容，并同步武器攻击按钮与尺寸。
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

## 断开输入连接并移除所有手牌和武器按钮，清空实例及显示缓存。
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

## 返回指定卡牌实例对应的手牌控件；卡牌为空或尚无控件时为 [code]null[/code]。
func card_view(card:CardInstance)->CardView:
	return _cards.get(card.get_instance_id()) if card != null else null

## 返回出牌动画所需的独立卡面及全局矩形；找不到手牌控件时快照为 [code]null[/code]。
func prepare_snapshot(card:CardInstance)->Dictionary:
	var view:CardView = card_view(card)
	if not is_instance_valid(view):
		return {"snapshot": null, "rect": get_global_rect()}
	return {"snapshot": view.make_play_snapshot(), "rect": view.get_global_rect()}

## 扣除武器按钮与间距后按可用宽度等比调整手牌尺寸，不超过卡面的基础宽度。
func fit_cards()->void:
	if _cards.is_empty():
		return
	var extras:float = _weapon_button.get_combined_minimum_size().x if is_instance_valid(_weapon_button) else 0.0
	var spacing:int = get_theme_constant("separation")
	var room:float = size.x - extras - spacing * maxi(0, get_child_count() - 1)
	var width:float = minf(CardFace.BASE_SIZE.x, room / _cards.size())
	for card:CardView in _cards.values():
		card.set_display_size(Vector2(width, CardFace.BASE_SIZE.y * width / CardFace.BASE_SIZE.x))

## 转发手牌控件选中的实例，不执行出牌操作。
func _on_card_selected(card:CardInstance)->void:
	card_selected.emit(card)

## 发出武器攻击意图，由外部控制器决定是否执行。
func _on_weapon_attack()->void:
	weapon_attack_requested.emit()
