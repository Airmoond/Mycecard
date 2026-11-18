## 按照加入顺序执行战斗行为。
##
## ActionQueue负责安排伤害、格挡和抽牌等操作的执行顺序。
## 第一阶段使用同步结算：加入行为后，由控制器立即调用resolve_all完成全部行为。
## 该对象不进入场景树，也不负责检查回合、卡牌费用、胜负或刷新界面。
class_name ActionQueue
extends RefCounted


## 等待执行的战斗行为。
##
## 每个Callable都保存了需要调用的方法以及调用时使用的参数。
var _pending_actions:Array[Callable] = [];


## 当前是否正在执行队列，防止重复调用resolve_all。
var _is_resolving:bool = false;

## 定义与目标已由入口验证；每段执行时读取格挡和状态，不在入队时冻结数值。
func queue_damage_effect(attacker:CombatantState, target:CombatantState, effect:CombatEffectDefinition)->bool:
	return _enqueue_action(AttackDamageResolver.apply_effect.bind(attacker, target, effect));


## 将增加力量的操作加入队列，并返回是否成功入队；不会立即修改目标状态。
func queue_gain_strength(target:CombatantState, amount:int)->bool:
	return _enqueue_action(target.gain_strength.bind(amount));


## 将施加虚弱的操作加入队列。[param from_enemy] 决定首次施加后是否跳过当轮递减。
func queue_weak(target:CombatantState, turns:int, from_enemy:bool)->bool:
	return _enqueue_action(target.apply_weak.bind(turns, from_enemy));


## 将施加易伤的操作加入队列。[param from_enemy] 决定首次施加后是否跳过当轮递减。
func queue_vulnerable(target:CombatantState, turns:int, from_enemy:bool)->bool:
	return _enqueue_action(target.apply_vulnerable.bind(turns, from_enemy));


## 定义和目标已经由效果入口验证；这里只安排施加时机。
func queue_power(target:CombatantState, power:PowerDefinition)->bool:
	return _enqueue_action(target.apply_power.bind(power));


## 在持有者自己的回合开始时调用，格挡清理已由控制器完成。
## 每份能力逐个入队；失血致死会沿用原逻辑清除后续格挡、能力与抽牌／行动。
func queue_turn_start_powers(target:CombatantState)->void:
	for power in target.powers:
		if power.power_type == PowerDefinition.PowerType.TURN_START_HEALTH_FOR_BLOCK:
			queue_lose_health(target, power.health_loss);
			queue_block(target, power.block_gain);


## 将一次获得格挡行为加入队列。
##
## target为空或block_amount小于等于0时返回false。
## 成功时只加入队列，不会立刻增加格挡。
func queue_block(target:CombatantState,block_amount:int)->bool:
	if target == null:
		push_error("格挡目标为空，无法加入格挡行为");
		return false;
	if block_amount <= 0:
		push_error("格挡数值必须大于0");
		return false;
	
	return _enqueue_action(target.gain_block.bind(block_amount));
	
## 将一次抽牌行为加入队列。
##
## state为空或draw_count小于等于0时返回false。
## 成功时只加入队列，不会立刻移动牌堆。
func queue_draw(state:BattleState,draw_count:int)->bool:
	if state == null:
		push_error("战斗状态为空，无法加入抽牌行为");
		return false;
	if draw_count <= 0:
		push_error("抽牌数量必须大于0");
		return false;
	
	return _enqueue_action(state.draw_multiple_cards.bind(draw_count));
	
## 获得能量与其他效果一起按顺序执行；调用方已验证效果定义和战斗上下文。
func queue_gain_energy(state:BattleState, amount:int)->bool:
	return _enqueue_action(state.gain_energy.bind(amount));


## 注册后续攻击牌的回能，与本牌其他效果保持配置顺序。
func queue_attack_card_energy(state:BattleState, amount:int)->bool:
	return _enqueue_action(state.add_attack_card_energy.bind(amount));


## 按配置顺序生效，让“先抽牌，再禁止抽牌”沿用现有队列。
func queue_prevent_draw(state:BattleState)->bool:
	return _enqueue_action(state.prevent_draw_for_turn);


## 最大生命的可支付性由出牌入口检查，执行时按效果顺序修改角色状态。
func queue_lose_max_health(target:CombatantState, amount:int)->bool:
	return _enqueue_action(target.lose_max_health.bind(amount));


## 准备效果时锁定当前武器实例，按队列顺序执行强化。
func queue_enhance_weapon(weapon:WeaponInstance, attack_bonus:int, durability_bonus:int)->bool:
	return _enqueue_action(weapon.enhance.bind(attack_bonus, durability_bonus));


## 直接失血作为一项队列行为；目标和正数已由效果入口验证。
func queue_lose_health(target:CombatantState, amount:int)->bool:
	return _enqueue_action(_lose_health_and_stop_if_dead.bind(target, amount));


## 失血致死是正常的提前结束。清除剩余效果后，控制器仍会归档卡牌并报告结果。
func _lose_health_and_stop_if_dead(target:CombatantState, amount:int)->void:
	target.lose_health(amount);
	if not target.is_alive():
		clear_actions();


## 验证并保存一个等待执行的行为。
func _enqueue_action(action:Callable)->bool:
	if not action.is_valid():
		push_error("尝试加入无效的战斗行为");
		return false;
	
	_pending_actions.push_back(action);
	return true;


## 按照加入顺序执行所有等待中的战斗行为。
##
## 队列为空时也返回true。
## 因失血致死清除剩余效果也返回true，不当作执行错误。
## 正在执行时再次调用该方法会返回false。
func resolve_all()->bool:
	if _is_resolving:
		push_error("行为队列正在执行，不能重复开始结算");
		return false;
	
	_is_resolving = true;
	
	while not _pending_actions.is_empty():
		var current_action:Callable = _pending_actions.pop_front();
		
		if not current_action.is_valid():
			push_error("行为队列中存在无效行为");
			_pending_actions.clear();
			_is_resolving = false;
			return false;
		
		current_action.call();
	
	_is_resolving = false;
	return true;
	
## 清除所有尚未执行的行为。
##
## 重新开始战斗或放弃当前结算时可以调用。
func clear_actions()->void:
	_pending_actions.clear();
