## 冒险规则的唯一生产命令入口。场景、音乐与文本显示由外层负责。
class_name RunSession
extends RefCounted

## 进程内已创建的会话序号，用于生成互不相同的会话身份。
static var _next_session_id:int = 0;
## 本会话持有的整局运行状态，初始化成功后才替换。
var state:RunState;
## 每次接受命令后递增的步骤令牌，用于拒绝旧页面提交。
var step_token:int = 0;
## 最近一次被接受命令的只读结果，供流程层读取实际收益及反馈。
var last_command_result:Dictionary = {};
## 本会话已分配的战斗序号，与会话及节点标识共同构成本场身份。
var _battle_sequence:int = 0;

## 创建并验证新局状态和独立随机流，成功后建立会话身份、刷新构筑候选并接受初始化命令。
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

## 返回本轮已保存的构筑候选；尚未初始化时返回空数组，不消耗随机流。
func get_draft_candidates()->Array[CardDefinition]:
	var empty:Array[CardDefinition] = [];
	return state.draft_candidates if state != null else empty;

## 在步骤令牌和构筑候选有效时加入所选卡牌，刷新下一轮候选并推进命令步骤。
func choose_starting_card(card:CardDefinition, token:int = -1)->bool:
	if not _token_matches(token) or state.status != RunState.RunStatus.DRAFTING or not state.draft_candidates.has(card):
		return false;
	if not state.choose_starting_card(card):
		return false;
	_refresh_draft_candidates();
	_accept({"command": "draft", "added_card": card});
	return true;

## 尝试进入节点并开始对应战斗、藏品选择、不期而遇或旧休整流程。
##
## 准备失败时恢复进入前的进度、生命和内容随机源状态，并返回 [code]false[/code]。
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

## 按步骤令牌提交藏品选择；选择成功后记录命令并返回 [code]true[/code]。
func choose_collection(collection:CollectionDefinition, token:int = -1)->bool:
	if not _token_matches(token) or not state.choose_collection(collection):
		return false;
	_accept({"command": "collection", "collection": collection});
	return true;

## 返回当前战斗所需的只读请求及牌组副本；不在战斗阶段时返回空字典。
##
## 请求中的定义和随机源仍引用本局对象。
func get_battle_request()->Dictionary:
	if state == null or state.status != RunState.RunStatus.IN_BATTLE:
		return {};
	var cards:Array[CardDefinition] = state.owned_cards.duplicate();
	cards.make_read_only();
	var request:Dictionary = {"battle_id": state.active_battle_id, "node_id": state.current_node_id, "encounter_definition": state.get_node_encounter(state.current_node_id), "character_definition": state.definition.character_definition, "player_definition": state.definition.character_definition.combatant_definition, "owned_cards": cards, "current_health": state.current_health, "max_health": state.max_health, "selected_collection": state.selected_collection, "rng": state.random.battle};
	request.make_read_only();
	return request;

## 校验战斗身份、节点、生命和防重记录后提交结果，并进入失败、胜利或奖励阶段。
##
## 只有接受新结果时才推进命令步骤；普通胜利同时应用一次战后藏品治疗。
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

## 在步骤、阶段和候选有效时领取本轮卡牌奖励，返回是否成功推进。
func choose_reward(card:CardDefinition, token:int = -1)->bool:
	if not _token_matches(token) or state.status != RunState.RunStatus.CHOOSING_REWARD or state.reward_state == null or card == null or not state.reward_state.candidates.has(card):
		return false;
	return _consume_reward(card);

## 在步骤与奖励阶段有效时跳过本轮奖励，返回是否成功推进。
func skip_reward(token:int = -1)->bool:
	if not _token_matches(token) or state.status != RunState.RunStatus.CHOOSING_REWARD or state.reward_state == null:
		return false;
	return _consume_reward(null);

## 返回当前不期而遇的只读选项显示数据，不提交选择。
func get_option_view_data()->Array[Dictionary]:
	return UnexpectedEncounterExecutor.get_option_view_data(state);

## 返回指定不期而遇选项的候选卡牌，不重新抽样。
func get_unexpected_candidates(option_id:String)->Array[CardDefinition]:
	return UnexpectedEncounterExecutor.get_candidates(state, option_id);

## 返回当前不期而遇已提交结果的显示数据；没有结果时返回空字典。
func get_unexpected_result_view_data()->Dictionary:
	return UnexpectedEncounterExecutor.get_result_view_data(state);

## 在步骤令牌有效时提交指定选项及卡牌选择，成功后记录实际费用与收益并推进步骤。
func resolve_unexpected(option_id:String, card:CardDefinition = null, deck_index:int = -1, token:int = -1)->bool:
	if not _token_matches(token) or not state.resolve_unexpected_encounter(option_id, card, deck_index):
		return false;
	var result:Dictionary = state.unexpected_results[state.current_node_id].duplicate();
	result["command"] = "unexpected";
	_accept(result);
	return true;

## 在步骤令牌有效时离开已显示结果的不期而遇，完成节点并推进命令步骤。
func continue_unexpected(token:int = -1)->bool:
	if not _token_matches(token) or not state.continue_unexpected_encounter():
		return false;
	_accept({"command": "continue_unexpected"});
	return true;

## 领取或跳过本轮奖励，并在需要时提前准备下一轮候选。
##
## 最后一轮完成后归档奖励并完成节点；[param card] 为 [code]null[/code] 表示跳过。
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

## 使用本局内容随机流，从角色允许的奖励稀有度中抽取一轮不重复候选。
func _sample_reward()->Array[CardDefinition]:
	return CardPoolSampler.sample(state.definition.character_definition.reward_card_pool, state.definition.reward_option_count, CardPoolSampler.REWARD_RARITIES, state.random.run);

## 根据当前构筑稀有度保存只读候选；不在构筑阶段时保存空候选。
func _refresh_draft_candidates()->void:
	var candidates:Array[CardDefinition] = [];
	if state.status == RunState.RunStatus.DRAFTING:
		candidates = CardPoolSampler.filter_pool(state.definition.character_definition.reward_card_pool, [state.get_draft_rarity()]);
	candidates.make_read_only();
	state.draft_candidates = candidates;

## 返回状态已初始化且步骤令牌匹配的结果；[code]-1[/code] 表示不检查具体步骤。
func _token_matches(token:int)->bool:
	return state != null and (token == -1 or token == step_token);

## 递增步骤令牌，并将本次接受的命令结果设为只读后保存。
func _accept(result:Dictionary)->void:
	step_token += 1;
	result.make_read_only();
	last_command_result = result;
