## 保存一名战斗角色的运行时状态。
##
## 该对象可以表示玩家或敌人，负责保存名称、生命和格挡等真实数据。
## 它不挂载到节点，也不负责角色画面、动画、回合流程或胜负判断。
class_name CombatantState
extends RefCounted

## 只读的已执行结果，用于独立表现；不等待监听者或把动画结果写回规则。
signal presentation_result(kind:StringName, amount:int)


## 当前运行时角色引用的静态角色定义资源。
##
## 通过combatant_init_from_definition完成绑定，用于读取角色ID、显示名称、
## 基础最大生命和原画。该资源在战斗过程中必须视为只读，当前生命、格挡等
## 临时数据只能保存在CombatantState自身的运行时字段中。
## 迁移期间允许为空，以兼容仍调用旧combatant_init方法创建的测试敌人。
var definition:CombatantDefinition

## 角色显示名称。
var combatant_name:String;

## 角色的最大生命值。
##
## 成功初始化后必须大于0。
var max_health:int = 0;

## 角色当前剩余的生命值。
##
## 初始化时等于max_health，受到伤害时减少，最低为0。
var current_health:int = 0;

## 角色当前拥有的格挡值。
##
## 格挡会优先抵消传入伤害，初始化时为0。
var current_block:int = 0;

## 每点力量增加每段攻击伤害，持续本场战斗，不逐回合衰减。
var strength:int = 0;

## 本场已获得的持续能力；数组归本角色所有，其中的定义保持只读。
var powers:Array[PowerDefinition] = [];

## 层数表示剩余整轮数，重复施加只延长时间，不增加倍率。
var weak_turns:int = 0;
var vulnerable_turns:int = 0;
var _weak_skip_first_tick:bool = false;
var _vulnerable_skip_first_tick:bool = false;


## 使用静态角色定义初始化当前运行时角色状态。
##
## new_definition为空或定义无效时推送错误，保持当前状态不变并返回false。
## 定义合法时保存其只读引用，将显示名称和最大生命同步到迁移期字段，
## 把当前生命恢复至最大生命、将格挡清零，然后返回true。
## 该方法不会修改传入的CombatantDefinition资源。
func combatant_init_from_definition(new_definition:CombatantDefinition)->bool:
	if new_definition == null:#空引用无法提供角色ID、名称、生命和原画
		push_error("角色定义为空，运行时角色初始化失败");#报告调用方缺少静态配置
		return false;#验证失败前不修改当前对象中的任何状态
	if new_definition.is_invalid():#让静态定义检查自身全部必需字段
		push_error("角色定义无效，运行时角色初始化失败");#补充初始化阶段的错误上下文
		return false;#非法资源不能成为运行时状态的数据来源

	definition = new_definition;#保存静态定义的只读引用，供后续View和规则读取
	combatant_name = new_definition.display_name;#迁移期间同步旧名称字段，兼容当前CombatantView
	max_health = new_definition.max_health;#从静态定义取得角色原本的最大生命
	current_health = max_health;#新建战斗状态时让角色以满生命开始
	current_block = 0;#新建战斗状态时不能继承上一场战斗的格挡
	_reset_statuses();
	return true;#所有运行时初始数据均已成功建立


## 尝试把当前生命设置为一个合法的存活状态，并返回是否设置成功。
##
## 该方法应当在combatant_init_from_definition或旧combatant_init成功后调用。
## 角色尚未初始化、new_current_health小于或等于0，或者数值超过max_health时，
## 推送对应错误、保持current_health原值不变并返回false。
##
## 输入合法时只修改current_health并返回true，不修改最大生命、格挡或静态角色定义。
## 第三阶段开始新战斗时，BattleController用它将RunState保存的剩余生命写入
## 新创建的玩家状态；0生命代表整局失败，不能通过该方法进入下一场战斗。
func set_current_health(new_current_health:int)->bool:
	if max_health <= 0:#最大生命尚未建立时说明当前角色没有成功完成初始化
		push_error("角色尚未初始化，无法设置当前生命");#报告调用顺序错误，而不是接受缺少上限的生命
		return false;#验证失败时保持current_health原值不变
	if new_current_health <= 0:#下一场战斗只能接收仍然存活的玩家状态
		push_error("新的当前生命必须大于0");#0生命应由整局失败流程处理，负数始终非法
		return false;#非法生命不能覆盖当前已经建立的运行时状态
	if new_current_health > max_health:#跨战斗保留的生命不能超过本局实际最大生命
		push_error("新的当前生命不能超过最大生命");#报告战斗回写或调用参数破坏了生命上限
		return false;#拒绝通过静默截断掩盖上游状态错误

	current_health = new_current_health;#全部验证通过后，只提交新的运行时当前生命
	return true;#当前角色可以使用指定生命进入后续单场战斗


## 使用角色名称和最大生命值初始化当前角色状态。
##
## max_hp小于或等于0时推送错误并立即结束，不修改当前数据。
## max_hp合法时，保存new_name和max_hp，将当前生命恢复至最大生命，并将格挡清零。
## 该方法没有返回值。
func combatant_init(new_name:String,max_hp:int)->void:
	if max_hp<=0:
		push_error("Invalid max_hp!非法的最大生命，初始化失败");#若生命值传入负数，则推送错误，中断初始化进程
		return;
	combatant_name=new_name;
	max_health = max_hp;
	current_health = max_health;
	current_block=0;
	_reset_statuses();


## 力量增益叠加到角色状态；正数由效果定义验证。
func gain_strength(amount:int)->void:
	strength += amount;


func _reset_statuses()->void:
	powers.clear();
	strength = 0;
	weak_turns = 0;
	vulnerable_turns = 0;
	_weak_skip_first_tick = false;
	_vulnerable_skip_first_tick = false;


## 敌人首次施加时跳过当轮递减；已有状态叠加时保留原来的递减安排。
func apply_weak(turns:int, from_enemy:bool)->void:
	if weak_turns == 0:
		_weak_skip_first_tick = from_enemy;
	weak_turns += turns;


func apply_vulnerable(turns:int, from_enemy:bool)->void:
	if vulnerable_turns == 0:
		_vulnerable_skip_first_tick = from_enemy;
	vulnerable_turns += turns;


## 玩家和敌人都行动完后各调用一次；力量不参与递减。
func tick_statuses_at_round_end()->void:
	if _weak_skip_first_tick:
		_weak_skip_first_tick = false;
	elif weak_turns > 0:
		weak_turns -= 1;
	if _vulnerable_skip_first_tick:
		_vulnerable_skip_first_tick = false;
	elif vulnerable_turns > 0:
		vulnerable_turns -= 1;


## 为角色增加指定数量的格挡。
##
## block_number大于0时，将其累加到current_block。
## block_number等于0时，格挡保持不变。
## block_number小于0时，不执行任何操作。
## 该方法没有返回值。
func gain_block(block_number:int)->void:
	if block_number>=0:
		current_block += block_number;
		if block_number > 0:
			presentation_result.emit(&"block_gain", block_number);


## 清空角色当前拥有的全部格挡。
##
## 调用后current_block变为0。
## 该方法不判断清空格挡的时机，也没有返回值。
func clear_block()->void:
	current_block = 0;


## 保留格挡去重；回合开始失血换格挡每次施加保留一份，按获得顺序独立触发。
## 只保存只读定义的引用，不绑定来源卡牌的去向。
func apply_power(power:PowerDefinition)->void:
	match power.power_type:
		PowerDefinition.PowerType.RETAIN_BLOCK:
			if not has_power(power.power_type):
				powers.append(power);
		PowerDefinition.PowerType.TURN_START_HEALTH_FOR_BLOCK:
			powers.append(power);


func has_power(power_type:PowerDefinition.PowerType)->bool:
	for power in powers:
		if power.power_type == power_type:
			return true;
	return false;


## 仅自动清理检查保留格挡；显式clear_block仍无条件清空。
func clear_block_at_turn_start()->void:
	if not has_power(PowerDefinition.PowerType.RETAIN_BLOCK):
		clear_block();


## 让角色承受指定数量的伤害，并返回实际损失的生命值。
##
## damage_number小于或等于0时，不修改生命和格挡，并返回0。
## damage_number大于0时，当前格挡会优先吸收伤害。
## 穿透格挡的剩余伤害会扣除当前生命，但不会让生命低于0。
## 伤害被格挡完全吸收时返回0。
## 伤害穿透格挡时返回本次实际减少的生命值。
## 发生超杀时只返回角色原本剩余的生命值。
func take_damage(damage_number:int)->int:
	if damage_number <= 0:
		return 0;
	var blocked_damage:int = mini(damage_number, current_block);
	current_block -= blocked_damage;
	if blocked_damage > 0:
		presentation_result.emit(&"block_hit", blocked_damage);
	return take_unblocked_damage(damage_number - blocked_damage);


## 承受已经算好的非负伤害，直接扣生命并返回实际损失，不读取或修改格挡。
## 普通伤害抵消格挡后的余量、无视格挡攻击均复用此入口；力量和倍率在上游计算。
func take_unblocked_damage(damage_number:int)->int:
	var actual_hp_loss:int = mini(current_health, damage_number);
	current_health -= actual_hp_loss;
	if actual_hp_loss > 0:
		presentation_result.emit(&"strike_hit", actual_hp_loss);
	return actual_hp_loss;


## 直接失去生命，绕过格挡和攻击计算，返回实际失去的生命值。
## amount由效果定义验证为正数；生命最低为0。
func lose_health(amount:int)->int:
	var actual_loss:int = mini(current_health, amount);
	current_health -= actual_loss;
	if actual_loss > 0:
		presentation_result.emit(&"health_loss", actual_loss);
	return actual_loss;


## 接收非负治疗量，恢复至多到当前最大生命，并返回实际恢复量。
## 按伤害治疗直接传入本段造成的实际生命损失，完全格挡时为0。
func heal(amount:int)->int:
	var actual_heal:int = mini(amount, max_health - current_health);
	current_health += actual_heal;
	if actual_heal > 0:
		presentation_result.emit(&"heal_gain", actual_heal);
	return actual_heal;


## 出牌入口已确认能完整减少且至少剩1点上限；当前生命只压到新上限。
func lose_max_health(amount:int)->void:
	var previous_health:int = current_health;
	max_health -= amount;
	current_health = mini(current_health, max_health);
	if previous_health > current_health:
		presentation_result.emit(&"health_loss", previous_health - current_health);


## 判断角色当前是否存活。
##
## current_health大于0时返回true。
## current_health等于0或小于0时返回false。
## 该方法只进行判断，不修改角色状态。
func is_alive()->bool:
	if current_health>0:
		return true;
	else:
		return false;
