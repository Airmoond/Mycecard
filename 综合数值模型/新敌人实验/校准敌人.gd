## 继承冻结的正式结算与贪心策略，只改敌人复制资源的数字进行训练。
extends "res://综合数值模型/运行战斗评估.gd"

var settings:Dictionary
var variant:Dictionary = {}
var search:Array = []

func _make_encounter(enemy_id:String, enemy_hp:int)->EncounterDefinition:
	var encounter:EncounterDefinition = super._make_encounter(enemy_id,enemy_hp)
	var actions:Array[EnemyActionDefinition] = []
	for index in range(encounter.enemy_definition.action_pattern.size()):
		var action:EnemyActionDefinition = encounter.enemy_definition.action_pattern[index].duplicate(true)
		for effect in action.effects:
			if enemy_id == "bulwark_sentinel" and effect.effect_type == CombatEffectDefinition.EffectType.BLOCK and index > 0:
				effect.amount = int(variant.get("later_block",16))
			if enemy_id != "bulwark_sentinel" and effect.effect_type == CombatEffectDefinition.EffectType.DAMAGE:
				effect.amount = int(variant.get("base_attack",2 if enemy_id == "ragebound_brute" else 9)) + (2 if enemy_id == "hexbound_acolyte" and index == 1 else 0)
		actions.append(action)
	encounter.enemy_definition.action_pattern = actions
	return encounter

func _measure(enemy_id:String, hp:int, samples:int, numbers:Dictionary)->Dictionary:
	variant = numbers
	var wins:int = 0
	var life:float = 0.0
	var turns:float = 0.0
	var deck:Array[CardDefinition] = _base_deck()
	for n in range(samples):
		var result:Dictionary = _battle("calibration","基础6张",deck,enemy_id,int(settings.player_health),int(settings.player_max_health),hp,int(settings.training_seed_start)+n)
		wins += 1 if result.victory else 0
		life += result.remaining_health
		turns += result.turns
		raw.clear()
	var record:Dictionary = {"enemy_id":enemy_id,"health":hp,"base_attack":numbers.get("base_attack",21),"later_block":numbers.get("later_block",0),"samples":samples,"wins":wins,"win_rate":wins/float(samples),"mean_remaining_health":life/samples,"mean_turns":turns/samples}
	search.append(record)
	return record

func _run()->void:
	if not preload("res://tools/history_guard.gd").require_sandbox():
		quit(2)
		return
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://综合数值模型/新敌人实验/校准参数.json"))
	_setup_evaluator()
	var selected:Array = []
	var requested:PackedStringArray = OS.get_cmdline_user_args()
	if not requested.is_empty() and FileAccess.file_exists("res://综合数值模型/新敌人实验/训练数据.json"):
		var previous:Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://综合数值模型/新敌人实验/训练数据.json"))
		for item in previous.selected:
			if not requested.has(item.enemy_id):
				selected.append(item)
	for enemy_id in settings.enemies:
		if not requested.is_empty() and not requested.has(enemy_id):
			continue
		var best:Dictionary = {}
		var variants:Array = [{"later_block":14},{"later_block":15}]
		var health_grid:Array = [80,85,90,95,100]
		if enemy_id == "hexbound_acolyte":
			variants = [{"base_attack":9}]
			health_grid = [64,66,68]
		elif enemy_id == "ragebound_brute":
			variants = [{"base_attack":2}]
			health_grid = [80,82,84,86,88]
		var coarse:Array = []
		for numbers in variants:
			for hp in health_grid:
				var value:Dictionary = _measure(enemy_id,hp,int(settings.coarse_samples),numbers)
				coarse.append(value)
				if best.is_empty() or absf(value.win_rate-float(settings.target_win_rate)) < absf(best.win_rate-float(settings.target_win_rate)):
					best = value
			print("粗调 %s %s：目前最接近HP%d，胜率%.3f" % [enemy_id,str(numbers),best.health,best.win_rate])
			await process_frame
		coarse.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return absf(a.win_rate-float(settings.target_win_rate)) < absf(b.win_rate-float(settings.target_win_rate)))
		best = {}
		for item in coarse.slice(0,4):
			var value:Dictionary = _measure(enemy_id,item.health,int(settings.training_samples),item)
			if best.is_empty() or absf(value.win_rate-float(settings.target_win_rate)) < absf(best.win_rate-float(settings.target_win_rate)):
				best = value
		print("训练选定 %s：HP%d，基攻%d，%d/%d=%.3f" % [enemy_id,best.health,best.base_attack,best.wins,best.samples,best.win_rate])
		selected.append(best)
		await process_frame
	var output:Dictionary = {"settings":settings,"source_hashes":source_hashes,"candidates":search,"selected":selected,"failures":failures}
	var file:FileAccess = FileAccess.open("res://综合数值模型/新敌人实验/训练数据.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	file.close()
	controller.dispose()
	await process_frame
	quit(0 if failures == 0 else 1)
