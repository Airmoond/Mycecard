## 正式配置的整局自动试玩：只读规则作决策，所有变化均经页面选择和正式战斗入口。
## 不替换敌人/卡牌/遭遇，不改生命、能量、牌堆，不调用伤害或结算捷径。
extends SceneTree

const MAX_TURNS:int = 100;
const MAX_ACTIONS:int = 1200;
const SEEDS:Array[int] = [20261005, 20261006, 20261007, 20261008];
const BUILD_PRIORITY:Dictionary = {
	"eternity":100.0, "war_god_blessing":98.0, "fortress":90.0,
	"blood_cloak":88.0, "strength_power":86.0, "thorns":82.0,
	"uppercut":80.0, "technical_fighting":78.0, "bloodthirsty_sword":76.0,
	"blood_feast":74.0, "endless_power":72.0, "battle_trance":70.0,
	"shield_slam":68.0, "ancient_ritual":66.0, "shrug_it_off":62.0,
	"pommel_strike":60.0, "iron_wave":58.0, "trade_wounds":55.0
};

var failures:int = 0;
var reports:Array[Dictionary] = [];

func _initialize()->void:
	_run.call_deferred();

func expect(value:bool, message:String)->void:
	if not value:
		failures += 1;
		push_error(message);

func _run()->void:
	root.size = Vector2i(1280, 720);
	for seed_value:int in SEEDS:
		var report:Dictionary = await _play_run(seed_value);
		reports.append(report);
		print("整局试玩记录：%s" % JSON.stringify(report));
		if report.get("result") == "victory" or failures > 0:
			break;
	var terminal_runs:int = 0;
	var victories:int = 0;
	for report:Dictionary in reports:
		if report.get("result") in ["victory", "defeat"]:
			terminal_runs += 1;
		if report.get("result") == "victory":
			victories += 1;
			expect(report["completed_nodes"].size() == 5 and report["battles"].size() == 3, "胜利必须真实完成起点、三个路线节点与Boss");
			expect(report["reward_skips"] == 1 and report["reward_claims"] == 1 and report["unexpected"].size() == 1, "胜利路线覆盖一次奖励跳过、一次领取与一次不期而遇");
	expect(terminal_runs > 0, "至少一次正式冒险到达正常胜利或失败结算");
	expect(victories > 0, "固定正式配置和已验证决策应至少取得一次真实整局胜利");
	print("真实整局自动试玩完成：%d局，%d胜，失败数：%d" % [reports.size(), victories, failures]);
	await create_timer(0.5).timeout; # 仅等待测试退出时的音频线程清理，不改变正式切页时序。
	quit(0 if failures == 0 else 1);

func _play_run(seed_value:int)->Dictionary:
	var main:Node = load("res://main.tscn").instantiate();
	root.add_child(main);
	var flow:GameFlowController = main.get_node("game_flow_controller");
	flow.run_seed = seed_value;
	var report:Dictionary = {"seed":seed_value, "route":"a", "draft":[], "collection":"", "battles":[], "unexpected":[], "reward_skips":0, "reward_claims":0};
	(flow.current_page as MainMenu).start_button.pressed.emit();
	for _round in range(3):
		expect(flow.current_page is StartingDraftView, "从主菜单正常进入三轮构筑");
		if not flow.current_page is StartingDraftView:
			break;
		var draft:StartingDraftView = flow.current_page;
		var selected:CardDefinition = _best_definition(draft.candidates, flow.run_state.owned_cards);
		var target_page:int = draft.candidates.find(selected) / StartingDraftView.CARDS_PER_PAGE;
		while draft.page_index < target_page:
			draft.next_button.pressed.emit();
		for view:CardChoiceView in draft._card_views:
			if view.card_definition == selected:
				report["draft"].append(selected.card_id);
				view.pressed.emit();
				break;
	var state:RunState = flow.run_state;
	expect(flow.current_page is MapView and state.owned_cards.size() == 9, "构筑完成得到真实九张初始牌组");
	if failures > 0:
		main.queue_free();
		await process_frame;
		return report;
	(flow.current_page as MapView)._node_views["start"].node_button.pressed.emit();
	var collection_page:CollectionChoiceView = flow.current_page;
	var collection_index:int = 0;
	for index in range(state.collection_candidates.size()):
		if state.collection_candidates[index].collection_id == "copper_fang":
			collection_index = index;
			break;
	report["collection"] = state.collection_candidates[collection_index].collection_id;
	collection_page.choice_buttons[collection_index].pressed.emit();
	var nodes:Array[String] = state.definition.map_definition.get_route_node_ids("a");
	nodes.append("final_boss");
	for node_id:String in nodes:
		if state.status in [RunState.RunStatus.VICTORY, RunState.RunStatus.DEFEAT] or failures > 0:
			break;
		expect(flow.current_page is MapView and state.available_node_ids.has(node_id), "路线的下一节点必须真实开放");
		if not flow.current_page is MapView or not state.available_node_ids.has(node_id):
			break;
		(flow.current_page as MapView)._node_views[node_id].node_button.pressed.emit();
		if state.get_node_type(node_id) == MapNodeDefinition.NodeType.UNEXPECTED:
			_play_unexpected(flow, report);
		else:
			var battle_report:Dictionary = await _play_battle(flow, node_id);
			report["battles"].append(battle_report);
			if flow.current_page is RewardView:
				var reward:RewardView = flow.current_page;
				var cards_before:int = state.owned_cards.size();
				if report["reward_skips"] == 0:
					reward.skip_button.pressed.emit();
					report["reward_skips"] += 1;
					battle_report["reward"] = "skip";
					expect(state.owned_cards.size() == cards_before, "真实奖励跳过不增加卡牌");
				else:
					var selected:CardDefinition = _best_definition(reward.reward_options, state.owned_cards);
					for view:CardChoiceView in reward._reward_card_views:
						if view.card_definition == selected:
							view.pressed.emit();
							break;
					battle_report["reward"] = selected.card_id;
					report["reward_claims"] += 1;
					expect(state.owned_cards.size() == cards_before + 1, "真实奖励领取仅增加所选一张卡牌");
				expect(state.completed_node_ids.has(node_id) and flow.current_page is MapView, "战斗奖励选择后正常完成节点并回到地图");
		await process_frame;
	report["result"] = "victory" if state.status == RunState.RunStatus.VICTORY else ("defeat" if state.status == RunState.RunStatus.DEFEAT else "incomplete");
	report["health"] = state.current_health;
	report["max_health"] = state.max_health;
	report["completed_nodes"] = state.completed_node_ids.duplicate();
	report["deck"] = [];
	for card:CardDefinition in state.owned_cards:
		report["deck"].append(card.card_id);
	expect(flow.current_page is RunResult and report["result"] != "incomplete", "实际冒险应进入正常结算页，不能把测试中止当作胜负");
	main.queue_free();
	await process_frame;
	return report;

func _best_definition(cards:Array[CardDefinition], owned:Array[CardDefinition])->CardDefinition:
	var best:CardDefinition = cards[0];
	var best_value:float = -INF;
	var has_weapon:bool = false;
	for card:CardDefinition in owned:
		has_weapon = has_weapon or card.card_type == CardDefinition.CardType.WEAPON;
	for card:CardDefinition in cards:
		var value:float = float(BUILD_PRIORITY.get(card.card_id, 35.0));
		if has_weapon and card.card_type == CardDefinition.CardType.WEAPON:
			value -= 55.0;
		if card.card_id == "war_god_blessing" and not has_weapon:
			value -= 80.0;
		if value > best_value:
			best_value = value;
			best = card;
	return best;

func _play_unexpected(flow:GameFlowController, report:Dictionary)->void:
	var state:RunState = flow.run_state;
	var page:UnexpectedEncounterView = flow.current_page;
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	var record:Dictionary = {"node":state.current_node_id, "encounter":content.encounter_id, "health_before":state.current_health};
	var option:String = "leave";
	if content.kind == UnexpectedEncounterDefinition.Kind.CAMP:
		option = "heal";
	elif content.kind == UnexpectedEncounterDefinition.Kind.FOUNTAIN:
		option = "heal" if state.max_health - state.current_health >= 8 else "remove";
	elif state.current_health > content.health_cost + 15:
		var best:CardDefinition = _best_definition(state.unexpected_candidates[state.current_node_id], state.owned_cards);
		if float(BUILD_PRIORITY.get(best.card_id, 35.0)) >= 80.0:
			option = "card";
	page.option_buttons[option].pressed.emit();
	if option == "remove":
		for view:CardChoiceView in page.card_views:
			if view.card_definition.card_id == "strike":
				view.pressed.emit();
				break;
	elif option == "card":
		var selected:CardDefinition = _best_definition(state.unexpected_candidates[state.current_node_id], state.owned_cards);
		for view:CardChoiceView in page.card_views:
			if view.card_definition == selected:
				view.pressed.emit();
				break;
	expect(state.status == RunState.RunStatus.UNEXPECTED_RESULT and flow.current_page is UnexpectedEncounterView, "不期而遇真实选择先显示结果");
	if state.status != RunState.RunStatus.UNEXPECTED_RESULT:
		return;
	record["option"] = option;
	record["summary"] = UnexpectedEncounterExecutor.get_result_view_data(state).template.format(UnexpectedEncounterExecutor.get_result_view_data(state));
	record["health_after"] = state.current_health;
	report["unexpected"].append(record);
	(flow.current_page as UnexpectedEncounterView).option_buttons["continue"].pressed.emit();
	expect(flow.current_page is MapView, "不期而遇确认结果后真实返回地图");

func _incoming_damage(state:BattleState)->int:
	var action:EnemyActionDefinition = state.enemy_state.current_action;
	var preview:Array[int] = AttackDamageResolver.preview_effect_damage(action.effects, state.enemy_state, state.player_state, state.enemy_state.current_block);
	var total:int = 0;
	for index in range(action.effects.size()):
		if action.effects[index].effect_type == CombatEffectDefinition.EffectType.DAMAGE and action.effects[index].target_type == CombatEffectDefinition.TargetType.OPPONENT:
			total += preview[index] * action.effects[index].repeat_count;
	return total;

## 使用公开规则预览和当前敌人意图评分，不模拟或写入战斗状态。
func _card_value(card:CardInstance, state:BattleState)->float:
	var value:float = -float(card.current_energy_cost);
	if card.definition.card_type == CardDefinition.CardType.WEAPON:
		return 95.0 if state.equipped_weapon == null else -100.0;
	var preview:Array[int] = AttackDamageResolver.preview_effect_damage(card.definition.effects, state.player_state, state.enemy_state, state.player_state.current_block);
	var attack:int = 0;
	var block:int = 0;
	for index in range(card.definition.effects.size()):
		var effect:CombatEffectDefinition = card.definition.effects[index];
		var total:int = effect.amount * effect.repeat_count;
		match effect.effect_type:
			CombatEffectDefinition.EffectType.DAMAGE:
				if effect.target_type == CombatEffectDefinition.TargetType.OPPONENT:
					attack += preview[index] * effect.repeat_count;
			CombatEffectDefinition.EffectType.BLOCK:
				block += total;
			CombatEffectDefinition.EffectType.GAIN_ENERGY:
				value += total * 20.0;
			CombatEffectDefinition.EffectType.GAIN_ATTACK_CARD_ENERGY:
				value += total * 25.0;
			CombatEffectDefinition.EffectType.DRAW:
				if not state.draw_blocked_this_turn:
					value += total * 9.0;
			CombatEffectDefinition.EffectType.GAIN_STRENGTH:
				value += total * 25.0;
			CombatEffectDefinition.EffectType.ENHANCE_WEAPON:
				value += total * 9.0;
			CombatEffectDefinition.EffectType.APPLY_VULNERABLE:
				value += 18.0 if state.enemy_state.vulnerable_turns == 0 else 4.0;
			CombatEffectDefinition.EffectType.APPLY_WEAK:
				value += 18.0 if state.enemy_state.weak_turns == 0 else 4.0;
			CombatEffectDefinition.EffectType.APPLY_POWER:
				value += 55.0 if state.current_turn_number <= 3 and state.enemy_state.current_health > 20 else 5.0;
			CombatEffectDefinition.EffectType.LOSE_HEALTH:
				if state.player_state.current_health <= total:
					return -1000.0;
				value -= total * 3.0;
			CombatEffectDefinition.EffectType.LOSE_MAX_HEALTH:
				value -= total * 8.0;
	if attack >= state.enemy_state.current_health + state.enemy_state.current_block:
		value += 250.0;
	value += maxi(0, attack - state.enemy_state.current_block) * 1.2 + mini(attack, state.enemy_state.current_block) * 0.3;
	var needed_block:int = maxi(0, _incoming_damage(state) - state.player_state.current_block);
	value += mini(block, needed_block) * 2.2;
	if state.player_state.has_power(PowerDefinition.PowerType.RETAIN_BLOCK):
		value += maxi(0, block - needed_block) * 1.1;
	for effect:CombatEffectDefinition in card.definition.effects:
		if effect.heals_from_damage:
			value += mini(maxi(0, attack - state.enemy_state.current_block), state.player_state.max_health - state.player_state.current_health) * 1.8;
	return value;

func _prepare_weapon(card:CardInstance)->bool:
	for effect:CombatEffectDefinition in card.definition.effects:
		if effect.effect_type in [CombatEffectDefinition.EffectType.GAIN_STRENGTH, CombatEffectDefinition.EffectType.ENHANCE_WEAPON, CombatEffectDefinition.EffectType.APPLY_VULNERABLE]:
			return true;
	return false;

func _play_battle(flow:GameFlowController, node_id:String)->Dictionary:
	var page:Control = flow.current_page;
	var controller:BattleController = page.get_node("battle_controller");
	var state:BattleState = controller.battle_state;
	var record:Dictionary = {"node":node_id, "enemy":state.enemy_state.definition.combatant_id, "health_before":state.player_state.current_health, "cards_played":0, "weapon_attacks":0, "ended_turns":0, "turns":[]};
	var last_turn:int = 0;
	for _action in range(MAX_ACTIONS):
		if not is_instance_valid(page) or flow.current_page != page:
			break;
		expect(not state.is_invalid_battle(), "真实出牌过程中牌堆归属和战斗状态保持合法");
		if failures > 0:
			break;
		if state.current_turn_number != last_turn:
			last_turn = state.current_turn_number;
			record["turns"].append({"turn":last_turn, "health":state.player_state.current_health, "enemy_health":state.enemy_state.current_health, "intent":state.enemy_state.current_action.action_id, "actions":[]});
		expect(last_turn <= MAX_TURNS, "真实战斗应在回合上限内正常结束");
		if last_turn > MAX_TURNS:
			break;
		var selected:CardInstance = null;
		var best_value:float = 0.0;
		for card:CardInstance in state.hand:
			if controller._card_is_playable(card):
				var value:float = _card_value(card, state);
				if value > best_value:
					best_value = value;
					selected = card;
		var actions:Array = record["turns"].back()["actions"];
		if state.can_attack_with_weapon() and (selected == null or not _prepare_weapon(selected)):
			actions.append("weapon:%s" % state.equipped_weapon.definition.card_id);
			controller._on_weapon_attack_requested();
			record["weapon_attacks"] += 1;
			expect(not state.weapon_attack_available, "真实武器攻击消耗本回合攻击机会");
		elif selected != null:
			actions.append(selected.definition.card_id);
			controller._on_card_selected(selected);
			record["cards_played"] += 1;
			expect(not state.hand.has(selected) and state.resolving_card == null, "被接受的真实出牌完成效果和归档");
		else:
			actions.append("end_turn");
			var before:int = state.current_turn_number;
			controller._on_end_turn_button_pressed();
			record["ended_turns"] += 1;
			expect(flow.current_page != page or state.current_turn_number > before, "结束回合真实推进敌人行动或正常结算");
		await process_frame;
		expect(not state.is_invalid_battle(), "每次真实操作后战斗守恒检查通过");
	record["turn_count"] = state.current_turn_number;
	record["health_after"] = state.player_state.current_health;
	record["enemy_health_after"] = state.enemy_state.current_health;
	record["victory"] = state.is_victory() and not state.is_defeat();
	expect(state.current_phase == BattleState.BattlePhase.FINISHED and state.resolving_card == null, "战斗经正式结果入口结束并完成卡牌归档");
	return record;
