extends GdUnitTestSuite


func test_attack_damage_with_weakness() -> void:
	# 1. Arrange：准备测试数据
	var base_damage: int = 10
	var strength: int = 2
	var is_weak: bool = true
	var is_vulnerable: bool = false

	var expected: int = 9

	# 2. Act：调用实际业务代码
	var actual: int = AttackDamageResolver.calculate(
		base_damage,
		strength,
		is_weak,
		is_vulnerable
	)

	# 3. Assert：验证实际结果
	assert_int(actual).is_equal(expected)
	
func test_damage_rounding_with_weak_and_vulnerable() -> void:
	var base_damage: int = 5
	var strength: int = 0
	var is_weak: bool = true
	var is_vulnerable: bool = true
	
	var expected=5
	
	var actual: int = AttackDamageResolver.calculate(
		base_damage,
		strength,
		is_weak,
		is_vulnerable
	)

	# 3. Assert：验证实际结果
	assert_int(actual).is_equal(expected)
	
func test_attack_damage(
	base_damage: int,
	strength: int,
	is_weak: bool,
	is_vulnerable: bool,
	expected: int,
	_test_parameters := [
		[10, 2, true, false, 9],
		[5, 0, true, true, 5],
		[10,-20,false,false,0]
	]
) -> void:
	var actual: int = AttackDamageResolver.calculate(
		base_damage,
		strength,
		is_weak,
		is_vulnerable
	)

	assert_int(actual).is_equal(expected)
