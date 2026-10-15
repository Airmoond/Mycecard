## 不期而遇的局部规则执行器。查询无副作用，evaluate 只生成提交方案。
class_name UnexpectedEncounterExecutor
extends RefCounted

static func prepare_candidates(state:RunState, rng:RandomNumberGenerator = null)->Dictionary:
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	var choices:Dictionary = {};
	for option in content.options:
		if option.operation != UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
			continue;
		var cards:Array[CardDefinition] = CardPoolSampler.sample(option.candidate_pool(state.definition.character_definition.reward_card_pool), option.candidate_count, option.card_rarities, rng);
		if cards.size() != option.candidate_count:
			return {};
		cards.make_read_only();
		choices[option.option_id] = cards;
	choices.make_read_only();
	return choices;

static func get_option_view_data(state:RunState)->Array[Dictionary]:
	var data:Array[Dictionary] = [];
	if state == null or state.status != RunState.RunStatus.CHOOSING_UNEXPECTED:
		return data;
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	if content == null:
		return data;
	for option in content.options:
		var enabled:bool = is_option_enabled(state, option);
		var item:Dictionary = {"option_id": option.option_id, "label": option.label, "enabled": enabled, "disabled_reason": "" if enabled else option.disabled_reason, "selection_kind": option.get_selection_kind()};
		item.make_read_only();
		data.append(item);
	data.make_read_only();
	return data;

static func is_option_enabled(state:RunState, option:UnexpectedEncounterOptionDefinition)->bool:
	if state == null or option == null or state.status != RunState.RunStatus.CHOOSING_UNEXPECTED or state.unexpected_results.has(state.current_node_id):
		return false;
	if option.health_cost > 0 and state.current_health <= option.health_cost:
		return false;
	if option.operation == UnexpectedEncounterOptionDefinition.Operation.REMOVE_CARD:
		return state.owned_cards.size() > 1;
	if option.operation == UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
		return get_candidates(state, option.option_id).size() == option.candidate_count;
	return true;

static func get_candidates(state:RunState, option_id:String)->Array[CardDefinition]:
	var empty:Array[CardDefinition] = [];
	if state == null:
		return empty;
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	var option:UnexpectedEncounterOptionDefinition = content.get_option(option_id) if content != null else null;
	if option == null:
		return empty;
	if option.operation == UnexpectedEncounterOptionDefinition.Operation.REMOVE_CARD:
		var cards:Array[CardDefinition] = state.owned_cards.duplicate();
		cards.make_read_only();
		return cards;
	if option.operation == UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
		return state.unexpected_option_candidates.get(state.current_node_id, {}).get(option_id, empty);
	return empty;

static func evaluate(state:RunState, option_id:String, card:CardDefinition = null, deck_index:int = -1)->Dictionary:
	if state == null or state.status != RunState.RunStatus.CHOOSING_UNEXPECTED or state.unexpected_results.has(state.current_node_id):
		return {};
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	var option:UnexpectedEncounterOptionDefinition = content.get_option(option_id) if content != null else null;
	if option == null or not is_option_enabled(state, option):
		return {};
	var actual_heal:int = 0;
	var added_card:CardDefinition;
	var removed_card:CardDefinition;
	match option.operation:
		UnexpectedEncounterOptionDefinition.Operation.LEAVE:
			if card != null or deck_index != -1:
				return {};
		UnexpectedEncounterOptionDefinition.Operation.HEAL:
			if card != null or deck_index != -1:
				return {};
			actual_heal = mini(option.heal_amount, state.max_health - state.current_health);
		UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD:
			if card == null or deck_index != -1 or not get_candidates(state, option_id).has(card):
				return {};
			added_card = card;
		UnexpectedEncounterOptionDefinition.Operation.REMOVE_CARD:
			if deck_index < 0 or deck_index >= state.owned_cards.size() or state.owned_cards[deck_index] != card:
				return {};
			removed_card = state.owned_cards[deck_index];
	var result:Dictionary = {"option_id": option_id, "actual_heal": actual_heal, "health_cost": option.health_cost, "added_card": added_card, "removed_card": removed_card, "removed_deck_index": deck_index if removed_card != null else -1};
	result.make_read_only();
	return result;

static func get_result_view_data(state:RunState)->Dictionary:
	if state == null or not state.unexpected_results.has(state.current_node_id):
		return {};
	var result:Dictionary = state.unexpected_results[state.current_node_id];
	var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(state.current_node_id);
	var option:UnexpectedEncounterOptionDefinition = content.get_option(result["option_id"]);
	var data:Dictionary = result.duplicate();
	data["template"] = option.result_text;
	var card:CardDefinition = result["added_card"] if result["added_card"] != null else result["removed_card"];
	data["card_name"] = card.card_name if card != null else "";
	data.make_read_only();
	return data;
