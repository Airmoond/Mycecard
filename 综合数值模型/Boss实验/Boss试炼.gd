## Boss单场试玩，支持基础牌、参考构筑及随机合法开局，复用正式战斗界面。
extends Control

const ENEMIES:Array[String] = ["ironcrown_tyrant","calamity_hierophant","ruin_guard"]
const REFERENCE:Array[String] = ["eternity","war_god_blessing","uppercut"]
var deck_choice:int = 1
var starting_health:int = 50
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
	list.custom_minimum_size = Vector2(680,0)
	list.add_theme_constant_override("separation",16)
	center.add_child(list)
	var title:Label = Label.new()
	title.text = "Boss试炼"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size",36)
	list.add_child(title)
	var deck_select:OptionButton = OptionButton.new()
	deck_select.name = "deck_select"
	for label in ["基础牌组：3打击＋3防御","参考构筑：基础＋永恒、战神祝福、上勾拳","随机开局：基础＋传说、史诗、稀有各1张"]:
		deck_select.add_item(label)
	deck_select.selected = deck_choice
	deck_select.add_theme_font_size_override("font_size",20)
	deck_select.item_selected.connect(func(index:int)->void:deck_choice=index)
	list.add_child(deck_select)
	var health_select:OptionButton = OptionButton.new()
	health_select.name = "health_select"
	health_select.add_item("满血入场：50 / 50")
	health_select.add_item("伤后入场：35 / 50")
	health_select.selected = 0 if starting_health == 50 else 1
	health_select.add_theme_font_size_override("font_size",20)
	health_select.item_selected.connect(func(index:int)->void:starting_health=50 if index==0 else 35)
	list.add_child(health_select)
	var descriptions:Array[String] = ["攻守切换与三连斩，第四轮整顿防御","虚弱、易伤衔接连续攻击，第四轮重聚法障","现有Boss，用于对照试玩"]
	for i in range(ENEMIES.size()):
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % ENEMIES[i])
		var button:Button = Button.new()
		button.text = "%s · %d生命\n%s" % [enemy.display_name,enemy.max_health,descriptions[i]]
		button.custom_minimum_size.y = 90
		button.add_theme_font_size_override("font_size",24)
		button.pressed.connect(_start_fight.bind(ENEMIES[i]))
		list.add_child(button)

func _build_deck()->Array[CardDefinition]:
	var character:CharacterDefinition = load("res://characters/data/warrior.tres")
	var deck:Array[CardDefinition] = []
	for entry in character.starting_deck_entries:
		for _n in range(entry.count):
			deck.append(entry.card_definition)
	if deck_choice == 1:
		for id in REFERENCE:
			deck.append(load("res://cards/data/%s.tres" % id))
	elif deck_choice == 2:
		for rarity in [3,2,1]:
			deck.append(CardPoolSampler.sample(character.reward_card_pool,3,[rarity])[0])
	return deck

func _start_fight(enemy_id:String)->void:
	var deck:Array[CardDefinition] = _build_deck()
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
	result_label.text = "基础牌组" if deck_choice == 0 else "构筑：%s／%s／%s" % [deck[6].card_name,deck[7].card_name,deck[8].card_name]
	result_label.offset_left = 25
	result_label.offset_top = 20
	result_label.add_theme_font_size_override("font_size",20)
	add_child(result_label)
	var character:CharacterDefinition = load("res://characters/data/warrior.tres")
	var controller:BattleController = page.get_node("battle_controller")
	controller.battle_finished.connect(_on_finished)
	controller.start_battle(load("res://battle/encounters/data/%s_encounter.tres" % enemy_id),character.combatant_definition,deck,starting_health,50)

func _on_finished(victory:bool, health:int, max_health:int)->void:
	result_label.text = "%s · 剩余生命 %d / %d" % ["胜利" if victory else "失败",health,max_health]
