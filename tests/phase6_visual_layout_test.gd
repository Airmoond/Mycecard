## 实际布局验证：十张手牌、武器入口、稳定悬停输入区和独立出牌快照。
extends SceneTree

var failures:int = 0

func _initialize()->void:
	run.call_deferred()

func expect(value:bool, message:String)->void:
	if not value:
		failures += 1
		push_error(message)

func frames()->void:
	for index in range(4):
		await process_frame

func run()->void:
	# 不进入场景树，检查编辑器读取的保存布局，不依赖运行时适配。
	var preview:Control = load("res://battle/battle.tscn").instantiate()
	var preview_size:Vector2 = Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	var preview_stage:Control = preview.get_node("main_layout")
	expect(preview.clip_contents, "编辑器预览裁剪画布外的桌面装饰")
	expect(preview_stage.scale.is_equal_approx(Vector2.ONE * (2.0 / 3.0)), "保存舞台缩放与1280×720预览一致")
	expect((preview_stage.size * preview_stage.scale).is_equal_approx(preview_size), "未运行脚本时舞台尺寸与项目视口一致")
	preview.free()
	for window_size:Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		root.size = window_size
		var page:Control = load("res://battle/battle.tscn").instantiate()
		root.add_child(page)
		var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate()
		encounter.cards_per_turn = 10
		var deck:Array[CardDefinition] = []
		for index in range(9):
			deck.append(load("res://cards/data/strike.tres"))
		deck.append(load("res://cards/data/eternity.tres"))
		var controller:BattleController = page.get_node("battle_controller")
		expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), deck, 50, 50), "十牌布局战斗可启动")
		await frames()
		var hand_rect:Rect2 = controller.hand_area.get_global_rect()
		var page_rect:Rect2 = page.get_global_rect()
		expect(controller.battle_state.hand.size() == 10, "十牌起手完整")
		var weapon_card:CardView
		for child in controller.hand_area.get_children():
			if child is CardView:
				expect(page_rect.encloses(child.get_global_rect()) and hand_rect.encloses(child.get_global_rect()), "十张手牌占位均在战场和手牌区域内")
				var description:CardDescriptionLabel = child.card_face.description_label
				expect(description.get_content_height() <= description.size.y, "十牌缩放仍完整显示规则")
				if child.card_instance.definition.card_id == "eternity":
					weapon_card = child
		expect(weapon_card != null, "武器卡仍可定位")
		var original_rect:Rect2 = weapon_card.get_global_rect()
		weapon_card._set_hovered(true)
		await create_timer(0.16).timeout
		expect(weapon_card.get_global_rect() == original_rect, "悬停只移动视觉卡面，输入占位稳定")
		expect(weapon_card._hover_preview != null and Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(weapon_card._hover_preview.get_global_rect()), "悬停大卡阅读层位于可见窗口内")
		expect(weapon_card._hover_preview.description_label.text == weapon_card.card_face.description_label.text and weapon_card._hover_preview.description_label.get_content_height() <= weapon_card._hover_preview.description_label.size.y, "大卡阅读层保留实际规则并完整排版")
		expect(weapon_card._hover_preview.description_label.get_theme_font_size("normal_font_size") >= 12, "最小窗口仍有可读的长规则字号")
		var snapshot:Control = weapon_card.make_play_snapshot()
		root.add_child(snapshot)
		expect((snapshot as CardFace).cost_label.text == "1" and (snapshot as CardFace).description_label.text == weapon_card.card_face.description_label.text, "独立出牌快照保留费用和完整规则")
		snapshot.queue_free()
		controller._on_card_selected(weapon_card.card_instance)
		await frames()
		for child in controller.hand_area.get_children():
			if child is Control:
				expect(page_rect.encloses(child.get_global_rect()), "九张手牌加武器攻击按钮仍在战场内")
		expect(not controller.end_turn_button.get_global_rect().intersects(controller.hand_area.get_global_rect()), "结束回合按钮与手牌区域不重叠")
		expect(not controller.weapon_label.get_global_rect().intersects(controller.energy_label.get_global_rect()), "武器与能量信息不重叠")
		page.queue_free()
		await frames()
	print("第六阶段卡面与战斗布局检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)
