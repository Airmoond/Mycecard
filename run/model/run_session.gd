## 冒险规则的唯一生产命令入口。场景、音乐与文本显示由外层负责。
class_name RunSession
extends RefCounted

static var _next_session_id:int = 0;
var state:RunState;
var step_token:int = 0;
var last_command_result:Dictionary = {};
var _battle_sequence:int = 0;

func initialize(definition:RunDefinition, seed_value:int = -1)->bool:
	var next_random:RunRNG = RunRNG.new(seed_value);
	var next_state:RunState = RunState.new();
	if not next_state.run_state_init(definition, next_random.run):
		return false;
	_next_session_id += 1;
	next_state.session_id = str(_next_session_id);
	next_state.random = next_random;
	state = next_state;
	_battle_sequence = 0;
	_refresh_draft_candidates();
	_accept({"command": "initialize"});
	return true;

func get_draft_candidates()->Array[CardDefinition]:
	var empty:Array[CardDefinition] = [];
	return state.draft_candidates if state != null else empty;

func choose_starting_card(card:CardDefinition, token:int = -1)->bool:
	if not _token_matches(token) or state.status != RunState.RunStatus.DRAFTING or not state.draft_candidates.has(card):
		return false;
	if not state.choose_starting_card(card):
		return false;
	_refresh_draft_candidates();
	_accept({"command": "draft", "added_card": card});
	return true;

func enter_node(node_id:String, token:int = -1)->bool:
	if not _token_matches(token) or not state.can_enter_node(node_id):
		return false;
	var node_type:int = state.get_node_type(node_id);
	if node_type not in [MapNodeDefinition.NodeType.START, MapNodeDefinition.NodeType.UNEXPECTED, MapNodeDefinition.NodeType.BATTLE, MapNodeDefinition.NodeType.BOSS, MapNodeDefinition.NodeType.REST]:
		return false;
	if node_type == MapNodeDefinition.NodeType.UNEXPECTED and state.get_unexpected_encounter(node_id) == null:
		return false;
	if node_type in [MapNodeDefinition.NodeType.BATTLE, MapNodeDefinition.NodeType.BOSS] and state.get_node_encounter(node_id) == null:
		return false;
	var previous_available:Array[String] = state.available_node_ids.duplicate();
	var previous_route:String = state.selected_route_id;
	var previous_health:int = state.current_health;
	var previous_random_state:int = state.random.run.state;
	if not state.enter_node(node_id):
		return false;
	var actual_heal:int = 0;
	var accepted:bool = false;
	match node_type:
		MapNodeDefinition.NodeType.START:
			if state.definition.collection_pool.is_empty():
				accepted = state.complete_current_node();
			else:
				accepted = state.begin_collection_selection(state.random.run);
		MapNodeDefinition.NodeType.UNEXPECTED:
			accepted = state.begin_unexpected_encounter(state.random.run);
		MapNodeDefinition.NodeType.BATTLE, MapNodeDefinition.NodeType.BOSS:
			_battle_sequence += 1;
			state.active_battle_id = "%s:%d:%s" % [state.session_id, _battle_sequence, node_id];
			state.status = RunState.RunStatus.IN_BATTLE;
			accepted = true;
		MapNodeDefinition.NodeType.REST:
			# 仅旧地图保留旧休整规则；随机位置没有该类型或自动恢复。
			actual_heal = state.heal(state.definition.map_definition.get_node_by_id(node_id).heal_amount);
			accepted = state.complete_current_node();
	if not accepted:
		state.current_node_id = "";
		state.available_node_ids = previous_available;
		state.selected_route_id = previous_route;
		state.current_health = previous_health;
		state.status = RunState.RunStatus.IN_PROGRESS;
		state.random.run.state = previous_random_state;
		return false;
	_accept({"command": "enter_node", "node_id": node_id, "actual_heal": actual_heal});
	return true;

func choose_collection(collection:CollectionDefinition, token:int = -1)->bool:
	if not _token_matches(token) or not state.choose_collection(collection):
		return false;
	_accept({"command": "collection", "collection": collection});
	return true;

func get_battle_request()->Dictionary:
	if state == null or state.status != RunState.RunStatus.IN_BATTLE:
		return {};
	var cards:Array[CardDefinition] = state.owned_cards.duplicate();
	cards.make_read_only();
	var request:Dictionary = {"battle_id": state.active_battle_id, "node_id": state.current_node_id, "encounter_definition": state.get_node_encounter(state.current_node_id), "character_definition": state.definition.character_definition, "player_definition": state.definition.character_definition.combatant_definition, "owned_cards": cards, "current_health": state.current_health, "max_health": state.max_health, "selected_collection": state.selected_collection, "rng": state.random.battle};
	request.make_read_only();
	return request;

func submit_battle_result(result:BattleResult)->bool:
	if state == null or result == null or state.status != RunState.RunStatus.IN_BATTLE or result.battle_id != state.active_battle_id or result.node_id != state.current_node_id or state.processed_battle_results.has(result.battle_id):
		return false;
	if not state.node_requires_encounter(result.node_id) or state.completed_node_ids.has(result.node_id):
		return false;
	if result.player_max_health <= 0 or result.player_health < 0 or result.player_health > result.player_max_health or (result.victory and result.player_health == 0) or (not result.victory and result.player_health != 0):
		return false;
	var snapshot:Dictionary = {"battle_id": result.battle_id, "node_id": result.node_id, "victory": result.victory, "player_health": result.player_health, "player_max_health": result.player_max_health};
	snapshot.make_read_only();
	var reward:RewardState;
	if result.victory and state.get_node_type(result.node_id) == MapNodeDefinition.NodeType.BATTLE:
		reward = RewardState.new(result.node_id, result.battle_id, state.definition.reward_selection_count);
		reward.set_candidates(_sample_reward());
		if reward.candidates.size() != state.definition.reward_option_count:
			return false;
	state.current_health = result.player_health;
	state.max_health = result.player_max_health;
	state.processed_battle_results[result.battle_id] = snapshot;
	state.last_battle_result = snapshot;
	state.active_battle_id = "";
	state.status = RunState.RunStatus.IN_PROGRESS;
	var actual_heal:int = 0;
	if not result.victory:
		state.mark_defeat();
	elif state.get_node_type(result.node_id) == MapNodeDefinition.NodeType.BOSS:
		state.complete_current_node();
		state.mark_victory();
	else:
		actual_heal = state.apply_normal_victory_collection();
		state.reward_state = reward;
		state.status = RunState.RunStatus.CHOOSING_REWARD;
	_accept({"command": "battle_result", "battle_result": snapshot, "actual_heal": actual_heal});
	return true;

func choose_reward(card:CardDefinition, token:int = -1)->bool:
	if not _token_matches(token) or state.status != RunState.RunStatus.CHOOSING_REWARD or state.reward_state == null or card == null or not state.reward_state.candidates.has(card):
		return false;
	return _consume_reward(card);

func skip_reward(token:int = -1)->bool:
	if not _token_matches(token) or state.status != RunState.RunStatus.CHOOSING_REWARD or state.reward_state == null:
		return false;
	return _consume_reward(null);

func get_option_view_data()->Array[Dictionary]:
	return UnexpectedEncounterExecutor.get_option_view_data(state);

func get_unexpected_candidates(option_id:String)->Array[CardDefinition]:
	return UnexpectedEncounterExecutor.get_candidates(state, option_id);

func get_unexpected_result_view_data()->Dictionary:
	return UnexpectedEncounterExecutor.get_result_view_data(state);

func resolve_unexpected(option_id:String, card:CardDefinition = null, deck_index:int = -1, token:int = -1)->bool:
	if not _token_matches(token) or not state.resolve_unexpected_encounter(option_id, card, deck_index):
		return false;
	var result:Dictionary = state.unexpected_results[state.current_node_id].duplicate();
	result["command"] = "unexpected";
	_accept(result);
	return true;

func continue_unexpected(token:int = -1)->bool:
	if not _token_matches(token) or not state.continue_unexpected_encounter():
		return false;
	_accept({"command": "continue_unexpected"});
	return true;

func _consume_reward(card:CardDefinition)->bool:
	var reward:RewardState = state.reward_state;
	if reward.remaining_rounds <= 0 or reward.node_id != state.current_node_id or state.get_node_type(reward.node_id) != MapNodeDefinition.NodeType.BATTLE or state.completed_node_ids.has(reward.node_id):
		return false;
	var next_candidates:Array[CardDefinition] = [];
	if reward.remaining_rounds > 1:
		next_candidates = _sample_reward();
		if next_candidates.size() != state.definition.reward_option_count:
			return false;
	if card != null:
		state.owned_cards.append(card);
	reward.record_selection(card);
	reward.set_candidates(next_candidates);
	if reward.remaining_rounds == 0:
		state.reward_history[reward.node_id] = reward;
		state.reward_state = null;
		state.status = RunState.RunStatus.IN_PROGRESS;
		state.complete_current_node();
	_accept({"command": "reward", "added_card": card, "skipped": card == null, "round_index": reward.round_index - 1, "node_id": reward.node_id});
	return true;

func _sample_reward()->Array[CardDefinition]:
	return CardPoolSampler.sample(state.definition.character_definition.reward_card_pool, state.definition.reward_option_count, CardPoolSampler.REWARD_RARITIES, state.random.run);

func _refresh_draft_candidates()->void:
	var candidates:Array[CardDefinition] = [];
	if state.status == RunState.RunStatus.DRAFTING:
		candidates = CardPoolSampler.filter_pool(state.definition.character_definition.reward_card_pool, [state.get_draft_rarity()]);
	candidates.make_read_only();
	state.draft_candidates = candidates;

func _token_matches(token:int)->bool:
	return state != null and (token == -1 or token == step_token);

func _accept(result:Dictionary)->void:
	step_token += 1;
	result.make_read_only();
	last_command_result = result;
