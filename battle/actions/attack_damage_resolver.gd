## 攻击伤害的共同入口；预览与执行都使用calculate，不修改基础数值。
class_name AttackDamageResolver
extends RefCounted


## 返回基础伤害叠加力量，再应用虚弱和易伤倍率后的攻击伤害。
##
## 所有倍率计算完成后向下取整，最终结果不小于 [code]0[/code]。
static func calculate(base_damage:int, strength:int, is_weak:bool, is_vulnerable:bool)->int:
	var damage:float = base_damage + strength;
	if is_weak:
		damage *= 0.75;
	if is_vulnerable:
		damage *= 1.5;
	return maxi(0, floori(damage));# 所有倍率计算完再取整，不能在中间丢失小数。


## 执行时读取双方状态，保证队列中先前的力量、虚弱和易伤能影响本次攻击。
static func apply(attacker:CombatantState, target:CombatantState, base_damage:int, ignores_block:bool = false)->int:
	var damage:int = calculate(
		base_damage, attacker.strength, attacker.weak_turns > 0, target.vulnerable_turns > 0
	);
	if ignores_block:
		return target.take_unblocked_damage(damage);
	return target.take_damage(damage);


## 在行为真正执行时取基础值，使先前的格挡效果和每段之间的变化生效。
## 按伤害治疗使用本段实际生命损失，伤害与治疗在同一次队列行为中完成。
static func apply_effect(attacker:CombatantState, target:CombatantState, effect:CombatEffectDefinition)->int:
	var base_damage:int = effect.get_base_damage(attacker.current_block);
	var actual_hp_loss:int;
	if effect.is_attack_damage:
		actual_hp_loss = apply(attacker, target, base_damage);
	else:
		actual_hp_loss = target.take_damage(base_damage);
	if effect.heals_from_damage:
		attacker.heal(actual_hp_loss);
	return actual_hp_loss;


## 依次预览各效果的单段伤害，数组下标与effects一致，非伤害位置为0。
## 仅在局部变量中模拟先前的状态与格挡变化，不修改真实角色。
## block_before_effects是行动执行前的格挡；敌人意图需先考虑回合开始自动清理。
static func preview_effect_damage(
	effects:Array[CombatEffectDefinition], attacker:CombatantState, opponent:CombatantState,
	block_before_effects:int
)->Array[int]:
	var damages:Array[int] = [];
	var strength:int = attacker.strength;
	var weak:bool = attacker.weak_turns > 0;
	var self_vulnerable:bool = attacker.vulnerable_turns > 0;
	var opponent_vulnerable:bool = opponent.vulnerable_turns > 0;
	var block:int = block_before_effects;
	for effect in effects:
		var damage:int = 0;
		var targets_self:bool = effect.target_type == CombatEffectDefinition.TargetType.SELF;
		match effect.effect_type:
			CombatEffectDefinition.EffectType.DAMAGE:
				damage = effect.get_base_damage(block);
				if effect.is_attack_damage:
					damage = calculate(damage, strength, weak, self_vulnerable if targets_self else opponent_vulnerable);
				if targets_self:
					block = maxi(0, block - damage * effect.repeat_count);
			CombatEffectDefinition.EffectType.BLOCK:
				if targets_self:
					block += effect.amount * effect.repeat_count;
			CombatEffectDefinition.EffectType.GAIN_STRENGTH:
				if targets_self:
					strength += effect.amount * effect.repeat_count;
			CombatEffectDefinition.EffectType.APPLY_WEAK:
				if targets_self:
					weak = true;
			CombatEffectDefinition.EffectType.APPLY_VULNERABLE:
				if targets_self:
					self_vulnerable = true;
				else:
					opponent_vulnerable = true;
		damages.append(damage);
	return damages;
