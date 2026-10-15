## 场景无关的单场战斗规则入口。同步结算只改变模型；视图与动画由调用者处理。
class_name BattleSession
extends RefCounted

signal actual_result(event:BattleEvent)
signal state_changed
signal battle_finished(result:BattleResult)

var battle_state:BattleState
var action_queue:ActionQueue = ActionQueue.new()
var selected_collection:CollectionDefinition
var battle_id:String = ""
var node_id:String = ""
var _rng:RandomNumberGenerator = RandomNumberGenerator.new()
var _result:BattleResult
var _active:bool = false
var _disposed:bool = false
var _command_active:bool = false
var _sequence:int = 0
var _event_source:StringName = &"battle"
var _configured_battle_id:String = ""
var _configured_node_id:String = ""
var _configured_rng:RandomNumberGenerator

func _init()->void:
	_rng.randomize()

## 准备期间只保存随机源，激活后的洗牌才消费它。
func configure_context(identity:String, owner_node_id:String, rng:RandomNumberGenerator = null)->void:
	_configured_battle_id = identity
	_configured_node_id = owner_node_id
	_configured_rng = rng

func prepare(
	encounter:EncounterDefinition,
	player_definition:CombatantDefinition,
	deck_definitions:Array[CardDefinition],
	starting_player_health:int,
	starting_player_max_health:int,
	new_collection:CollectionDefinition = null
)->bool:
	if _command_active:
		return false
	if encounter == null:#没有遭遇时无法确定敌人和单场规则
		push_error("遭遇定义为空，无法开始战斗");#报告流程控制器没有传入地图节点的遭遇
		return false;#空遭遇不能成为战斗的静态数据源
	if encounter.is_invalid():#EncounterDefinition负责验证敌人与所有单场规则
		push_error("遭遇定义无效，无法开始战斗");#补充外部战斗入口的错误上下文
		return false;#非法静态规则不能进入运行时战斗
	if player_definition == null:#外部流程必须明确提供本局使用的玩家定义
		push_error("玩家定义为空，无法开始战斗");#报告无法创建玩家运行时状态
		return false;#空玩家定义不能用于创建本场CombatantState
	if player_definition.is_invalid():#玩家ID、名称、最大生命和原画必须完整合法
		push_error("玩家定义无效，无法开始战斗");#补充玩家运行时初始化上下文
		return false;#非法定义不能成为CombatantState的数据源
	if starting_player_health <= 0:#0生命表示整局已失败，不能进入下一场战斗
		push_error("战斗起始生命必须大于0");#报告流程层尝试使用死亡玩家启动战斗
		return false;#非正数生命不能写入新CombatantState
	if starting_player_max_health <= 0 or starting_player_health > starting_player_max_health:
		push_error("战斗起始生命不能超过玩家最大生命");#报告RunState回写或治疗计算可能已损坏
		return false;#不通过静默截断掩盖外部状态错误
	if new_collection != null and new_collection.is_invalid():
		push_error("藏品定义无效，无法开始战斗");
		return false;

	var new_player_state:CombatantState = CombatantState.new();#为本场战斗创建全新玩家生命与格挡状态
	if not new_player_state.combatant_init_from_definition(player_definition):#先从外部玩家定义建立最大生命和显示数据
		push_error("玩家状态初始化失败，无法开始战斗");#报告运行时玩家创建失败
		return false;#不使用未完整初始化的CombatantState
	new_player_state.max_health = starting_player_max_health;# 使用本局实际上限，不修改角色静态定义。
	if not new_player_state.set_current_health(starting_player_health):#再把RunState保存的剩余生命写入新玩家状态
		push_error("玩家剩余生命设置失败，无法开始战斗");#补充跨战斗生命注入阶段的上下文
		return false;#生命设置失败时不继续构建敌人或牌组

	var new_enemy_state:EnemyState = EnemyState.new();#每场战斗都使用新的敌人生命、格挡和行动下标
	if not new_enemy_state.enemy_state_init(encounter.enemy_definition):#敌人内容只来自当前地图节点传入的遭遇
		push_error("敌人状态初始化失败，无法开始战斗");#报告敌人定义或行动模式初始化失败
		return false;#缺少合法当前意图的敌人不能进入战斗

	var new_deck:Array[CardInstance] = _create_deck_from_definitions(
		deck_definitions
	);#按本局实际拥有的每个定义创建一张独立运行时卡牌
	if new_deck.is_empty():#输入非法或任意实例创建失败都会得到空数组
		push_error("战斗牌组创建失败，无法开始战斗");#补充整场战斗初始化阶段的错误上下文
		return false;#不允许空牌组或半成品牌组进入BattleState

	var new_battle_state:BattleState = BattleState.new();#在局部变量中组装本场战斗的唯一运行时数据源
	if not new_battle_state.battle_state_init(
		new_player_state,
		new_enemy_state,
		new_deck,
		encounter.energy_per_turn,
		encounter.cards_per_turn,
		encounter.max_hand_size
	):#单场能量、抽牌和手牌上限规则仍只来自EncounterDefinition
		push_error("战斗状态初始化失败，无法开始战斗");#报告运行时组装未通过BattleState验证
		return false;#局部半成品不会覆盖控制器当前的battle_state

	_disconnect_actual_events()
	battle_id = _configured_battle_id
	node_id = _configured_node_id
	if _configured_rng != null:
		_rng = _configured_rng
	battle_state = new_battle_state
	battle_state.set_random_source(_rng)
	selected_collection = new_collection
	action_queue.clear_actions()
	_result = null
	_active = false
	_disposed = false
	_sequence = 0
	_bind_actual_events()
	return true

func activate()->bool:
	if battle_state == null or _active or _disposed or _result != null:
		return false
	_active = true
	_command_active = true
	_event_source = &"player"
	if selected_collection != null and selected_collection.effect_type == CollectionDefinition.EffectType.STARTING_STRENGTH:
		battle_state.player_state.gain_strength(selected_collection.amount)
	_start_player_turn()
	_command_active = false
	state_changed.emit()
	return true

func start_battle(encounter:EncounterDefinition, player:CombatantDefinition, deck:Array[CardDefinition], health:int, max_health:int, collection:CollectionDefinition = null)->bool:
	return prepare(encounter, player, deck, health, max_health, collection) and activate()

func get_result()->BattleResult:
	return _result

func is_active()->bool:
	return _active

func random_seed()->int:
	return _rng.seed

func player_operation_failure()->StringName:
	if battle_state == null or not _active or _disposed:
		return &"not_started"
	if _result != null or battle_state.is_victory() or battle_state.is_defeat():
		return &"finished"
	if _command_active or battle_state.resolving_card != null:
		return &"busy"
	if battle_state.current_phase != BattleState.BattlePhase.PLAYER_TURN:
		return &"not_player_turn"
	return &""

func card_play_failure(card:CardInstance)->StringName:
	var failure:StringName = player_operation_failure()
	if failure != &"":
		return failure
	if card == null or not battle_state.hand.has(card):
		return &"not_in_hand"
	if not card.can_afford(battle_state.current_available_energy):
		return &"not_enough_energy"
	for effect in card.definition.effects:
		if effect.effect_type == CombatEffectDefinition.EffectType.ENHANCE_WEAPON and battle_state.equipped_weapon == null:
			return &"no_weapon"
	if not _meets_effect_requirements(card):
		return &"max_health_cost"
	return &""

func can_play_card(card:CardInstance)->bool:
	return card_play_failure(card) == &""

func weapon_attack_failure()->StringName:
	var failure:StringName = player_operation_failure()
	if failure != &"":
		return failure
	if battle_state.equipped_weapon == null:
		return &"no_weapon"
	if not battle_state.weapon_attack_available:
		return &"weapon_spent"
	return &""

func can_attack_with_weapon()->bool:
	return weapon_attack_failure() == &""

func can_end_turn()->bool:
	return player_operation_failure() == &""

func card_description(card:CardInstance)->String:
	return BattleDisplay.card_description(battle_state, card)

func enemy_intent_text()->String:
	return BattleDisplay.enemy_intent_text(battle_state)

func weapon_attack_tooltip()->String:
	return BattleDisplay.weapon_attack_tooltip(battle_state)

func play_card(card:CardInstance)->bool:
	if not can_play_card(card):
		return false
	_command_active = true
	_event_source = &"player"
	action_queue.clear_actions()
	if not _queue_card_effect(card) or not battle_state.begin_card_play(card):
		action_queue.clear_actions()
		_command_active = false
		return false
	if not action_queue.resolve_all():
		action_queue.clear_actions()
		push_error("卡牌行为没有完整执行")
		# 已提交的部分效果和费用保留，resolving_card继续阻止后续命令。
	else:
		battle_state.finish_card_play()
		_check_battle_result()
	_command_active = false
	state_changed.emit()
	return true

func attack_with_weapon()->bool:
	if not can_attack_with_weapon():
		return false
	_command_active = true
	_event_source = &"player"
	var accepted:bool = battle_state.attack_with_weapon()
	if accepted:
		_record(&"weapon_attack", 1, &"weapon")
		_check_battle_result()
	_command_active = false
	if accepted:
		state_changed.emit()
	return accepted

func end_turn()->bool:
	# 兼容外部状态验证：真实胜负已产生时只提交结果，不再推进敌人。
	if _active and not _disposed and not _command_active and battle_state.resolving_card == null and _result == null:
		if _check_battle_result():
			state_changed.emit()
			return false
	if not can_end_turn():
		return false
	_command_active = true
	battle_state.current_phase = BattleState.BattlePhase.ENEMY_TURN
	battle_state.attack_card_energy_this_turn = 0
	battle_state.discard_hand_at_turn_end()
	_run_enemy_turn()
	_command_active = false
	state_changed.emit()
	return true

func check_battle_result()->bool:
	if _disposed:
		return _result != null
	if _command_active:
		return false
	var finished:bool = _check_battle_result()
	if finished:
		state_changed.emit()
	return finished

func _finish(victory:bool)->void:
	if battle_state == null or _result != null:
		return
	if (victory and not battle_state.is_victory()) or (not victory and not battle_state.is_defeat()):
		push_error("战斗结果与真实状态不一致")
		return
	battle_state.current_phase = BattleState.BattlePhase.FINISHED
	action_queue.clear_actions()
	_result = BattleResult.new()
	_result.battle_id = battle_id
	_result.node_id = node_id
	_result.victory = victory
	_result.player_health = battle_state.player_state.current_health
	_result.player_max_health = battle_state.player_state.max_health
	battle_finished.emit(_result)

func _bind_actual_events()->void:
	battle_state.player_state.presentation_result.connect(_on_combatant_result.bind(&"player", battle_state.player_state.get_instance_id()))
	battle_state.enemy_state.presentation_result.connect(_on_combatant_result.bind(&"enemy", battle_state.enemy_state.get_instance_id()))
	battle_state.presentation_result.connect(_on_state_result.bind(battle_state.get_instance_id()))

func _disconnect_actual_events()->void:
	if battle_state == null:
		return
	for pair:Array in [[battle_state.player_state, &"player"], [battle_state.enemy_state, &"enemy"]]:
		var handler:Callable = _on_combatant_result.bind(pair[1], pair[0].get_instance_id())
		if pair[0].presentation_result.is_connected(handler):
			pair[0].presentation_result.disconnect(handler)
	var handler:Callable = _on_state_result.bind(battle_state.get_instance_id())
	if battle_state.presentation_result.is_connected(handler):
		battle_state.presentation_result.disconnect(handler)

func _on_combatant_result(kind:StringName, amount:int, target:StringName, source_instance_id:int)->void:
	if battle_state == null or _result != null:
		return
	var current:CombatantState = battle_state.player_state if target == &"player" else battle_state.enemy_state
	if current.get_instance_id() == source_instance_id:
		_record(kind, amount, target)

func _on_state_result(kind:StringName, amount:int, source_instance_id:int)->void:
	if battle_state == null or _result != null or battle_state.get_instance_id() != source_instance_id:
		return
	_record(kind, amount, &"energy" if kind == &"energy" else &"weapon")

func _record(kind:StringName, amount:int, target:StringName)->void:
	_sequence += 1
	var event:BattleEvent = BattleEvent.new()
	event.battle_id = battle_id
	event.sequence = _sequence
	event.source_id = _event_source
	event.target_id = target
	event.kind = kind
	event.amount = amount
	actual_result.emit(event)

func dispose()->void:
	_disposed = true
	_active = false
	_disconnect_actual_events()
	if not _command_active:
		action_queue.clear_actions()

func _meets_effect_requirements(card:CardInstance)->bool:
	var max_health_cost:int = 0;
	for effect in card.definition.effects:
		if effect.effect_type == CombatEffectDefinition.EffectType.ENHANCE_WEAPON and battle_state.equipped_weapon == null:
			return false;
		if effect.effect_type == CombatEffectDefinition.EffectType.LOSE_MAX_HEALTH:
			max_health_cost += effect.amount * effect.repeat_count;
	return battle_state.player_state.max_health > max_health_cost;

func _create_card_instance(definition:CardDefinition)->CardInstance:
	if definition == null:#没有卡牌定义，就无法确定名称、费用和效果数值
		push_error("卡牌定义为空，无法创建卡牌实例");
		return null;

	var new_card_instance:CardInstance = CardInstance.new();#先创建一张尚未填入定义的运行时卡牌
	if not new_card_instance.card_instance_init(definition):#验证定义，并复制初始费用
		push_error("卡牌实例初始化失败");
		return null;

	return new_card_instance;#只有完整初始化后才交给调用者

func _create_deck_from_definitions(
	deck_definitions:Array[CardDefinition]
)->Array[CardInstance]:
	var new_deck:Array[CardInstance] = [];#局部保存当前正在构建的全部独立卡牌实例
	if deck_definitions.is_empty():#无卡牌时无法创建当前阶段要求的可用战斗牌组
		push_error("卡牌定义数组为空，无法创建战斗牌组");#报告外部流程没有传入本局实际拥有的卡牌
		return new_deck;#保持空数组，让战斗初始化统一中止

	for card_definition in deck_definitions:#按原数组顺序创建并验证每张卡的独立实例
		var card_instance:CardInstance = _create_card_instance(card_definition);#每次循环都会创建一个新CardInstance
		if card_instance == null:#任意一张卡创建失败都会使整副战斗牌组不完整
			push_error("战斗牌组中的卡牌实例创建失败");#报告已进入运行时实例创建阶段
			return [];#丢弃局部半成品，不把缺牌的牌组交给BattleState

		new_deck.append(card_instance);#一个输入元素只对应追加一个已完整初始化的新实例

	return new_deck;#成功时元素数量与deck_definitions一致，并保留输入顺序

func _queue_card_effect(card:CardInstance)->bool:
	return _queue_effect_list(card.definition.effects, battle_state.player_state, battle_state.enemy_state);

func _queue_effect_list(
	effects:Array[CombatEffectDefinition],
	actor_state:CombatantState,
	opponent_state:CombatantState
)->bool:
	for effect in effects:
		if not _queue_single_effect(effect, actor_state, opponent_state):
			action_queue.clear_actions();
			return false;
	return true;

func _queue_single_effect(
	effect:CombatEffectDefinition,
	actor_state:CombatantState,
	opponent_state:CombatantState
)->bool:
	var effect_target:CombatantState = actor_state;#SELF默认选择效果行动者自己
	if effect.target_type == CombatEffectDefinition.TargetType.OPPONENT:#OPPONENT要求切换到行动者的对手
		effect_target = opponent_state;#保存本项效果的实际角色目标

	for _repeat_index in range(effect.repeat_count):#每次循环都加入一次独立行为，保留多段效果语义
		var queued_successfully:bool = false;#记录当前这一段效果是否成功进入队列
		match effect.effect_type:#把静态效果类型翻译为ActionQueue支持的基础行为
			CombatEffectDefinition.EffectType.DAMAGE:#伤害效果作用于选择出的角色目标
				queued_successfully = action_queue.queue_damage_effect(actor_state,effect_target,effect);
			CombatEffectDefinition.EffectType.GAIN_STRENGTH:
				queued_successfully = action_queue.queue_gain_strength(effect_target,effect.amount);
			CombatEffectDefinition.EffectType.APPLY_WEAK:
				queued_successfully = action_queue.queue_weak(effect_target,effect.amount,actor_state == battle_state.enemy_state);
			CombatEffectDefinition.EffectType.APPLY_VULNERABLE:
				queued_successfully = action_queue.queue_vulnerable(effect_target,effect.amount,actor_state == battle_state.enemy_state);
			CombatEffectDefinition.EffectType.APPLY_POWER:
				queued_successfully = action_queue.queue_power(effect_target,effect.power_definition);
			CombatEffectDefinition.EffectType.BLOCK:#格挡效果作用于选择出的角色目标
				queued_successfully = action_queue.queue_block(effect_target,effect.amount);#加入一次独立格挡
			CombatEffectDefinition.EffectType.DRAW:#抽牌效果操作当前玩家的BattleState牌堆
				queued_successfully = action_queue.queue_draw(battle_state,effect.amount);#加入一次玩家抽牌行为
			CombatEffectDefinition.EffectType.GAIN_ENERGY:
				queued_successfully = action_queue.queue_gain_energy(battle_state,effect.amount);
			CombatEffectDefinition.EffectType.GAIN_ATTACK_CARD_ENERGY:
				queued_successfully = action_queue.queue_attack_card_energy(battle_state,effect.amount);
			CombatEffectDefinition.EffectType.PREVENT_DRAW:
				queued_successfully = action_queue.queue_prevent_draw(battle_state);
			CombatEffectDefinition.EffectType.LOSE_MAX_HEALTH:
				queued_successfully = action_queue.queue_lose_max_health(effect_target,effect.amount);
			CombatEffectDefinition.EffectType.LOSE_HEALTH:
				queued_successfully = action_queue.queue_lose_health(effect_target,effect.amount);
			CombatEffectDefinition.EffectType.ENHANCE_WEAPON:
				queued_successfully = action_queue.queue_enhance_weapon(
					battle_state.equipped_weapon.weapon, effect.amount, effect.durability_bonus
				);
			_:#即使资源绕过前置验证，也不能静默忽略未知类型
				push_error("遇到不支持的战斗效果类型，无法安排单项效果");#报告无法解释的枚举值

		if not queued_successfully:#任意一次重复入队失败都会让当前效果失败
			return false;#交给效果列表方法统一清空已经加入的行为

	return true;#当前效果的全部重复次数均成功加入队列

func _start_player_turn()->void:
	_event_source = &"player"
	if battle_state == null:
		push_error("尚未创建战斗状态，无法开始玩家回合");
		return;
	if battle_state.current_phase not in [BattleState.BattlePhase.SETUP, BattleState.BattlePhase.ENEMY_TURN]:
		return;# 同一玩家回合不能重复刷新能量、抽牌或领取开局格挡。

	if _check_battle_result():
		return;

	battle_state.player_state.clear_block_at_turn_start();#保留格挡能力跳过自动清理。
	battle_state.reset_energy_for_turn();#把当前能量恢复为每回合基础能量
	battle_state.draw_blocked_this_turn = false;# 先解禁，再执行本回合抽牌。
	battle_state.weapon_attack_available = true;# 即使尚未装备，本回合首次装备后也能攻击。
	battle_state.current_turn_number += 1;#进入下一个回合

	action_queue.clear_actions();
	action_queue.queue_turn_start_powers(battle_state.player_state);
	if (
		selected_collection != null
		and selected_collection.effect_type == CollectionDefinition.EffectType.EARLY_TURN_BLOCK
		and battle_state.current_turn_number <= selected_collection.turn_limit
	):
		if not action_queue.queue_block(battle_state.player_state, selected_collection.amount):
			push_error("藏品格挡行为加入失败");
			return;

	var draw_count:int = battle_state.cards_per_turn;
	if battle_state.current_turn_number == 1:
		draw_count = battle_state.prepare_opening_draw();
	if not action_queue.queue_draw(battle_state,draw_count):
		push_error("新玩家回合的抽牌行为加入失败");
		return;

	if not action_queue.resolve_all():
		push_error("新玩家回合的能力与抽牌执行失败");
		return;
	if _check_battle_result():# 回合开始失血致死时，队列已中断，不再进入可操作阶段。
		return;

	battle_state.current_phase = BattleState.BattlePhase.PLAYER_TURN;


func _run_enemy_turn()->void:
	if battle_state == null:
		push_error("尚未创建战斗状态，无法执行敌人回合");
		return;

	if battle_state.current_phase != BattleState.BattlePhase.ENEMY_TURN:
		push_error("当前不是敌人回合，无法执行敌人行动");
		return;

	if _check_battle_result():
		return;

	_event_source = &"enemy"
	var current_enemy_action:EnemyActionDefinition = battle_state.enemy_state.current_action;#保存本回合将要显示和执行的同一行动引用

	battle_state.enemy_state.clear_block_at_turn_start();#敌人使用同一套自动清理规则。
	action_queue.clear_actions();
	action_queue.queue_turn_start_powers(battle_state.enemy_state);

	if not _queue_effect_list(
		current_enemy_action.effects,
		battle_state.enemy_state,
		battle_state.player_state
	):#敌人是行动者，因此SELF指向敌人，OPPONENT指向玩家
		push_error("敌人当前行动效果加入失败");

		return;

	if not action_queue.resolve_all():
		push_error("敌人当前行动效果执行失败");

		return;

	if _check_battle_result():#敌人行动可能在这里让玩家生命归零
		return;

	battle_state.player_state.tick_statuses_at_round_end();
	battle_state.enemy_state.tick_statuses_at_round_end();

	battle_state.enemy_state.advance_to_next_action();

	_start_player_turn();#玩家回合刷新界面时会显示推进后的新current_action

func _check_battle_result()->bool:
	if battle_state == null:#缺少状态时无法判断任何真实胜负
		push_error("尚未创建战斗状态，无法检查战斗结果");#报告战斗检查被过早调用
		return false;#没有实际结果可以提交
	if _result != null:#同一场战斗的结果已经发送给外部流程
		return true;#继续告诉所有调用者立即停止普通战斗流程

	if battle_state.is_defeat():# 即使先前效果已击杀敌人，玩家失血致死仍按失败处理。
		_finish(false);#使用结构化布尔值提交单场失败
		return true;#阻止敌人行动推进或新玩家回合继续开始

	if battle_state.is_victory():
		_finish(true);
		return true;

	return false;#双方都存活，当前战斗应继续运行
