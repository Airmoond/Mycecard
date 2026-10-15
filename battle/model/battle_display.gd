## 从真实规则状态生成文字。预览和执行共用AttackDamageResolver，不修改资源。
class_name BattleDisplay
extends RefCounted

static func card_description(state:BattleState, card:CardInstance)->String:
	if state == null or card == null:
		return ""
	var damage_values:Array[int] = AttackDamageResolver.preview_effect_damage(
		card.definition.effects, state.player_state, state.enemy_state, state.player_state.current_block)
	return card.definition.format_description(damage_values)

static func failure_text(code:StringName)->String:
	match code:
		&"not_enough_energy": return "能量不足"
		&"no_weapon": return "需要装备武器"
		&"max_health_cost": return "最大生命不足"
		&"not_in_hand": return "卡牌已离开手牌"
		_: return "当前不能执行该操作"

static func weapon_attack_tooltip(state:BattleState)->String:
	if state == null or state.equipped_weapon == null:
		return ""
	var weapon:WeaponInstance = state.equipped_weapon.weapon
	var damage:int = AttackDamageResolver.calculate(weapon.current_attack, state.player_state.strength,
		state.player_state.weak_turns > 0, state.enemy_state.vulnerable_turns > 0)
	var note:String = "无视格挡" if weapon.definition.ignores_block else "格挡前"
	var text:String = "预计伤害：%d（%s）" % [damage, note]
	if weapon.definition.strength_on_attack > 0:
		text += "\n攻击后：获得%d点力量" % weapon.definition.strength_on_attack
	if weapon.definition.draw_on_attack > 0:
		text += "\n攻击后：抽%d张牌" % weapon.definition.draw_on_attack
		if state.draw_blocked_this_turn:
			text += "（本回合禁止抽牌）"
	return text

static func enemy_intent_text(battle_state:BattleState)->String:
	if battle_state == null:
		return ""
	var action:EnemyActionDefinition = battle_state.enemy_state.current_action
	var effect_descriptions:PackedStringArray = [];#按照行动效果顺序收集每一项显示说明
	var block_at_action_start:int = 0;
	if battle_state.enemy_state.has_power(PowerDefinition.PowerType.RETAIN_BLOCK):
		block_at_action_start = battle_state.enemy_state.current_block;
	for power in battle_state.enemy_state.powers:
		if power.power_type == PowerDefinition.PowerType.TURN_START_HEALTH_FOR_BLOCK:
			block_at_action_start += power.block_gain;
	var damage_values:Array[int] = AttackDamageResolver.preview_effect_damage(
		action.effects, battle_state.enemy_state, battle_state.player_state, block_at_action_start
	);
	for effect_index in range(action.effects.size()):
		var effect:CombatEffectDefinition = action.effects[effect_index];
		var effect_description:String = "";#保存当前效果生成的局部说明
		match effect.effect_type:#根据效果类型选择玩家容易理解的显示名称
			CombatEffectDefinition.EffectType.DAMAGE:
				effect_description = "%d点伤害" % damage_values[effect_index];
				if effect.heals_from_damage:
					effect_description += "，按目标失血回血";
			CombatEffectDefinition.EffectType.GAIN_STRENGTH:
				effect_description = ("自身力量 +%d" if effect.target_type == CombatEffectDefinition.TargetType.SELF else "对手力量 +%d") % effect.amount;
			CombatEffectDefinition.EffectType.BLOCK:
				effect_description = "%d点格挡" % effect.amount;#格挡数值直接来自真实效果
			CombatEffectDefinition.EffectType.APPLY_WEAK:
				effect_description = ("自身虚弱 %d 回合" if effect.target_type == CombatEffectDefinition.TargetType.SELF else "对手虚弱 %d 回合") % effect.amount;
			CombatEffectDefinition.EffectType.APPLY_VULNERABLE:
				effect_description = ("自身易伤 %d 回合" if effect.target_type == CombatEffectDefinition.TargetType.SELF else "对手易伤 %d 回合") % effect.amount;
			CombatEffectDefinition.EffectType.APPLY_POWER:
				effect_description = ("自身获得%s" if effect.target_type == CombatEffectDefinition.TargetType.SELF else "对手获得%s") % effect.power_definition.display_name;
			CombatEffectDefinition.EffectType.DRAW, CombatEffectDefinition.EffectType.GAIN_ENERGY, CombatEffectDefinition.EffectType.ENHANCE_WEAPON, CombatEffectDefinition.EffectType.LOSE_HEALTH, CombatEffectDefinition.EffectType.PREVENT_DRAW, CombatEffectDefinition.EffectType.LOSE_MAX_HEALTH, CombatEffectDefinition.EffectType.GAIN_ATTACK_CARD_ENERGY:
				push_error("敌人行动不能使用玩家专用效果");
				return "";#拒绝显示无法正确执行的敌人效果
			_:
				push_error("敌人行动包含不支持的效果类型");#防止未知枚举被静默显示
				return "";#未知效果无法生成可信意图

		if effect.repeat_count > 1:#多段效果需要明确告诉玩家实际执行次数
			effect_description += " × %d" % effect.repeat_count;#例如显示为“3点伤害 × 2”
		effect_descriptions.append(effect_description);#保留行动资源中的原始效果顺序

	return "%s：%s" % [
		action.intent_text,
		"；".join(effect_descriptions)
	];#行动名称负责语义，效果列表负责提供不会失真的真实数值
