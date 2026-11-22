extends GdUnitTestSuite


# 测试对象工厂
func create_combatant(max_hp: int = 30) -> CombatantState:
	var enemy: CombatantState = CombatantState.new()
	enemy.combatant_init("TestEnemy", max_hp)
	return enemy


func test_damage_boundaries(
	max_hp: int,
	initial_block: int,
	incoming_damage: int,
	expected_hp_loss: int,
	expected_block: int,
	expected_health: int,
	_test_parameters := [
		[30, 10, 6,   0,  4, 30],  # 伤害小于格挡
		[30, 10, 10,  0,  0, 30],  # 伤害等于格挡
		[30, 10, 14,  4,  0, 26],  # 伤害大于格挡
		[30, 10, 0,   0, 10, 30],  # 零伤害
		[30, 0,  50, 30,  0,  0],  # 超杀
		[100, 0, 150, 100, 0,  0] # 原来的100HP超杀测试
	]
) -> void:

	# Arrange：根据参数创建测试对象
	var enemy: CombatantState = create_combatant(max_hp)
	enemy.gain_block(initial_block)

	# Act：执行伤害结算
	var actual_hp_loss: int = enemy.take_damage(incoming_damage)

	# Assert：这里沿用原来的三个断言
	assert_int(actual_hp_loss).is_equal(expected_hp_loss)
	assert_int(enemy.current_block).is_equal(expected_block)
	assert_int(enemy.current_health).is_equal(expected_health)
