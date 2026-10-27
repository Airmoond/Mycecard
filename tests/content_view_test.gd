## 真实牌组和牌堆、重复实例、只读输入隔离、滚动布局与窗口生命周期。
extends SceneTree

var failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1
		push_error(message)

func card(id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % id)

func frames()->void:
	await process_frame
	await process_frame
	await process_frame

func same_cards(left:Array, right:Array)->bool:
	var counts:Dictionary = {}
	for value in left:
		counts[value.get_instance_id()] = counts.get(value.get_instance_id(), 0) + 1
	for value in right:
		var id:int = value.get_instance_id()
		if not counts.has(id) or counts[id] <= 0:
			return false
		counts[id] -= 1
	for count:int in counts.values():
		if count != 0:
			return false
	return true

func snapshot(state:BattleState)->Dictionary:
	var weapons:Array = []
	var costs:Array = []
	var cards:Array = state.draw_pile + state.hand + state.discard_pile + state.exhaust_pile + state.played_power_cards
	if state.equipped_weapon != null:
		cards.append(state.equipped_weapon)
	for instance:CardInstance in cards:
		costs.append([instance, instance.current_energy_cost])
		if instance.weapon != null:
			weapons.append([instance, instance.weapon.current_attack, instance.weapon.current_durability, instance.weapon.max_durability])
	return {
		"draw":state.draw_pile.duplicate(), "hand":state.hand.duplicate(),
		"discard":state.discard_pile.duplicate(), "exhaust":state.exhaust_pile.duplicate(),
		"powers":state.played_power_cards.duplicate(), "equipped":state.equipped_weapon,
		"phase":state.current_phase, "turn":state.current_turn_number,
		"energy":state.current_available_energy, "blocked":state.draw_blocked_this_turn,
		"health":state.player_state.current_health, "maximum":state.player_state.max_health,
		"block":state.player_state.current_block, "strength":state.player_state.strength,
		"enemy_health":state.enemy_state.current_health, "enemy_action":state.enemy_state.current_action,
		"weapon_attack":state.weapon_attack_available, "costs":costs, "weapons":weapons,
	}

func escape(inspector:CardInspector)->void:
	var event:InputEventKey = InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	inspector._unhandled_key_input(event)

func safe_encounter()->EncounterDefinition:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate()
	encounter.enemy_definition = encounter.enemy_definition.duplicate()
	encounter.enemy_definition.max_health = 10000
	encounter.energy_per_turn = 12 # 本测试多次出牌制造合法的各牌区，不修改正式资源。
	encounter.cards_per_turn = 8
	encounter.max_hand_size = 12
	var effect:CombatEffectDefinition = CombatEffectDefinition.new()
	effect.effect_type = CombatEffectDefinition.EffectType.BLOCK
	effect.amount = 1
	var action:EnemyActionDefinition = EnemyActionDefinition.new()
	action.action_id = "content_inspection_fixture"
	action.intent_text = "观察"
	action.effects = [effect]
	encounter.enemy_definition.action_pattern = [action]
	return encounter

func battle_deck()->Array[CardDefinition]:
	var definitions:Array[CardDefinition] = []
	for id in ["eternity", "ancient_ritual", "strength_power"]:
		var definition:CardDefinition = card(id).duplicate()
		definition.is_innate = true
		definitions.append(definition)
	for _i in range(5):
		definitions.append(card("strike"))
	for _i in range(4):
		definitions.append(card("defend"))
	return definitions

func _run()->void:
	await test_shared_view()
	await test_map()
	await test_battle()
	await frames()
	print("内容查看检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)

func test_shared_view()->void:
	var inspector:CardInspector = load("res://ui/inspect/card_inspector.tscn").instantiate()
	var definitions:Array[CardDefinition] = [card("strike"), card("eternity"), card("strike"), card("defend")]
	var original:Array[CardDefinition] = definitions.duplicate()
	expect(inspector.setup_definitions(definitions, "牌组"), "窗口可先设置再进入场景树")
	root.add_child(inspector)
	expect(inspector.title_label.text == "牌组：4张" and inspector.card_faces.size() == 4 and same_cards(inspector.displayed_definitions, definitions), "重复定义按张数完整展示")
	expect(definitions == original and inspector.displayed_definitions.is_read_only() and inspector.displayed_instances.is_empty(), "牌组只排序独立只读副本")
	var first:CardInstance = CardInstance.new()
	var second:CardInstance = CardInstance.new()
	first.card_instance_init(card("eternity"))
	second.card_instance_init(card("eternity"))
	first.set_current_energy_cost(0)
	first.weapon.enhance(4, 2)
	first.weapon.current_durability = 1
	second.set_current_energy_cost(2)
	var instances:Array[CardInstance] = [second, first]
	var order:Array[CardInstance] = instances.duplicate()
	expect(inspector.setup_instances(instances, "弃牌堆"), "支持同名武器不同实例")
	for index in range(2):
		var instance:CardInstance = inspector.displayed_instances[index]
		expect(inspector.card_faces[index].cost_label.text == str(instance.current_energy_cost), "每个实例显示自己的当前费用")
		if instance == first:
			expect(inspector.detail_labels[index].text.contains("攻击7") and inspector.detail_labels[index].text.contains("耐久1/5") and inspector.detail_labels[index].text.contains("攻击+4"), "强化与损耗武器显示当前攻击、耐久和强化")
	expect(instances == order and first.weapon.current_attack == 7 and first.weapon.current_durability == 1 and second.weapon.current_attack == 3 and card("eternity").base_energy_cost == 1, "查看没有改变实例或静态资源")
	var displayed_order:Array[CardInstance] = inspector.displayed_instances.duplicate()
	var reversed_order:Array[CardInstance] = [first, second]
	inspector.setup_instances(reversed_order, "抽牌堆")
	expect(inspector.displayed_instances == displayed_order and reversed_order == [first, second], "同名实例换位置不改变浏览排序，也不透露真实抽牌相对位置")
	var many:Array[CardDefinition] = []
	for _i in range(40):
		many.append(card("eternity"))
	inspector.setup_definitions(many, "牌组")
	for dimensions in [Vector2i(1024, 600), Vector2i(1920, 1080)]:
		root.size = dimensions
		await frames()
		expect(inspector.get_global_rect().encloses(inspector.close_button.get_global_rect()), "关闭按钮位于窗口内")
		expect(inspector.card_grid.size.x <= inspector.scroll_container.size.x + 1, "网格横向不裁切")
		expect(inspector.scroll_container.get_v_scroll_bar().max_value > inspector.scroll_container.get_v_scroll_bar().page, "大牌组可纵向滚动至后续卡牌")
		for label:Label in inspector.detail_labels:
			expect(label.get_line_count() * label.get_line_height() <= label.size.y + 1, "完整说明能换行并完整显示")
		inspector.scroll_container.scroll_vertical = 100000
		await frames()
		expect(inspector.scroll_container.get_global_rect().intersects(inspector.card_grid.get_child(39).get_global_rect()), "可以滚动到最后一张卡")
	var empty:Array[CardInstance] = []
	inspector.setup_instances(empty, "消耗牌堆")
	expect(inspector.title_label.text == "消耗牌堆：0张" and inspector.empty_label.visible and inspector.card_faces.is_empty(), "空牌堆标题零张且显示空态")
	escape(inspector)
	await frames()
	expect(not is_instance_valid(inspector), "Esc关闭并释放查看窗口")

func test_map()->void:
	root.size = Vector2i(1024, 600)
	var main:Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var flow:GameFlowController = main.get_node("game_flow_controller")
	flow.run_definition = load("res://tests/fixtures/phase5_run.tres");
	flow.current_page.start_requested.emit()
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit()
	var map:MapView = flow.current_page
	var state:RunState = flow.run_state
	var original:Array[CardDefinition] = state.owned_cards.duplicate()
	var encounters:Dictionary = state.node_encounters.duplicate()
	map.deck_button.pressed.emit()
	var inspector:CardInspector = map._card_inspector
	expect(inspector.title_label.text == "牌组：9张" and same_cards(inspector.displayed_definitions, original), "地图读取真实九牌组包括三张打击和三张防御")
	expect(map.collection_button.disabled and map.deck_button.disabled and map._node_views["start"].node_button.disabled, "牌组查看锁定所有地图入口")
	map._open_collection_inspector()
	map._open_deck_inspector()
	map._on_map_node_pressed("start")
	map.refresh_map()
	expect(map._card_inspector == inspector and not is_instance_valid(map._collection_inspector) and state.current_node_id.is_empty() and map._node_views["start"].node_button.disabled, "反复点击和地图刷新不叠窗、不解除输入锁定")
	expect(state.owned_cards == original and state.node_encounters == encounters and state.current_health == 50, "查看不加牌、扣血、重抽或推进")
	inspector.close_button.pressed.emit()
	# 同帧先关旧窗再开另一窗；已关闭页面的残余信号不能清除新窗。
	map.collection_button.pressed.emit()
	inspector.closed.emit()
	expect(is_instance_valid(map._collection_inspector) and map._has_inspector(), "关闭后快速打开藏品，旧窗口不会恢复背景输入")
	map._collection_inspector.close_button.pressed.emit()
	await frames()
	map._node_views["start"].node_button.pressed.emit()
	var choice:CollectionChoiceView = flow.current_page
	var fang:CollectionDefinition = load("res://collections/data/copper_fang.tres")
	choice.choice_buttons[choice.collection_options.find(fang)].pressed.emit()
	map = flow.current_page
	await frames()
	expect(map.collection_button.get_global_rect().end.x < map.deck_button.get_global_rect().position.x, "藏品按钮位于牌组左侧且不重叠")
	map._node_views["route_a_1"].node_button.pressed.emit()
	var controller:BattleController = flow.current_page.get_node("battle_controller")
	controller.battle_state.enemy_state.take_unblocked_damage(10000)
	controller._check_battle_result()
	var reward:RewardView = flow.current_page
	var gained:CardDefinition = reward._reward_card_views[0].card_definition
	reward._reward_card_views[0].pressed.emit()
	map = flow.current_page
	map.deck_button.pressed.emit()
	inspector = map._card_inspector
	expect(state.owned_cards.size() == 10 and inspector.title_label.text == "牌组：10张" and same_cards(inspector.displayed_definitions, state.owned_cards) and inspector.displayed_definitions.has(gained), "新奖励立即出现在完整牌组浏览中")
	for index in range(inspector.card_faces.size()):
		expect(inspector.card_faces[index].cost_label.text == str(inspector.displayed_definitions[index].base_energy_cost), "地图浏览始终显示基础费用")
	main.queue_free()
	await frames()
	expect(not is_instance_valid(inspector), "页面结束释放所属查看窗口")

func test_battle()->void:
	var page:Control = load("res://battle/battle.tscn").instantiate()
	root.add_child(page)
	var controller:BattleController = page.get_node("battle_controller")
	var definitions:Array[CardDefinition] = battle_deck()
	var fang:CollectionDefinition = load("res://collections/data/copper_fang.tres")
	expect(controller.start_battle(safe_encounter(), load("res://combatants/players/data/player.tres"), definitions, 50, 50, fang), "战斗浏览测试使用正式控制器启动")
	var state:BattleState = controller.battle_state
	# 先看真实空堆，再正常出牌制造弃牌、消耗、能力和装备区域。
	controller.exhaust_pile_label.pressed.emit()
	expect(controller._card_inspector.empty_label.visible and controller._card_inspector.title_label.text == "消耗牌堆：0张", "空堆也可以从数量入口查看")
	controller._card_inspector.close_button.pressed.emit()
	for id in ["eternity", "ancient_ritual", "strength_power"]:
		for instance:CardInstance in state.hand.duplicate():
			if instance.definition.card_id == id:
				controller._on_card_selected(instance)
	controller._on_card_selected(state.hand[0])
	expect(state.equipped_weapon != null and state.played_power_cards.size() == 1 and state.exhaust_pile.size() == 1 and state.discard_pile.size() == 1 and not state.is_invalid_battle(), "真实出牌后各牌区明确且守恒")
	state.draw_pile[0].set_current_energy_cost(0)
	state.draw_pile[1].set_current_energy_cost(2)
	state.prevent_draw_for_turn()
	controller._refresh_battle_view()
	var pile_buttons:Array[Button] = [controller.draw_pile_label, controller.discard_pile_label, controller.exhaust_pile_label]
	var piles:Array = [state.draw_pile, state.discard_pile, state.exhaust_pile]
	var titles:Array[String] = ["抽牌堆", "弃牌堆", "消耗牌堆"]
	for index in range(3):
		var before:Dictionary = snapshot(state)
		pile_buttons[index].pressed.emit()
		var inspector:CardInspector = controller._card_inspector
		expect(inspector != null and inspector.title_label.text == "%s：%d张" % [titles[index], piles[index].size()] and same_cards(inspector.displayed_instances, piles[index]), "指定牌堆展示所有实际实例，不混入其他牌区")
		for position in range(inspector.card_faces.size()):
			expect(inspector.card_faces[position].cost_label.text == str(inspector.displayed_instances[position].current_energy_cost), "战斗浏览显示实例当前费用")
		expect(controller.end_turn_button.disabled and controller.collection_button.disabled and pile_buttons[0].disabled and pile_buttons[1].disabled and pile_buttons[2].disabled, "任意查看窗口禁用结束回合、藏品及全部牌堆入口")
		controller._on_pile_button_pressed("draw")
		controller._on_collection_button_pressed()
		controller._on_card_selected(state.hand[0])
		controller._on_weapon_attack_requested()
		controller._on_end_turn_button_pressed()
		expect(controller._card_inspector == inspector and not controller._has_collection_inspector() and snapshot(state) == before, "直接背景handler也不能出牌、攻击或结束回合；查看本身不改顺序与资源")
		escape(inspector)
		await frames()
		expect(not controller._has_inspector() and not controller.draw_pile_label.disabled and not controller.end_turn_button.disabled and snapshot(state) == before, "关闭恢复同一回合；禁抽仍可再次浏览")
	controller.collection_button.pressed.emit()
	controller._on_pile_button_pressed("discard")
	expect(controller._has_collection_inspector() and not is_instance_valid(controller._card_inspector), "藏品窗口阻止同时打开牌堆")
	controller._collection_inspector.close_button.pressed.emit()
	state.draw_blocked_this_turn = false
	controller._on_end_turn_button_pressed()
	controller.discard_pile_label.pressed.emit()
	expect(same_cards(controller._card_inspector.displayed_instances, state.discard_pile), "回合、洗牌和抽牌后再查看读取最新牌堆")
	var old:CardInspector = controller._card_inspector
	expect(controller.start_battle(safe_encounter(), load("res://combatants/players/data/player.tres"), definitions, 40, 50), "同控制器重新开始战斗")
	expect(old.is_queued_for_deletion() and not controller._has_inspector(), "新战斗清除旧牌堆窗口")
	controller.exhaust_pile_label.pressed.emit()
	var current:CardInspector = controller._card_inspector
	old.closed.emit()
	expect(controller._card_inspector == current and controller.end_turn_button.disabled, "旧战斗查看信号不清除新窗口或恢复输入")
	current.close_button.pressed.emit()
	state = controller.battle_state
	for phase in [BattleState.BattlePhase.SETUP, BattleState.BattlePhase.ENEMY_TURN, BattleState.BattlePhase.FINISHED]:
		state.current_phase = phase
		controller._on_pile_button_pressed("draw")
		expect(not controller._has_inspector(), "非玩家回合与结束阶段不能打开窗口")
	state.current_phase = BattleState.BattlePhase.PLAYER_TURN
	state.resolving_card = state.hand[0]
	controller._on_pile_button_pressed("draw")
	expect(not controller._has_inspector(), "卡牌结算中不能浏览")
	state.resolving_card = null
	controller.draw_pile_label.pressed.emit()
	current = controller._card_inspector
	state.enemy_state.take_unblocked_damage(10000)
	controller._check_battle_result()
	expect(current.is_queued_for_deletion() and not controller._has_inspector() and controller.draw_pile_label.disabled and controller.exhaust_pile_label.disabled, "战斗结束自动释放查看窗口并关闭入口")
	page.queue_free()
	await frames()
