## 新Boss生命对照与独立验证；继承正式结算及冻结的贪心策略。
extends "res://综合数值模型/运行战斗评估.gd"

var settings:Dictionary

func _deck(label:String, random_seed:int)->Array[CardDefinition]:
	if label == "随机合法开局":
		return _draft(random_seed)
	var deck:Array[CardDefinition] = _base_deck()
	if label == "参考9张":
		for id in settings.reference_deck:
			deck.append(cards[id])
	return deck

func _measure(enemy_id:String, hp:int, player_hp:int, label:String, samples:int, seed_start:int)->Dictionary:
	var rows:Array = []
	var examples:Array = []
	var wins:int = 0
	var life:float = 0.0
	var turns:float = 0.0
	for n in range(samples):
		var s:int = seed_start+n
		var result:Dictionary = _battle("boss_experiment",label,_deck(label,s),enemy_id,player_hp,int(settings.player_max_health),hp,s)
		wins += 1 if result.victory else 0
		life += result.remaining_health
		turns += result.turns
		var row:Dictionary = result.duplicate()
		row.erase("trace")
		rows.append(row)
		if n < 3 or (not result.victory and examples.size() < 6):
			examples.append(result)
		raw.clear()
	return {"enemy_id":enemy_id,"health":hp,"player_health":player_hp,"label":label,"samples":samples,"wins":wins,"win_rate":wins/float(samples),"mean_remaining_health":life/samples,"mean_turns":turns/samples,"outcomes":rows,"examples":examples}

func _run()->void:
	if not preload("res://tools/history_guard.gd").require_sandbox():
		quit(2)
		return
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://综合数值模型/Boss实验/评估参数.json"))
	_setup_evaluator()
	var validating:bool = OS.get_cmdline_user_args().has("validate")
	var results:Array = []
	var enemies:Array = [settings.reference_enemy]+settings.enemies
	for enemy_id in enemies:
		var enemy:EnemyDefinition = load("res://combatants/enemies/data/%s.tres" % enemy_id)
		var health_grid:Array = [enemy.max_health]
		if not validating and enemy_id != settings.reference_enemy:
			health_grid = settings.health_candidates
		for hp in health_grid:
			for label in settings.deck_labels:
				var count:int = int(settings.validation_samples) if validating else int(settings.coarse_samples)
				var start:int = int(settings.validation_seed_start) if validating else int(settings.training_seed_start)
				var row:Dictionary = _measure(enemy_id,hp,int(settings.player_health),label,count,start)
				results.append(row)
				print("%s %s HP%d %s：%d/%d，余血%.2f，回合%.2f" % ["验证" if validating else "对照",enemy.display_name,hp,label,row.wins,count,row.mean_remaining_health,row.mean_turns])
			await process_frame
		if validating:
			var wounded:Dictionary = _measure(enemy_id,enemy.max_health,35,"随机合法开局",int(settings.validation_samples),int(settings.validation_seed_start)+10000)
			results.append(wounded)
			print("伤后入场 %s 35/50HP：%d/%d" % [enemy.display_name,wounded.wins,wounded.samples])
			await process_frame
	var output:Dictionary = {"date":settings.evaluation_date,"settings":settings,"mode":"validation" if validating else "calibration","source_hashes":source_hashes,"godot_version":Engine.get_version_info().string,"results":results,"failures":failures}
	var file:FileAccess = FileAccess.open("res://综合数值模型/Boss实验/"+("验证数据.json" if validating else "生命对照数据.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	file.close()
	controller.dispose()
	await process_frame
	quit(0 if failures == 0 else 1)
