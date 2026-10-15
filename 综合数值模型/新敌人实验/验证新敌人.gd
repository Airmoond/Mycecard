## 仅用未参与调参的种子检验定稿正式资源；不修改数字或自动再训练。
extends "res://综合数值模型/运行战斗评估.gd"

func _run()->void:
	if not preload("res://tools/history_guard.gd").require_sandbox():
		quit(2)
		return
	var settings:Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://综合数值模型/新敌人实验/校准参数.json"))
	_setup_evaluator()
	var results:Array = []
	for enemy_id in settings.enemies:
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id)
		var wins:int = 0
		var hp_sum:float = 0.0
		var turns_sum:float = 0.0
		var samples:Array = []
		var examples:Array = []
		for n in range(int(settings.validation_samples)):
			var result:Dictionary = _battle("validation","基础6张",_base_deck(),enemy_id,int(settings.player_health),int(settings.player_max_health),enemy.max_health,int(settings.validation_seed_start)+n)
			wins += 1 if result.victory else 0
			hp_sum += result.remaining_health
			turns_sum += result.turns
			var row:Dictionary = result.duplicate()
			row.erase("trace")
			samples.append(row)
			if n < 6 or (not result.victory and examples.size() < 12):
				examples.append(result)
			raw.clear()
		var rate:float = wins / float(settings.validation_samples)
		results.append({"enemy_id":enemy_id,"name":enemy.display_name,"health":enemy.max_health,"wins":wins,"samples":settings.validation_samples,"win_rate":rate,"mean_remaining_health":hp_sum/float(settings.validation_samples),"mean_turns":turns_sum/float(settings.validation_samples),"within_target_band":rate >= float(settings.acceptance_band[0]) and rate <= float(settings.acceptance_band[1]),"outcomes":samples,"examples":examples})
		print("独立复核 %s：%d/%d=%.3f，平均余血%.2f，回合%.2f" % [enemy.display_name,wins,settings.validation_samples,rate,hp_sum/float(settings.validation_samples),turns_sum/float(settings.validation_samples)])
		await process_frame
	var output:Dictionary = {"settings":settings,"source_hashes":source_hashes,"results":results,"failures":failures,"godot_version":Engine.get_version_info().string}
	var file:FileAccess = FileAccess.open("res://综合数值模型/新敌人实验/验证数据.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	file.close()
	controller.dispose()
	await process_frame
	quit(0 if failures == 0 else 1)
