## F6 Boss试炼的三种构筑、两种入场生命、敌人选择和返回重开隔离检查。
## 通过真实按钮与选项信号启动战斗，不修改正式角色、卡牌或敌人资源。
extends SceneTree

const TRIAL_SCENE:PackedScene = preload("res://综合数值模型/Boss实验/Boss试炼.tscn");
const ENEMY_IDS:Array[String] = ["ironcrown_tyrant", "calamity_hierophant", "ruin_guard"];
const REFERENCE_IDS:Array[String] = ["eternity", "war_god_blessing", "uppercut"];

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _buttons(node:Node)->Array[Button]:
	var result:Array[Button] = [];
	if (node is Button) and not (node is OptionButton):
		result.append(node);
	for child in node.get_children():
		result.append_array(_buttons(child));
	return result;


func _enemy_button(trial:Control, enemy_id:String)->Button:
	var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id);
	for button in _buttons(trial):
		if button.text.contains(enemy.display_name):
			return button;
	return null;


func _check_selection(trial:Control)->void:
	var choices:Array[Button] = _buttons(trial);
	_expect(choices.size() == 3, "Boss试炼选择页应显示两名新Boss及遗迹守卫三个按钮");
	for enemy_id in ENEMY_IDS:
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id);
		var button:Button = _enemy_button(trial, enemy_id);
		_expect(button != null, "选择页应包含Boss：%s" % enemy_id);
		if button != null:
			_expect(button.text.contains(str(enemy.max_health)), "Boss选择按钮应显示正式资源生命");
			_expect(not button.disabled and button.pressed.get_connections().size() > 0, "Boss按钮应可用且已连接战斗交互");
	var deck_select:OptionButton = trial.find_child("deck_select", true, false) as OptionButton;
	var health_select:OptionButton = trial.find_child("health_select", true, false) as OptionButton;
	_expect(deck_select != null and deck_select.item_count == 3, "构筑选项应提供基础、参考和随机三种牌组");
	_expect(health_select != null and health_select.item_count == 2, "生命选项应提供50和35两种入场生命");
	if deck_select != null:
		_expect(deck_select.selected == int(trial.get("deck_choice")), "返回菜单应保留所选构筑");
		_expect(deck_select.item_selected.get_connections().size() > 0, "构筑选项应连接真实选择交互");
	if health_select != null:
		_expect(health_select.selected == (0 if int(trial.get("starting_health")) == 50 else 1), "返回菜单应保留所选入场生命");
		_expect(health_select.item_selected.get_connections().size() > 0, "生命选项应连接真实选择交互");
	_expect(trial.get_node_or_null("battle") == null, "返回选择页后应移除上一场战斗界面");


func _collect_cards(state:BattleState)->Array[CardInstance]:
	var all_cards:Array[CardInstance] = [];
	all_cards.append_array(state.draw_pile);
	all_cards.append_array(state.hand);
	all_cards.append_array(state.discard_pile);
	all_cards.append_array(state.exhaust_pile);
	all_cards.append_array(state.played_power_cards);
	if state.resolving_card != null:
		all_cards.append(state.resolving_card);
	if state.equipped_weapon != null:
		all_cards.append(state.equipped_weapon);
	return all_cards;


func _check_deck(state:BattleState, deck_choice:int, trial:Control)->void:
	var all_cards:Array[CardInstance] = _collect_cards(state);
	var counts:Dictionary = {"strike":0, "defend":0};
	var rarities:Dictionary = {};
	var character:CharacterDefinition = load("res://characters/data/warrior.tres");
	var extra_cards:Array[CardDefinition] = [];
	for card in all_cards:
		var definition:CardDefinition = card.definition;
		counts[definition.card_id] = int(counts.get(definition.card_id, 0)) + 1;
		if definition.card_id != "strike" and definition.card_id != "defend":
			extra_cards.append(definition);
			rarities[definition.rarity] = int(rarities.get(definition.rarity, 0)) + 1;
			_expect(character.reward_card_pool.has(definition), "新增构筑牌必须来自战士正式奖励卡池");
	_expect(counts.strike == 3 and counts.defend == 3, "三种构筑均应保留3打击与3防御");
	if deck_choice == 0:
		_expect(all_cards.size() == 6 and counts.size() == 2 and extra_cards.is_empty(), "基础试炼应只有6张基础牌");
	elif deck_choice == 1:
		_expect(all_cards.size() == 9 and extra_cards.size() == 3 and counts.size() == 5, "参考试炼应为6张基础牌加3张指定构筑牌");
		for card_id in REFERENCE_IDS:
			_expect(int(counts.get(card_id, 0)) == 1, "参考构筑应各有1张永恒、战神祝福与上勾拳");
	else:
		_expect(all_cards.size() == 9 and extra_cards.size() == 3 and counts.size() == 5, "随机试炼应为6张基础牌加3张不同稀有度的合法牌");
		_expect(rarities.size() == 3, "随机试炼的3张奖励牌应覆盖3种稀有度");
		for rarity in [CardDefinition.CardRarity.LEGENDARY, CardDefinition.CardRarity.EPIC, CardDefinition.CardRarity.RARE]:
			_expect(int(rarities.get(rarity, 0)) == 1, "随机开局应各有1张传说、史诗与稀有牌");
	var result_label:Label = trial.get("result_label") as Label;
	_expect(result_label != null, "试炼战斗应显示当前构筑提示");
	if result_label != null:
		for definition in extra_cards:
			_expect(result_label.text.contains(definition.card_name), "构筑提示应显示实际带入的每张奖励牌名称");
	_expect(not state.is_invalid_battle(), "Boss试炼全部牌区、实例与正式战斗状态应完整合法");


func _run()->void:
	seed(726331);
	var trial:Control = TRIAL_SCENE.instantiate();
	root.add_child(trial);
	_check_selection(trial);
	var previous_state:BattleState = null;
	for deck_choice in [0, 1, 2]:
		for starting_health in [50, 35]:
			for enemy_id in ENEMY_IDS:
				var deck_select:OptionButton = trial.find_child("deck_select", true, false) as OptionButton;
				var health_select:OptionButton = trial.find_child("health_select", true, false) as OptionButton;
				if deck_select == null or health_select == null:
					_expect(false, "Boss试炼应保留可交互的构筑和生命选择器");
					continue;
				deck_select.select(deck_choice);
				deck_select.item_selected.emit(deck_choice);
				health_select.select(0 if starting_health == 50 else 1);
				health_select.item_selected.emit(0 if starting_health == 50 else 1);
				_expect(int(trial.get("deck_choice")) == deck_choice and int(trial.get("starting_health")) == starting_health, "选择器应把所选构筑和生命传给试炼入口");
				var enemy_button:Button = _enemy_button(trial, enemy_id);
				if enemy_button == null:
					_expect(false, "待试炼Boss应存在对应按钮");
					continue;
				enemy_button.pressed.emit();
				var controller:BattleController = trial.get_node_or_null("battle/battle_controller") as BattleController;
				_expect(controller != null and controller.battle_state != null, "点击Boss按钮应启动正式战斗控制器");
				if controller == null or controller.battle_state == null:
					trial.call("_show_selection");
					continue;
				var state:BattleState = controller.battle_state;
				var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id);
				_expect(state != previous_state, "每次Boss试炼应创建新的战斗状态");
				_expect(state.current_phase == BattleState.BattlePhase.PLAYER_TURN and state.current_turn_number == 1, "Boss试炼应从第一个玩家回合开始");
				_expect(state.player_state.current_health == starting_health and state.player_state.max_health == 50, "Boss试炼应按50/50或35/50生命入场");
				_expect(state.enemy_state.enemy_definition.combatant_id == enemy_id, "Boss按钮应加载所选敌人，而非固定同一个遭遇");
				_expect(state.enemy_state.current_health == enemy.max_health and state.enemy_state.max_health == enemy.max_health, "Boss应以正式资源配置的完整生命入场");
				_expect(state.enemy_state.current_action_index == 0 and state.enemy_state.current_block == 0, "新Boss试炼应从第一个行动、零格挡开始");
				_expect(state.player_state.strength == 0 and state.enemy_state.strength == 0, "重开试炼不能继承上一场双方力量");
				_expect(state.player_state.weak_turns == 0 and state.player_state.vulnerable_turns == 0, "重开试炼不能继承玩家减益");
				_expect(state.enemy_state.weak_turns == 0 and state.enemy_state.vulnerable_turns == 0, "重开试炼不能继承Boss减益");
				_expect(state.energy_per_turn == 3 and state.current_available_energy == 3 and state.cards_per_turn == 5, "Boss试炼应保留正式3能量及5抽牌规则");
				_check_deck(state, deck_choice, trial);
				# 留下明显的运行时变化，随后通过返回按钮检查下一局隔离。
				state.player_state.lose_health(11);
				state.player_state.gain_strength(5);
				state.enemy_state.gain_strength(12);
				state.enemy_state.gain_block(17);
				state.enemy_state.advance_to_next_action();
				state.player_state.apply_weak(2, true);
				state.player_state.apply_vulnerable(2, true);
				state.enemy_state.apply_weak(2, false);
				state.enemy_state.apply_vulnerable(2, false);
				previous_state = state;
				var back:Button = null;
				for button in _buttons(trial):
					if button.text == "返回选择":
						back = button;
						break;
				_expect(back != null and back.pressed.get_connections().size() > 0, "Boss试炼战斗应提供已连接的返回选择按钮");
				if back != null:
					back.pressed.emit();
				else:
					trial.call("_show_selection");
				_check_selection(trial);
				await process_frame;
	trial.queue_free();
	await process_frame;
	print("新Boss试炼入口检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);
