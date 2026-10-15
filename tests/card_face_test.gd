## 卡面标识、样式实例隔离及完整文案的排版回归。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _card(id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % id);


func _hand(definition:CardDefinition)->CardView:
	var view:CardView = load("res://cards/card_view.tscn").instantiate();
	root.add_child(view);
	var instance:CardInstance = CardInstance.new();
	instance.card_instance_init(definition);
	view.bind_card_instance(instance);
	return view;


func _run()->void:
	_test_metadata_and_isolation();
	await _test_all_descriptions();
	await _test_resize_and_refresh();
	await _test_shared_face_and_input();
	await process_frame;
	print("卡面标识与完整描述检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _test_metadata_and_isolation()->void:
	var views:Array[CardView] = [];
	var cases:Array = [
		["strike", "攻击", Color.WHITE],
		["battle_trance", "技能", Color("3b82f6")],
		["blood_cloak", "能力", Color("a855f7")],
		["eternity", "武器", Color("ffa500")]
	];
	for values in cases:
		views.append(_hand(_card(values[0])));
	# 同时存在四种稀有度：后一张的颜色不能污染前面的卡。
	for index in range(views.size()):
		var view:CardView = views[index];
		_expect(view.get_node("card_face/cardtype_label").text == cases[index][1], "四种类型正确对应");
		_expect(view.get_node("card_face/expansion_type_label").text == "标", "当前全部为标准扩展包");
		for name in ["cost_label", "name_label", "description_label", "cardtype_label", "expansion_type_label"]:
			_expect(view.get_node("card_face/" + name).get_theme_stylebox("normal").border_color == cases[index][2], "所有标签边框按稀有度显示，彼此不串色");
		view.queue_free();
	# 新实例仍使用用户场景原样式，运行时不能改写 PackedScene 的共享样式。
	var fresh:CardView = load("res://cards/card_view.tscn").instantiate();
	root.add_child(fresh);
	_expect(fresh.card_face.name_label.get_theme_stylebox("normal").border_color != Color("ffa500"), "原场景样式未被上一张传说卡修改");
	fresh.queue_free();


func _test_all_descriptions()->void:
	var definitions:Array[CardDefinition] = load("res://characters/data/warrior.tres").reward_card_pool.duplicate();
	definitions.append_array([_card("strike"), _card("defend")]);
	var views:Array[Control] = [];
	for definition in definitions:
		var hand:CardView = _hand(definition);
		var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
		root.add_child(reward);
		reward.setup(definition);
		views.append_array([hand, reward]);
		_expect(hand.card_face.description_label.text == definition.format_description() and reward.card_face.description_label.text == hand.card_face.description_label.text, "手牌与奖励保留全部文字");
		_expect(reward.get_node("card_face/cardtype_label").text == hand.get_node("card_face/cardtype_label").text and reward.get_node("card_face/expansion_type_label").text == "标", "开局/奖励显示相同类型和扩展包");
		for name in ["cost_label", "name_label", "description_label", "cardtype_label", "expansion_type_label"]:
			_expect(reward.get_node("card_face/" + name).get_theme_stylebox("normal").border_color == hand.get_node("card_face/" + name).get_theme_stylebox("normal").border_color, "奖励与手牌稀有度颜色一致");
	await process_frame;
	await process_frame;
	for view in views:
		var label:CardDescriptionLabel = view.get_node("card_face/description_label");
		var available:float = label.size.y - label.get_theme_stylebox("normal").get_minimum_size().y;
		_expect(label.get_content_height() <= available, "全文在描述框内：%s" % view.get_node("card_face/name_label").text);
		_expect(not label.get_rect().intersects(view.get_node("card_face/cardtype_label").get_rect()), "文字区域不与底部类型重叠");
		_expect(not label.text.contains("{damage_"), "最终显示没有未替换的伤害占位符");
		_expect(view.tooltip_text == "标准扩展包\n" + label.text, "接收鼠标的卡牌根节点提供完整悬停文案");
		print("%s %s 字号%d" % [view.get_class(), view.get_node("card_face/name_label").text, label.get_theme_font_size("normal_font_size")]);
		view.queue_free();


func _test_resize_and_refresh()->void:
	var view:CardView = _hand(_card("eternity"));
	var label:CardDescriptionLabel = view.card_face.description_label;
	var original:String = label.text;
	_expect(label.get_theme_font_size("normal_font_size") < 12, "永恒全文触发自动缩字");
	label.size.y = 160;
	await process_frame;
	_expect(label.get_theme_font_size("normal_font_size") == 12 and label.text == original, "空间增大恢复场景字号且全文不变");
	label.size.y = 51;
	await process_frame;
	_expect(label.get_theme_font_size("normal_font_size") < 12 and label.text == original, "空间缩小重新适配");
	view.set_description("造成999点伤害。");
	_expect(label.get_theme_font_size("normal_font_size") == 12 and label.text == "造成999点伤害。", "动态预览更新后恢复合适字号");
	_expect(view.tooltip_text.ends_with(label.text), "动态预览同步更新悬停文案");
	view.queue_free();


## 从视口发送点击，验证新增卡面层没有截获出牌或选牌输入。
func _click(position:Vector2)->void:
	var motion:InputEventMouseMotion = InputEventMouseMotion.new();
	motion.position = position;
	root.push_input(motion, true);
	for pressed in [true, false]:
		var event:InputEventMouseButton = InputEventMouseButton.new();
		event.button_index = MOUSE_BUTTON_LEFT;
		event.position = position;
		event.pressed = pressed;
		root.push_input(event, true);


func _test_shared_face_and_input()->void:
	await process_frame;
	var definition:CardDefinition = _card("strike");
	var hand:CardView = _hand(definition);
	hand.position = Vector2(20, 20);
	var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
	root.add_child(reward);
	reward.position = Vector2(200, 20);
	reward.setup(definition);
	reward.set_interactable(true);
	hand.card_instance.current_energy_cost = 0;
	hand.refresh_card_view();
	hand.set_description("造成9点伤害");
	_expect(hand.card_face.scene_file_path == "res://cards/card_face.tscn" and reward.card_face.scene_file_path == hand.card_face.scene_file_path, "两种外层引用同一份卡面场景");
	_expect(hand.card_face.cost_label.text == "0" and reward.card_face.cost_label.text == "1", "手牌当前费用与奖励基础费用彼此独立");
	_expect(reward.card_face.description_label.text == "造成6点伤害" and definition.description == "造成{damage_0}点伤害", "动态预览不污染静态卡面或原资源");
	var hand_selected:Array[CardInstance] = [];
	var reward_selected:Array[CardDefinition] = [];
	hand.card_selected.connect(func(card:CardInstance)->void: hand_selected.append(card));
	reward.card_selected.connect(func(card:CardDefinition)->void: reward_selected.append(card));
	await process_frame;
	# 分别点击费用、名称、插画、描述、类型和扩展包区域。
	var points:Array[Vector2] = [Vector2(10, 10), Vector2(60, 10), Vector2(70, 70), Vector2(70, 145), Vector2(70, 184), Vector2(125, 10)];
	for point in points:
		_click(hand.global_position + point);
		_click(reward.global_position + point);
	_expect(hand_selected.size() == points.size() and hand_selected[0] == hand.card_instance, "卡面各区域点击均到达手牌外层并报告原实例");
	_expect(reward_selected.size() == 1 and reward_selected[0] == definition and reward.disabled, "奖励点击报告原定义，禁用后后续点击不重复选择");
	reward.setup(definition);
	reward.set_interactable(true);
	_click(reward.global_position + Vector2(70, 145));
	_expect(reward_selected.size() == 2, "奖励重新绑定后可再次选择");
	hand.queue_free();
	reward.queue_free();
