## 用独立BattleSession评估真实规则，不加载战斗场景。历史复算只能在受保护副本执行。
extends SceneTree

var params:Dictionary
var controller:BattleSession
var character:CharacterDefinition = load("res://characters/data/warrior.tres")
var cards:Dictionary = {}
var raw:Array = []
var routes:Array = []
var failures:int = 0
var source_hashes:Dictionary = {}
var _incoming_cache:int = -1

func _initialize()->void:
	_run.call_deferred()

func _hash_sources(path:String)->void:
	for child in DirAccess.get_directories_at(path):
		_hash_sources(path.path_join(child))
	for child in DirAccess.get_files_at(path):
		if child.ends_with(".gd") or child.ends_with(".tres"):
			var file:String = path.path_join(child)
			source_hashes[file.trim_prefix("res://")] = FileAccess.get_sha256(file)

func _base_deck()->Array[CardDefinition]:
	var deck:Array[CardDefinition] = []
	for entry in character.starting_deck_entries:
		for _n in range(entry.count):
			deck.append(entry.card_definition)
	return deck

func _deck_ids(deck:Array[CardDefinition])->Array[String]:
	var result:Array[String] = []
	for card in deck:
		result.append(card.card_id)
	return result

func _incoming()->int:
	if _incoming_cache >= 0:
		return _incoming_cache
	var state:BattleState = controller.battle_state
	var values:Array[int] = AttackDamageResolver.preview_effect_damage(state.enemy_state.current_action.effects, state.enemy_state, state.player_state, 0)
	var damage:int = 0
	for i in range(values.size()):
		if state.enemy_state.current_action.effects[i].effect_type == CombatEffectDefinition.EffectType.DAMAGE:
			damage += values[i] * state.enemy_state.current_action.effects[i].repeat_count
	_incoming_cache = damage
	return damage

func _score(card:CardInstance)->float:
	var state:BattleState = controller.battle_state
	var p:CombatantState = state.player_state
	var e:EnemyState = state.enemy_state
	var cost:int = card.current_energy_cost
	var horizon:float = clampf(e.current_health / 12.0, 1.0, 4.0)
	var defense_weight:float = 1.6 if p.current_health <= _incoming() * 2 else 1.0
	var score:float = 0.0
	var extra_block:int = 0
	var damage:int = 0
	var previews:Array[int] = AttackDamageResolver.preview_effect_damage(card.definition.effects, p, e, p.current_block)
	for i in range(card.definition.effects.size()):
		var effect:CombatEffectDefinition = card.definition.effects[i]
		var amount:int = effect.amount * effect.repeat_count
		match effect.effect_type:
			CombatEffectDefinition.EffectType.DAMAGE:
				damage += previews[i] * effect.repeat_count
				if effect.heals_from_damage:
					score += minf(p.max_health - p.current_health, maxi(0, damage - e.current_block)) / 5.0
			CombatEffectDefinition.EffectType.BLOCK:
				extra_block += amount
			CombatEffectDefinition.EffectType.DRAW:
				if not state.draw_blocked_this_turn:
					score += minf(amount, state.max_hand_size - state.hand.size() + 1) * (0.65 if state.current_available_energy > cost else 0.1)
			CombatEffectDefinition.EffectType.GAIN_ENERGY:
				score += amount * minf(1.0, state.hand.size() / 3.0)
			CombatEffectDefinition.EffectType.ENHANCE_WEAPON:
				var weapon:WeaponInstance = state.equipped_weapon.weapon
				score += (amount * minf(horizon, weapon.current_durability + effect.durability_bonus) + weapon.current_attack * minf(effect.durability_bonus, horizon)) / 6.0
			CombatEffectDefinition.EffectType.LOSE_HEALTH:
				score -= amount / 5.0
				if amount >= p.current_health:
					return -1000.0
			CombatEffectDefinition.EffectType.LOSE_MAX_HEALTH:
				score -= amount * 0.3
			CombatEffectDefinition.EffectType.GAIN_STRENGTH:
				score += amount * horizon * 2.0 / 6.0
			CombatEffectDefinition.EffectType.APPLY_WEAK:
				score += _incoming() * 0.25 * minf(amount, horizon) / 5.0 if e.weak_turns == 0 else 0.1
			CombatEffectDefinition.EffectType.APPLY_VULNERABLE:
				score += 6.0 * minf(amount, horizon) / 6.0 if e.vulnerable_turns == 0 else 0.1
			CombatEffectDefinition.EffectType.APPLY_POWER:
				if effect.power_definition.power_type == PowerDefinition.PowerType.RETAIN_BLOCK:
					score += horizon * 0.6 if not p.has_power(PowerDefinition.PowerType.RETAIN_BLOCK) else 0.0
				else:
					score += horizon * (effect.power_definition.block_gain / 5.0 - effect.power_definition.health_loss / 5.0) * 0.7
			CombatEffectDefinition.EffectType.PREVENT_DRAW:
				score -= 0.1
			CombatEffectDefinition.EffectType.GAIN_ATTACK_CARD_ENERGY:
				for other in state.hand:
					if other != card and other.definition.card_type == CardDefinition.CardType.ATTACK:
						score += amount * 0.7
			_:
				push_error("未建模的策略效果")
				failures += 1
	var useful_damage:int = mini(e.current_health, maxi(0, damage - e.current_block))
	score += useful_damage / 6.0 + minf(damage, e.current_block) / 12.0
	if useful_damage >= e.current_health:
		score += 1000.0
	var useful_block:int = mini(extra_block, maxi(0, _incoming() - p.current_block))
	score += useful_block / 5.0 * defense_weight
	if p.has_power(PowerDefinition.PowerType.RETAIN_BLOCK):
		score += (extra_block - useful_block) / 5.0 * 0.5
	if card.weapon != null:
		if state.equipped_weapon == null:
			score += card.weapon.current_attack * minf(horizon, card.weapon.max_durability) / 6.0
		else:
			return -1.0 # 保留现有武器，策略不主动换装；局限在报告中说明。
	return score / maxf(1.0, cost)

func _weapon_score()->float:
	var state:BattleState = controller.battle_state
	if state.equipped_weapon == null or not state.weapon_attack_available:
		return -1.0
	var w:WeaponInstance = state.equipped_weapon.weapon
	var damage:int = AttackDamageResolver.calculate(w.current_attack, state.player_state.strength, state.player_state.weak_turns > 0, state.enemy_state.vulnerable_turns > 0)
	if not w.definition.ignores_block:
		damage = maxi(0, damage - state.enemy_state.current_block)
	return 1000.0 if damage >= state.enemy_state.current_health else damage / 6.0 + 0.05

func _make_encounter(enemy_id:String, enemy_hp:int)->EncounterDefinition:
	var encounter:EncounterDefinition = load("res://battle/data/encounters/%s_encounter.tres" % enemy_id).duplicate()
	var enemy:EnemyDefinition = encounter.enemy_definition.duplicate()
	enemy.max_health = enemy_hp
	encounter.enemy_definition = enemy
	return encounter

func _battle(group:String, label:String, deck:Array[CardDefinition], enemy_id:String, hp:int, max_hp:int, enemy_hp:int, random_seed:int, bound_encounter:EncounterDefinition = null, collection:CollectionDefinition = null)->Dictionary:
	var battle_rng:RandomNumberGenerator = RandomNumberGenerator.new()
	battle_rng.seed = random_seed
	controller.configure_context("%s:%s:%d" % [group, label, random_seed], "", battle_rng)
	var encounter:EncounterDefinition = _make_encounter(enemy_id, enemy_hp) if bound_encounter == null else bound_encounter
	if not controller.start_battle(encounter, character.combatant_definition, deck, hp, max_hp, collection):
		failures += 1
		return {}
	var state:BattleState = controller.battle_state
	var log:Array = []
	var played:Dictionary = {}
	var hp_deductions:int = 0
	var healing:int = 0
	var energy_spent:int = 0
	var stopped:bool = false
	while state.current_phase != BattleState.BattlePhase.FINISHED and state.current_turn_number <= int(params.maximum_rounds):
		var record:Dictionary = {"turn":state.current_turn_number, "start_health":state.player_state.current_health, "start_enemy_health":state.enemy_state.current_health, "intent":state.enemy_state.current_action.action_id, "plays":[]}
		var actions:int = 0
		while state.current_phase == BattleState.BattlePhase.PLAYER_TURN:
			# 同一次选牌期间状态不变，复用意图预览；每次操作后下一步重新计算。
			_incoming_cache = -1
			var chosen:CardInstance = null
			var best:float = 0.001
			for card in state.hand:
				if controller.can_play_card(card):
					var value:float = _score(card)
					if value > best:
						best = value
						chosen = card
			var before:int = state.player_state.current_health
			if _weapon_score() > best:
				controller.attack_with_weapon()
				record.plays.append("weapon_attack")
			elif chosen != null:
				var id:String = chosen.definition.card_id
				energy_spent += chosen.current_energy_cost
				played[id] = int(played.get(id,0)) + 1
				record.plays.append(id)
				controller.play_card(chosen)
			else:
				break
			hp_deductions += maxi(0, before - state.player_state.current_health)
			healing += maxi(0, state.player_state.current_health - before)
			actions += 1
			if actions >= int(params.maximum_actions_per_turn) or state.resolving_card != null:
				stopped = true
				break
		var before_end:int = state.player_state.current_health
		if state.current_phase != BattleState.BattlePhase.FINISHED and not stopped:
			controller.end_turn()
		if not stopped and state.current_phase != BattleState.BattlePhase.FINISHED and (state.current_phase != BattleState.BattlePhase.PLAYER_TURN or state.current_turn_number <= int(record.turn)):
			push_error("战斗未推进到下一玩家回合：%s，回合%d" % [enemy_id,record.turn])
			stopped = true
		hp_deductions += maxi(0, before_end - state.player_state.current_health)
		healing += maxi(0, state.player_state.current_health - before_end)
		record["end_health"] = state.player_state.current_health
		record["end_max_health"] = state.player_state.max_health
		record["end_enemy_health"] = state.enemy_state.current_health
		log.append(record)
		if stopped:
			break
	var victory:bool = state.is_victory() and not state.is_defeat()
	var outcome:String = "胜利" if victory else ("失败" if state.is_defeat() else "窗口耗尽")
	var result:Dictionary = {"group":group,"label":label,"enemy_id":enemy_id,"enemy_initial_health":enemy_hp,"player_initial_health":hp,"player_initial_max_health":max_hp,"seed":random_seed,"deck":_deck_ids(deck),"collection_id":"none" if collection == null else collection.collection_id,"outcome":outcome,"victory":victory,"remaining_health":state.player_state.current_health,"remaining_max_health":state.player_state.max_health,"remaining_enemy_health":state.enemy_state.current_health,"net_health_loss":hp-state.player_state.current_health,"hp_deductions":hp_deductions,"positive_health_recovery":healing,"max_health_loss":max_hp-state.player_state.max_health,"turns":log.size(),"energy_spent":energy_spent,"played":played,"trace":log}
	if outcome == "窗口耗尽":
		failures += 1
	raw.append(result)
	return result

func _draft(random_seed:int)->Array[CardDefinition]:
	seed(random_seed)
	var deck:Array[CardDefinition] = _base_deck()
	for rarity in [3, 2, 1]:
		var candidates:Array[CardDefinition] = CardPoolSampler.sample(character.reward_card_pool, 3, [rarity])
		deck.append(candidates[0]) # 中立选择候选第一张，避免把特定选牌偏好当作所有玩家。
	return deck

func _setup_evaluator()->void:
	params = JSON.parse_string(FileAccess.get_file_as_string("res://综合数值模型/评估参数.json"))
	for folder in ["battle", "cards", "combatants", "characters", "run", "collections", "综合数值模型"]:
		_hash_sources("res://" + folder)
	controller = BattleSession.new()
	for source:String in ["tests/fixtures/phase5_run.tres", "tests/fixtures/phase5_map.tres", "tools/history_guard.gd"]:
		source_hashes[source] = FileAccess.get_sha256("res://" + source)
	for entry in character.starting_deck_entries:
		cards[entry.card_definition.card_id] = entry.card_definition
	for card in character.reward_card_pool:
		cards[card.card_id] = card

func _historical_route(random_seed:int, heal:int)->Dictionary:
	# 控制参照保留旧拓扑与旧敌人，恢复量只取一次休整，不累加未经过的支线。
	var deck:Array[CardDefinition] = _draft(random_seed)
	var hp:int = character.combatant_definition.max_health
	var max_hp:int = hp
	var route:Dictionary = {"scenario":"historical_reference", "normal_battles":1, "route_id":"historical", "seed":random_seed, "starting_deck":_deck_ids(deck), "node_ids":[], "normal_enemy_ids":["cave_crawler"], "boss_enemy_id":"ruin_guard", "battles":[], "reward_cards":[], "rest_healing":0, "rest_config_heal":heal, "boss_entry_health":0, "boss_reached":false}
	var normal:EnemyDefinition = load("res://combatants/enemies/data/cave_crawler.tres")
	var fight:Dictionary = _battle("route", "历史连续遭遇", deck, normal.combatant_id, hp, max_hp, normal.max_health, random_seed+100)
	route.battles.append(fight)
	hp = fight.remaining_health
	max_hp = fight.remaining_max_health
	if fight.victory:
		seed(random_seed+200)
		var reward:Array[CardDefinition] = CardPoolSampler.sample(character.reward_card_pool, 3, CardPoolSampler.REWARD_RARITIES)
		deck.append(reward[0])
		route.reward_cards.append(reward[0].card_id)
		route.rest_healing = mini(heal, max_hp-hp)
		hp += int(route.rest_healing)
		route.boss_entry_health = hp
		route.boss_reached = true
		var boss:EnemyDefinition = load("res://combatants/enemies/data/ruin_guard.tres")
		fight = _battle("route", "历史连续遭遇", deck, boss.combatant_id, hp, max_hp, boss.max_health, random_seed+300)
		route.battles.append(fight)
		hp = fight.remaining_health
		max_hp = fight.remaining_max_health
	route["victory"] = route.boss_reached and fight.victory
	route["remaining_health"] = hp
	route["remaining_max_health"] = max_hp
	return route

func _branch_route(definition:RunDefinition, random_seed:int, route_id:String, collection:CollectionDefinition = null, starting_deck:Array[CardDefinition] = [])->Dictionary:
	# 地图先按独立种子生成并保存，再按同一开局种子抽牌；不依赖进入节点时再随机。
	assert(definition.reward_selection_count == 1)
	var map_seed:int = random_seed+400000
	seed(map_seed)
	var run_state:RunState = RunState.new()
	assert(run_state.run_state_init(definition))
	# 六牌诊断先合法完成三轮构筑，再替换局内牌组；它不是正式开局选项。
	var deck:Array[CardDefinition] = _draft(random_seed) if starting_deck.size() != _base_deck().size()+RunDefinition.DRAFT_RARITIES.size() else starting_deck
	for index in range(_base_deck().size(), deck.size()):
		assert(run_state.choose_starting_card(deck[index]))
	if not starting_deck.is_empty():
		run_state.owned_cards = starting_deck.duplicate()
	var start_id:String = definition.map_definition.starting_node_ids[0]
	assert(run_state.enter_node(start_id))
	if collection == null:
		assert(definition.collection_pool.is_empty())
		assert(run_state.complete_current_node())
	else:
		assert(definition.collection_pool.has(collection))
		assert(run_state.begin_collection_selection())
		assert(run_state.choose_collection(collection))
	assert(not run_state.is_invalid())
	var branch_ids:Array[String] = definition.map_definition.get_route_node_ids(route_id)
	assert(branch_ids.size() == 3)
	var rest:MapNodeDefinition = definition.map_definition.get_node_by_id(branch_ids[2])
	var boss_id:String = rest.next_node_ids[0]
	var boss:EncounterDefinition = run_state.get_node_encounter(boss_id)
	var normal_ids:Array[String] = []
	for node_id in branch_ids.slice(0, 2):
		normal_ids.append(run_state.get_node_encounter(node_id).enemy_definition.combatant_id)
	var node_ids:Array[String] = [start_id]
	node_ids.append_array(branch_ids)
	node_ids.append(boss_id)
	var bindings:Dictionary = {}
	for node in definition.map_definition.nodes:
		if node.requires_encounter():
			bindings[node.node_id] = run_state.get_node_encounter(node.node_id).enemy_definition.combatant_id
	var route:Dictionary = {"scenario":"branch_map", "normal_battles":2, "route_id":route_id, "seed":random_seed, "map_seed":map_seed, "starting_deck":_deck_ids(run_state.owned_cards), "initial_health":run_state.current_health, "initial_max_health":run_state.max_health, "collection_id":"none" if collection == null else collection.collection_id, "node_ids":node_ids, "encounter_bindings":bindings, "normal_enemy_ids":normal_ids, "boss_enemy_id":boss.enemy_definition.combatant_id, "planned_battle_seeds":[random_seed+100,random_seed+101,random_seed+300], "planned_reward_seeds":[random_seed+200,random_seed+201], "battles":[], "reward_cards":[], "collection_healing":0, "collection_heals":[], "rest_healing":0, "rest_config_heal":rest.heal_amount, "rest_health_before":0, "rest_health_after":0, "rest_max_health":0, "boss_entry_health":0, "boss_reached":false}
	for step in range(2):
		assert(run_state.enter_node(branch_ids[step]))
		var encounter:EncounterDefinition = run_state.get_node_encounter(branch_ids[step])
		var enemy:EnemyDefinition = encounter.enemy_definition
		var fight:Dictionary = _battle("route", "当前分支遭遇", run_state.owned_cards, enemy.combatant_id, run_state.current_health, run_state.max_health, enemy.max_health, random_seed+100+step, encounter, run_state.selected_collection)
		route.battles.append(fight)
		run_state.current_health = fight.remaining_health
		run_state.max_health = fight.remaining_max_health
		if not fight.victory:
			assert(run_state.mark_defeat())
			break
		var before_heal:int = run_state.current_health
		var collection_heal:int = run_state.apply_normal_victory_collection()
		route.collection_healing += collection_heal
		route.collection_heals.append({"node_id":branch_ids[step], "before_health":before_heal, "max_health":run_state.max_health, "amount":collection_heal, "after_health":run_state.current_health})
		seed(random_seed+200+step)
		var reward:Array[CardDefinition] = CardPoolSampler.sample(character.reward_card_pool, definition.reward_option_count, CardPoolSampler.REWARD_RARITIES)
		assert(run_state.add_card(reward[0]))
		route.reward_cards.append(reward[0].card_id)
		assert(run_state.complete_current_node())
	if run_state.status == RunState.RunStatus.IN_PROGRESS:
		assert(run_state.enter_node(rest.node_id))
		route.rest_health_before = run_state.current_health
		route.rest_max_health = run_state.max_health
		route.rest_healing = run_state.heal(rest.heal_amount)
		route.rest_health_after = run_state.current_health
		assert(run_state.complete_current_node())
		assert(run_state.enter_node(boss_id))
		route.boss_entry_health = run_state.current_health
		route.boss_reached = true
		var fight:Dictionary = _battle("route", "当前分支遭遇", run_state.owned_cards, boss.enemy_definition.combatant_id, run_state.current_health, run_state.max_health, boss.enemy_definition.max_health, random_seed+300, boss, run_state.selected_collection)
		route.battles.append(fight)
		run_state.current_health = fight.remaining_health
		run_state.max_health = fight.remaining_max_health
		if fight.victory:
			assert(run_state.complete_current_node())
			assert(run_state.mark_victory())
		else:
			assert(run_state.mark_defeat())
	route["victory"] = run_state.status == RunState.RunStatus.VICTORY
	route["remaining_health"] = run_state.current_health
	route["remaining_max_health"] = run_state.max_health
	route["completed_node_ids"] = run_state.completed_node_ids.duplicate()
	assert(not run_state.is_invalid())
	return route

func _run()->void:
	if not preload("res://tools/history_guard.gd").require_sandbox():
		quit(2)
		return
	_setup_evaluator()
	var player_base_health:int = character.combatant_definition.max_health
	var normal_health:int = (load("res://combatants/enemies/data/cave_crawler.tres") as EnemyDefinition).max_health
	var boss_health:int = (load("res://combatants/enemies/data/ruin_guard.tres") as EnemyDefinition).max_health
	var reference:Array[CardDefinition] = _base_deck()
	for id in params.reference_deck:
		reference.append(cards[id])
	for id in ["cave_crawler", "ruin_guard"]:
		var hp:int = normal_health if id == "cave_crawler" else boss_health
		for n in range(int(params.samples)):
			var s:int = int(params.seed_start) + n
			_battle("baseline","基础6张",_base_deck(),id,player_base_health,player_base_health,hp,s)
			_battle("reference","参考9张",reference,id,player_base_health,player_base_health,hp,s)
			for card_id in cards:
				var deck:Array[CardDefinition] = _base_deck()
				deck.append(cards[card_id])
				_battle("card",card_id,deck,id,player_base_health,player_base_health,hp,s)
			_battle("draft","随机合法开局",_draft(s),id,player_base_health,player_base_health,hp,s)
		print("已完成单卡与牌组：%s" % id)
		await process_frame
	for player_hp in params.player_health_grid:
		for boss_hp in params.boss_health_grid:
			for n in range(int(params.samples)):
				_battle("sensitivity","参考9张",reference,"ruin_guard",player_hp,player_hp,boss_hp,int(params.seed_start)+n)
				_battle("sensitivity","基础6张",_base_deck(),"ruin_guard",player_hp,player_hp,boss_hp,int(params.seed_start)+n)
		print("已完成血量敏感性：玩家%d" % player_hp)
		await process_frame
	# 主基准显式保持无藏品，避免新必选状态改变历史比较的观察口径。
	var definition:RunDefinition = load("res://tests/fixtures/phase5_run.tres").duplicate()
	definition.collection_pool = []
	assert(not definition.is_invalid())
	var route_ids:Array[String] = ["a", "b", "c"]
	assert(int(params.proposed_route_battles) == 2)
	var heal:int = definition.map_definition.get_node_by_id("route_a_rest").heal_amount
	for n in range(int(params.samples)):
		var s:int = int(params.seed_start)+n
		routes.append(_historical_route(s, heal))
		routes.append(_branch_route(definition, s, route_ids[n % route_ids.size()]))
	print("已完成连续遭遇：历史参照与真实随机分支各%d局" % int(params.samples))
	await process_frame
	var output:Dictionary = {"parameters":params,"source_hashes":source_hashes,"godot_version":Engine.get_version_info().string,"battle_random_source":"RandomNumberGenerator/Fisher-Yates","battle_count":raw.size(),"failures":failures,"battles":raw,"routes":routes}
	var file:FileAccess = FileAccess.open("res://综合数值模型/原始战斗数据.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	file.close()
	print("综合战斗评估完成：%d场，异常%d" % [raw.size(),failures])
	controller.dispose()
	await process_frame
	quit(0 if failures == 0 else 1)
