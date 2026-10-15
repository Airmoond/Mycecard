## 手牌增量更新：重复卡实例、稳定节点/连接、动态预览、残影与重开隔离。
extends SceneTree

var _failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func _expect(value:bool, message:String)->void:
	if not value:
		_failures += 1
		push_error(message)

func _frames()->void:
	for _frame in range(3):
		await process_frame

func _run()->void:
	for window_size:Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(1024, 600)]:
		root.size = window_size
		await _test_window()
	if _failures == 0:
		print("HandView生命周期检查通过")
	else:
		print("HandView生命周期检查失败：%d" % _failures)
	quit(0 if _failures == 0 else 1)

func _test_window()->void:
	var page:BattleView = load("res://battle/battle.tscn").instantiate()
	root.add_child(page)
	var controller:BattleController = page.get_controller()
	controller.presentation.enabled = false
	var encounter:EncounterDefinition = load("res://battle/data/encounters/cave_crawler_encounter.tres").duplicate()
	encounter.cards_per_turn = 10
	var strike:CardDefinition = load("res://cards/data/strike.tres")
	var weapon_definition:CardDefinition = load("res://cards/data/eternity.tres")
	var deck:Array[CardDefinition] = []
	for _index in range(9):
		deck.append(strike)
	deck.append(weapon_definition)
	_expect(controller.start_battle(encounter, load("res://combatants/data/player.tres"), deck, 50, 50), "十牌战斗启动")
	await _frames()
	var state:BattleState = controller.battle_state
	var hand:HandView = controller.hand_area
	var ids:Dictionary = {}
	var weapon:CardInstance
	var sample:CardInstance
	for card:CardInstance in state.hand:
		var view:CardView = hand.card_view(card)
		ids[card.get_instance_id()] = view.get_instance_id()
		_expect(view.card_selected.get_connections().size() == 1, "每张重复卡实例独立控件且只有一个输入连接")
		_expect(page.get_global_rect().encloses(view.get_global_rect()) and hand.get_global_rect().encloses(view.get_global_rect()), "十张牌均位于窗口和手牌区内")
		if card.definition == weapon_definition:
			weapon = card
		else:
			sample = card
	var sample_view:CardView = hand.card_view(sample)
	var sample_rect:Rect2 = sample_view.get_global_rect()
	sample_view._set_hovered(true)
	await create_timer(0.16).timeout
	var hover:CardFace = sample_view._hover_preview
	_expect(hover != null and Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(hover.get_global_rect()), "最小窗口悬停完整可读")
	controller._refresh_battle_view()
	_expect(hand.card_view(sample) == sample_view and sample_view._hover_preview == hover and sample_view.get_global_rect() == sample_rect, "无状态变化刷新保留悬停与稳定输入区域")
	state.player_state.gain_strength(2)
	state.current_available_energy = 0
	controller._refresh_battle_view()
	_expect(sample_view.card_face.description_label.text == "造成8点伤害" and sample_view.modulate == CardView.UNPLAYABLE_MODULATE, "复用节点刷新动态伤害与合法性")
	_expect(sample_view._hover_preview == hover and hover.description_label.text == "造成8点伤害", "状态变化更新既有悬停而不重建")
	for card:CardInstance in state.hand:
		_expect(hand.card_view(card).get_instance_id() == ids[card.get_instance_id()], "手牌状态变化不释放仍存在的控件")
	sample.set_current_energy_cost(0)
	controller._refresh_battle_view()
	_expect(sample_view.card_face.cost_label.text == "0" and sample_view.modulate == CardView.PLAYABLE_MODULATE, "实际实例费用变更通过同一查询更新")
	var snapshot:CardFace = sample_view.make_play_snapshot()
	root.add_child(snapshot)
	controller._on_card_selected(sample)
	_expect(not state.hand.has(sample) and hand.card_view(sample) == null, "已打出实例立即移除自身控件")
	await _frames()
	_expect(not is_instance_valid(sample_view) and is_instance_valid(snapshot), "旧卡释放不影响独立快照")
	_expect(snapshot.cost_label.text == "0" and snapshot.description_label.text == "造成8点伤害", "快照保留命令前实际费用和动态规则")
	snapshot.queue_free()
	for card:CardInstance in state.hand:
		_expect(hand.card_view(card).get_instance_id() == ids[card.get_instance_id()], "出牌只移除一张，同名其他实例保持身份")
	state.current_available_energy = 3
	controller._on_card_selected(weapon)
	await _frames()
	var attack:Button = hand.get_node_or_null("weapon_attack")
	_expect(attack != null and hand.get_child_count() == state.hand.size() + 1, "武器入口独立于CardInstance数量")
	controller._refresh_battle_view()
	_expect(attack == hand.get_node_or_null("weapon_attack") and attack.pressed.get_connections().size() == 1, "可用武器入口刷新保留节点且不重复连接")
	controller._on_weapon_attack_requested()
	controller._on_end_turn_button_pressed()
	var health_before:int = state.enemy_state.current_health
	attack.pressed.emit()
	_expect(state.enemy_state.current_health == health_before and state.weapon_attack_available and attack.pressed.get_connections().is_empty(), "上一回合武器按钮的迟到信号不能消耗新回合攻击机会")
	var remaining:CardInstance = state.hand[0]
	var old_view:CardView = hand.card_view(remaining)
	_expect(controller.start_battle(encounter, load("res://combatants/data/player.tres"), [strike], 50, 50), "重开使用新的会话和牌实例")
	var new_state:BattleState = controller.battle_state
	old_view.card_selected.emit(remaining)
	_expect(new_state.enemy_state.current_health == 30 and new_state.hand.size() == 1 and old_view.card_selected.get_connections().is_empty(), "旧牌节点迟到点击不影响新战斗")
	await _frames()
	_expect(not is_instance_valid(old_view) and hand.get_child_count() == 1 and hand.card_view(new_state.hand[0]) != null, "重开清理旧手牌及武器入口")
	page.queue_free()
	await _frames()
