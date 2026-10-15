## 保存一场战斗当前时刻的全部运行时状态。
##
## 包含参战角色、能量、回合阶段，以及卡牌在各牌堆和结算中的归属。
## BattleState是战斗数据的唯一可信来源；BattleSession负责调用这里的方法推进战斗，
## 显示层只读取这些状态并更新画面，不应把UI中的数值反向当作真实战斗数据。
class_name BattleState
extends RefCounted

## 只报告已经提交的能量与装备变化；监听者不能参与费用、攻击或归档验证。
signal presentation_result(kind:StringName, amount:int)

## 独立战斗随机源。显式传入时与冒险候选抽样互不消费彼此的序列。
var _random_source:RandomNumberGenerator = RandomNumberGenerator.new()

func _init()->void:
	_random_source.randomize()

func set_random_source(source:RandomNumberGenerator)->void:
	if source != null:
		_random_source = source

## 当前战斗所处的阶段。
enum BattlePhase{
	## 战斗正在初始化，玩家和敌人的回合尚未开始。
	SETUP,

	## 当前允许玩家抽牌、出牌和结束回合。
	PLAYER_TURN,

	## 当前由敌人执行行动。
	ENEMY_TURN,

	## 当前战斗已经结束，不应继续执行普通回合操作。
	FINISHED
}

## 当前战斗中的玩家状态实例，用于读取和修改玩家的生命与格挡等真实数据。
var player_state:CombatantState;

## 当前战斗中的敌人状态实例。
## 除生命与格挡外，还保存敌人定义、当前行动下标和已经准备好的当前行动。
var enemy_state:EnemyState;

## 玩家每个回合开始时应当恢复到的基础能量，不能小于0。
var energy_per_turn:int;#每回合开始恢复的能量

## 玩家当前能够用于支付卡牌费用的能量，不能小于0。
var current_available_energy:int;#当前可用的能量

## 当前抽牌堆中的卡牌实例；数组末尾视为牌堆顶端。
var draw_pile:Array[CardInstance];

## 玩家当前持有的卡牌实例；其中每张卡牌都可以在显示层拥有对应的card_view。
var hand:Array[CardInstance];

## 当前弃牌堆中的卡牌实例；抽牌堆耗尽时，这些卡牌会被重新洗入抽牌堆。
var discard_pile:Array[CardInstance];

## 正在执行效果的卡牌；不参与抽牌与洗牌，同时阻止其他出牌或结束回合操作。
## 正常结算后归档并清空；执行失败时保留在这里，便于定位已部分生效的操作。
var resolving_card:CardInstance;

## 本场已消耗的卡牌，不会被洗回抽牌堆。
var exhaust_pile:Array[CardInstance] = [];

## 已打出的无消耗能力牌；退出循环但不算消耗。
var played_power_cards:Array[CardInstance] = [];

## 当前装备的原卡牌实例；它离开手牌，但仍参与本场卡牌数量统计。
var equipped_weapon:CardInstance;

## 每个玩家回合恢复一次；机会属于角色，换装和重装都不会刷新。
var weapon_attack_available:bool = false;

## 只限制抽牌，不影响装备损坏回手等直接移动卡牌的行为。
var draw_blocked_this_turn:bool = false;

## 本回合每打出一张攻击牌获得的能量；重复施加相加，玩家回合结束清零。
var attack_card_energy_this_turn:int = 0;

## 本场初始牌数，供状态检查核对移动过程中有没有丢牌。
var _initial_card_count:int = 0;

## 当前战斗阶段，由BattleSession提供统一合法性查询。
var current_phase:BattlePhase;

## 当前回合编号；初始化时为0，正式开始新的玩家回合时再由BattleSession递增。
var current_turn_number:int=0;#当前回合编号

## 玩家每个回合开始时应当尝试抽取的卡牌数量，必须大于0。
##
## 该数值来自遭遇配置，由BattleSession在开始玩家回合时读取；BattleState只保存规则，
## 不会因为该变量变化而自动触发抽牌。
var cards_per_turn:int;

## 玩家能够持有的最大手牌数量；达到或超过该数值时不能继续抽牌。
##
## 该数值来自遭遇配置，必须大于0，并且不能小于cards_per_turn。
var max_hand_size:int;

## 使用参战角色、初始牌组和遭遇规则参数初始化一场新战斗。
##
## player或enemy为null、任意一方未存活、敌人定义或当前行动非法、
## energy_start小于0、cards_each_turn或hand_size_limit不合法，或者start_pile为空时，
## 推送对应错误、保持当前BattleState原有数据不变，并返回false。
## cards_each_turn必须大于0且不能超过hand_size_limit；hand_size_limit必须大于0。
## start_pile中存在null、非法CardInstance，或者重复放入同一个CardInstance时，
## 推送对应错误、保持当前BattleState原有数据不变，并返回false。
## 所有参数合法时保存角色引用，将start_pile中的卡牌实例放入draw_pile，清空其他牌区，
## 保存全部遭遇规则，把能量、回合编号和阶段恢复为战斗初始状态，
## 然后返回true。
## 该方法会复制start_pile数组本身，但不会复制数组中的CardInstance。
func battle_state_init(
	player:CombatantState,
	enemy:EnemyState,
	start_pile:Array[CardInstance],
	energy_start:int,
	cards_each_turn:int,
	hand_size_limit:int
)->bool:
	if player == null:
		push_error("非法玩家对象，战斗初始化失败")
		return false;
	if enemy == null:
		push_error("非法敌人对象，战斗初始化失败")
		return false;
	if not player.is_alive():
		push_error("玩家未存活，战斗初始化失败")
		return false;
	if not enemy.is_alive():
		push_error("敌人未存活，战斗初始化失败")
		return false;
	if enemy.enemy_definition == null:#敌人运行时状态必须保留具体的静态定义
		push_error("敌人定义为空，战斗初始化失败")
		return false;
	if enemy.enemy_definition.is_invalid():#非法定义无法提供可靠的行动模式
		push_error("敌人定义无效，战斗初始化失败")
		return false;
	if enemy.current_action_index < 0 or enemy.current_action_index >= enemy.enemy_definition.action_pattern.size():#下标必须落在行动模式范围内
		push_error("敌人当前行动下标越界，战斗初始化失败")
		return false;
	if enemy.current_action == null:#界面和BattleSession都需要读取已经准备好的行动
		push_error("敌人当前行动为空，战斗初始化失败")
		return false;
	if enemy.current_action.is_invalid():#拒绝把效果不完整的行动带入战斗
		push_error("敌人当前行动无效，战斗初始化失败")
		return false;
	if enemy.current_action != enemy.enemy_definition.action_pattern[enemy.current_action_index]:#行动引用必须与当前下标一致
		push_error("敌人当前行动与行动下标不一致，战斗初始化失败")
		return false;
	if energy_start<0:
		push_error("初始能量非法，战斗初始化失败")
		return false;
	if cards_each_turn <= 0:#每个玩家回合必须配置正数抽牌数量
		push_error("每回合抽牌数必须大于0，战斗初始化失败");#报告无法正常开始玩家回合的规则
		return false;#非法抽牌规则不能写入当前BattleState
	if hand_size_limit <= 0:#手牌上限必须能够容纳至少一张卡牌
		push_error("手牌上限必须大于0，战斗初始化失败");#报告无法容纳卡牌的规则
		return false;#非法上限不能交给抽牌方法使用
	if cards_each_turn > hand_size_limit:#基础回合抽牌量不能从一开始就超过手牌容量
		push_error("每回合抽牌数不能超过手牌上限，战斗初始化失败");#报告互相冲突的遭遇规则
		return false;#参数关系非法时保持当前BattleState原有数据不变
	if start_pile.is_empty():
		push_error("初始牌组为空，战斗初始化失败")
		return false;
	var start_pile_instance_ids:Dictionary = {};
	for card in start_pile:
		if card == null:
			push_error("牌组中存在空卡牌，战斗初始化失败")
			return false;
		if card.is_invalid_instance():
			push_error("牌组中存在非法卡牌实例，战斗初始化失败")
			return false;
		var card_instance_id:int = card.get_instance_id();
		if start_pile_instance_ids.has(card_instance_id):
			push_error("初始牌组中重复使用了同一个卡牌实例，战斗初始化失败")
			return false;
		start_pile_instance_ids[card_instance_id] = true;
		
	player_state = player;
	enemy_state = enemy;
	
	draw_pile = start_pile.duplicate();
	hand.clear();
	discard_pile.clear();
	resolving_card = null;
	exhaust_pile.clear();
	played_power_cards.clear();
	equipped_weapon = null;
	weapon_attack_available = false;
	draw_blocked_this_turn = false;
	attack_card_energy_this_turn = 0;
	_initial_card_count = start_pile.size();
	current_available_energy = 0;
	current_turn_number = 0;
	current_phase = BattlePhase.SETUP;
	energy_per_turn = energy_start;#保存遭遇指定的每回合基础能量
	cards_per_turn = cards_each_turn;#保存遭遇指定的每回合抽牌数量
	max_hand_size = hand_size_limit;#保存遭遇指定的手牌容量规则
	
	return true;

## 检查当前战斗状态是否存在非法数据。
##
## 角色状态为空，敌人定义或当前行动非法，能量或回合编号小于0，每回合抽牌数或
## 手牌上限不合法，或者手牌数量超过上限时，推送对应错误并返回true。
## 任意牌堆中存在null、非法CardInstance，或者同一个CardInstance在一个或多个牌堆中
## 重复出现，或者所有牌区（包括结算中）的总数不等于初始牌数时，返回true。
## 上述非法情况均不存在时返回false。
## 该方法只检查数据，不会修复或修改当前战斗状态。
func is_invalid_battle()->bool:
	if player_state == null:
		push_error("玩家状态为空，战斗状态非法")
		return true;
	if enemy_state == null:
		push_error("敌人状态为空，战斗状态非法")
		return true;
	if enemy_state.enemy_definition == null:#缺少敌人定义时无法验证行动模式
		push_error("敌人定义为空，战斗状态非法")
		return true;
	if enemy_state.enemy_definition.is_invalid():#运行时敌人不能依赖非法静态数据
		push_error("敌人定义无效，战斗状态非法")
		return true;
	if enemy_state.current_action_index < 0 or enemy_state.current_action_index >= enemy_state.enemy_definition.action_pattern.size():#防止访问越界的行动项
		push_error("敌人当前行动下标越界，战斗状态非法")
		return true;
	if enemy_state.current_action == null:#敌人回合开始前必须已经准备好行动
		push_error("敌人当前行动为空，战斗状态非法")
		return true;
	if enemy_state.current_action.is_invalid():#当前行动中的效果必须完整合法
		push_error("敌人当前行动无效，战斗状态非法")
		return true;
	if enemy_state.current_action != enemy_state.enemy_definition.action_pattern[enemy_state.current_action_index]:#确保显示意图与实际执行来源相同
		push_error("敌人当前行动与行动下标不一致，战斗状态非法")
		return true;
	if energy_per_turn < 0:
		push_error("每回合能量小于零，战斗状态非法")
		return true;
	if current_available_energy < 0:
		push_error("当前可用能量小于零，战斗状态非法")
		return true;
	if current_turn_number < 0:
		push_error("当前回合编号小于零，战斗状态非法")
		return true;
	if cards_per_turn <= 0:#运行时规则必须保留正数的每回合抽牌量
		push_error("每回合抽牌数小于或等于零，战斗状态非法");#报告遭遇规则未保存或被错误修改
		return true;#非法规则不能继续驱动玩家回合
	if max_hand_size <= 0:
		push_error("手牌上限小于或等于零，战斗状态非法")
		return true;
	if cards_per_turn > max_hand_size:#每回合基础抽牌量必须能够被手牌容量完整容纳
		push_error("每回合抽牌数超过手牌上限，战斗状态非法");#报告运行时规则之间发生冲突
		return true;#互相冲突的规则不能继续推进战斗
	if hand.size() > max_hand_size:
		push_error("当前手牌数量超过手牌上限，战斗状态非法")
		return true;
	
	# 汇总所有真实卡牌区域，统一检查，避免为每个新牌堆复制一套验证。
	var all_cards:Array[CardInstance] = [];
	all_cards.append_array(draw_pile);
	all_cards.append_array(hand);
	all_cards.append_array(discard_pile);
	all_cards.append_array(exhaust_pile);
	all_cards.append_array(played_power_cards);
	if resolving_card != null:
		all_cards.append(resolving_card);
	if equipped_weapon != null:
		all_cards.append(equipped_weapon);

	if all_cards.size() != _initial_card_count:
		push_error("所有牌区的卡牌总数与初始牌数不一致");
		return true;

	var seen_card_ids:Dictionary = {};
	for card in all_cards:
		if card == null or card.is_invalid_instance():
			push_error("牌区中存在空卡牌或非法实例");
			return true;
		var instance_id:int = card.get_instance_id();
		if seen_card_ids.has(instance_id):
			push_error("同一卡牌实例重复出现在牌区中");
			return true;
		seen_card_ids[instance_id] = true;

	return false;


## 将玩家当前可用能量恢复为每回合基础能量。
##
## 调用后，current_available_energy将等于energy_per_turn。
## 调用方应当保证当前BattleState已经成功初始化且energy_per_turn合法。
## 该方法只负责恢复能量，不负责开始玩家回合，也没有返回值。
func reset_energy_for_turn()->void:
	var change:int = energy_per_turn - current_available_energy;
	current_available_energy = energy_per_turn;
	if change != 0:
		presentation_result.emit(&"energy", change);


## 增加当前能量，可以超过每回合基础值；数值由效果定义验证为正数。
func gain_energy(amount:int)->void:
	current_available_energy += amount;
	if amount != 0:
		presentation_result.emit(&"energy", amount);


## 只增加后续攻击牌的回能额度，不立刻回复能量。
func add_attack_card_energy(amount:int)->void:
	attack_card_energy_this_turn += amount;


## 尝试消耗指定数量的当前可用能量。
##
## energy_cost小于0时推送错误、保持当前能量不变，并返回false。
## 当前能量不足时保持当前能量不变，并返回false。
## 当前能量足够时扣除energy_cost，并返回true。
## energy_cost等于0时不改变当前能量，并返回true。
## 该方法只处理能量，不检查卡牌实例、目标或当前战斗阶段是否合法。
func spend_energy(energy_cost:int)->bool:
	if energy_cost < 0:
		push_error("需要消耗的能量小于零，能量消耗失败")
		return false;
	if current_available_energy < energy_cost:
		return false;
	current_available_energy -= energy_cost;
	if energy_cost > 0:
		presentation_result.emit(&"energy", -energy_cost);
	return true;


## 随机打乱当前抽牌堆中卡牌实例的排列顺序。
##
## 抽牌堆少于两张卡牌时不执行操作。
## 抽牌堆至少有两张卡牌时调用数组的随机打乱功能。
## 该方法只改变卡牌在draw_pile中的顺序，不会创建、删除或复制卡牌，也没有返回值。
func shuffle_draw_pile()->void:
	if draw_pile.size() < 2:
		return;
	for index in range(draw_pile.size() - 1, 0, -1):
		var swap_index:int = _random_source.randi_range(0, index)
		var card:CardInstance = draw_pile[index]
		draw_pile[index] = draw_pile[swap_index]
		draw_pile[swap_index] = card


## 仅在首回合抽牌前调用：洗牌后把固有牌放到数组末尾（牌堆顶）。
## 返回首回合尝试抽取的数量，实际手牌上限仍由draw_one_card统一处理。
func prepare_opening_draw()->int:
	shuffle_draw_pile();
	var ordinary_cards:Array[CardInstance] = [];
	var innate_cards:Array[CardInstance] = [];
	for card in draw_pile:
		if card.definition.is_innate:
			innate_cards.append(card);
		else:
			ordinary_cards.append(card);
	draw_pile = ordinary_cards;
	draw_pile.append_array(innate_cards);
	return maxi(cards_per_turn, innate_cards.size());


## 限制持续到下一玩家回合开始，重复施加不叠加。
func prevent_draw_for_turn()->void:
	draw_blocked_this_turn = true;


## 尝试从抽牌堆顶端抽取一张卡牌并加入玩家手牌。
##
## 禁止抽牌或手牌已满时不修改任何牌堆，并返回null。
## draw_pile为空而discard_pile不为空时，先将弃牌堆移动到抽牌堆并进行洗牌。
## 完成上述处理后仍然没有可抽取的卡牌时返回null。
## 成功时从draw_pile末尾取出同一个CardInstance，将其加入hand并返回该实例。
## 该方法不会创建或复制CardInstance。
func draw_one_card()->CardInstance:
	if draw_blocked_this_turn or hand_is_full():
		return null;
	if draw_pile.is_empty() and !discard_pile.is_empty():#如果抽牌堆空了，尝试洗牌
		draw_pile = discard_pile.duplicate();
		discard_pile.clear();
		shuffle_draw_pile();
		
	if draw_pile.is_empty():#如果洗完还是没牌，那就是真没了
		return null;
		
	var drawn_card:CardInstance = draw_pile.pop_back();#数组末尾视为牌堆顶端！
	hand.push_back(drawn_card);
	return drawn_card;


## 检查玩家当前手牌是否已经达到或超过手牌上限。
##
## hand中的卡牌数量小于max_hand_size时返回false。
## hand中的卡牌数量大于或等于max_hand_size时返回true。
## 该方法只读取手牌数量，不会修改任何牌堆。
func hand_is_full()->bool:
	if hand.size()<max_hand_size:
		return false;
	else:
		return true;

## 尝试连续抽取指定数量的卡牌。
##
## draw_count小于或等于0时不修改任何牌堆，并返回空数组。
## 每次抽牌都会调用draw_one_card；禁止抽牌、手牌已满或无牌可抽时提前停止。
## 返回值包含本次实际成功抽到的全部CardInstance，数量可能小于draw_count。
## 如果一张牌也没有成功抽取，则返回空数组。
func draw_multiple_cards(draw_count:int)->Array[CardInstance]:
	var cards_need_drawn:Array[CardInstance];#本次被抽取的那几张牌
	if draw_count<=0:#若要抽的卡牌数量小于等于0，直接返回空数组
		return cards_need_drawn;
	for i in range(draw_count):
		var drawn_card:CardInstance = draw_one_card();
		if drawn_card == null:
			break;
		cards_need_drawn.push_back(drawn_card);
	return cards_need_drawn;


## 尝试将指定卡牌实例从手牌移动到弃牌堆。
##
## card为null时推送错误、保持所有牌堆不变，并返回false。
## card不在hand中时保持所有牌堆不变，并返回false。
## card存在于hand中时，将同一个CardInstance从hand移除并加入discard_pile，然后返回true。
## 该方法不会创建、复制或销毁卡牌实例。
func discard_card_from_hand(card:CardInstance)->bool:
	if card == null:
		push_error("需要弃置的卡牌实例为空，弃牌失败")
		return false;
	if not hand.has(card):
		return false;
	hand.erase(card);
	discard_pile.push_back(card);
	return true;


## 验证本次出牌的可用性，再一起完成扣费和从手牌移入结算中区域。
## 手牌中的实例已在战斗初始化时验证，这里不重新扫描卡牌定义或其他牌堆。
func begin_card_play(card:CardInstance)->bool:
	if current_phase != BattlePhase.PLAYER_TURN or resolving_card != null:
		return false;
	if card == null or not hand.has(card):
		return false;
	if not spend_energy(card.current_energy_cost):
		return false;

	hand.erase(card);
	resolving_card = card;
	# 在本牌效果执行前读取已有额度，因此不会触发本牌新施加的回能。
	if card.definition.card_type == CardDefinition.CardType.ATTACK and attack_card_energy_this_turn > 0:
		gain_energy(attack_card_energy_this_turn);
	if card.definition.card_type == CardDefinition.CardType.WEAPON:
		_break_equipped_weapon();# 新牌已经离手，旧武器回手时有一个空位。
	return true;


## 仅在begin_card_play成功且全部效果执行完成后调用。
## 武器进入装备位；其他牌消耗优先于能力类型。保留只影响未打出的手牌。
func finish_card_play()->void:
	var card:CardInstance = resolving_card;
	if card.definition.card_type == CardDefinition.CardType.WEAPON:
		card.weapon.restore_durability();
		equipped_weapon = card;
		presentation_result.emit(&"weapon_equip", 1);
	elif card.definition.exhausts_on_play:
		exhaust_pile.append(card);
	elif card.definition.card_type == CardDefinition.CardType.POWER:
		played_power_cards.append(card);
	else:
		discard_pile.append(card);
	resolving_card = null;


## 换装与攻击共用损坏去向；“永恒”满手时进入弃牌堆，之后正常抽回。
func _break_equipped_weapon()->void:
	if equipped_weapon == null:
		return;
	var old_weapon:CardInstance = equipped_weapon;
	equipped_weapon = null;
	old_weapon.weapon.current_durability = 0;
	if old_weapon.weapon.definition.break_destination == WeaponDefinition.BreakDestination.RETURN_TO_HAND:
		if hand_is_full():
			discard_pile.append(old_weapon);
		else:
			hand.append(old_weapon);
	else:
		exhaust_pile.append(old_weapon);
	presentation_result.emit(&"weapon_break", 1);


## 界面显示和实际攻击共用此判断，攻击不检查能量或手牌容量。
func can_attack_with_weapon()->bool:
	return (
		current_phase == BattlePhase.PLAYER_TURN
		and resolving_card == null
		and equipped_weapon != null
		and weapon_attack_available
		and player_state.is_alive()
		and enemy_state.is_alive()
	);


## 独立于出牌的同步攻击。先消耗机会并造成伤害，再触发力量和抽牌，最后扣耐久并处理损坏。
## 即使伤害为0或完全被格挡，也消耗这次机会和1点耐久。
func attack_with_weapon()->bool:
	if not can_attack_with_weapon():
		return false;
	weapon_attack_available = false;
	var weapon:WeaponInstance = equipped_weapon.weapon;
	AttackDamageResolver.apply(player_state, enemy_state, weapon.current_attack, weapon.definition.ignores_block);
	if weapon.definition.strength_on_attack > 0:
		player_state.gain_strength(weapon.definition.strength_on_attack);
	if weapon.definition.draw_on_attack > 0:
		draw_multiple_cards(weapon.definition.draw_on_attack);
	weapon.current_durability -= 1;
	if weapon.current_durability == 0:
		_break_equipped_weapon();
	return true;


## 回合结束时只弃置没有保留词条的手牌；未打出的消耗牌不会自动消耗。
func discard_hand_at_turn_end()->void:
	# 遍历快照，因为discard_card_from_hand会修改原手牌数组。
	for card in hand.duplicate():
		if not card.definition.retains_on_turn_end:
			discard_card_from_hand(card);


## 判断玩家是否已经取得当前战斗的胜利。
##
## enemy_state为null时返回false，避免把缺少敌人的非法状态误判为胜利。
## enemy_state仍然存活时返回false。
## enemy_state存在且已经死亡时返回true。
## 该方法只读取敌人状态，不会修改角色数据或current_phase。
func is_victory()->bool:
	if enemy_state == null:
		return false;
	if enemy_state.is_alive():
		return false;
	return true;


## 判断玩家是否已经在当前战斗中失败。
##
## player_state为null时返回false，避免把缺少玩家的非法状态误判为失败。
## player_state仍然存活时返回false。
## player_state存在且已经死亡时返回true。
## 该方法只读取玩家状态，不会修改角色数据或current_phase。
func is_defeat()->bool:
	if player_state == null:
		return false;
	if player_state.is_alive():
		return false;
	return true;
	
	
	
	
	
