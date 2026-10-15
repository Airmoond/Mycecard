## 人工试玩三种新敌人的入口；基础6张、50生命，复用正式战斗界面。
extends Control

const ENEMIES:Array[String] = ["bulwark_sentinel", "hexbound_acolyte", "ragebound_brute"]
var result_label:Label

func _ready()->void:
	_show_selection()

func _clear_page()->void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _show_selection()->void:
	_clear_page()
	var backdrop:ColorRect = ColorRect.new()
	backdrop.color = Color("182438")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var center:CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var list:VBoxContainer = VBoxContainer.new()
	list.custom_minimum_size = Vector2(560,0)
	list.add_theme_constant_override("separation",20)
	center.add_child(list)
	var title:Label = Label.new()
	title.text = "敌人试炼"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size",36)
	list.add_child(title)
	var subtitle:Label = Label.new()
	subtitle.text = "50生命 · 3张打击＋3张防御 · 每回合3能量"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size",20)
	list.add_child(subtitle)
	var descriptions:Array[String] = ["连续格挡三回合，随后发动重击", "以低伤攻击施加虚弱与易伤", "每回合增加2力量，攻击不断增强"]
	for i in range(ENEMIES.size()):
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % ENEMIES[i])
		var button:Button = Button.new()
		button.text = "%s · %d生命\n%s" % [enemy.display_name,enemy.max_health,descriptions[i]]
		button.custom_minimum_size.y = 95
		button.add_theme_font_size_override("font_size",24)
		button.pressed.connect(_start_fight.bind(ENEMIES[i]))
		list.add_child(button)

func _start_fight(enemy_id:String)->void:
	_clear_page()
	var page:Control = load("res://battle/battle.tscn").instantiate()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(page)
	var back:Button = Button.new()
	back.text = "返回选择"
	back.anchor_left = 1.0
	back.anchor_right = 1.0
	back.offset_left = -190
	back.offset_right = -20
	back.offset_top = 18
	back.offset_bottom = 64
	back.add_theme_font_size_override("font_size",22)
	back.pressed.connect(_show_selection)
	add_child(back)
	result_label = Label.new()
	result_label.text = "基础牌组试炼"
	result_label.offset_left = 25
	result_label.offset_top = 20
	result_label.add_theme_font_size_override("font_size",24)
	add_child(result_label)
	var character:CharacterDefinition = load("res://characters/data/warrior.tres")
	var deck:Array[CardDefinition] = []
	for entry in character.starting_deck_entries:
		for _n in range(entry.count):
			deck.append(entry.card_definition)
	var controller:BattleController = page.get_node("battle_controller")
	controller.battle_finished.connect(_on_finished)
	controller.start_battle(load("res://battle/data/encounters/%s_encounter.tres" % enemy_id),character.combatant_definition,deck,50,50)

func _on_finished(victory:bool, health:int, max_health:int)->void:
	result_label.text = "%s · 剩余生命 %d / %d" % ["胜利" if victory else "失败",health,max_health]
