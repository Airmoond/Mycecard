extends GdUnitTestSuite


func test_can_play_card_checks_failure_reason() -> void:
	# Arrange：创建带有调用记录能力的真实对象
	var session: BattleSession = spy(BattleSession.new())

	# Act：战斗尚未开始，尝试检查能否出牌
	var playable: bool = session.can_play_card(null)

	# Assert：真实业务结果
	assert_bool(playable).is_false()

	# Assert：验证内部方法调用
	verify(session, 1).card_play_failure(null)

	# 验证操作权限检查被执行
	verify(session, 1).player_operation_failure()
