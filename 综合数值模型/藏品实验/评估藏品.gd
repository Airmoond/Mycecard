## 正式随机分支路线上的四组配对；藏品结算复用正式控制器与 RunState。
extends "res://综合数值模型/运行战斗评估.gd"

var settings:Dictionary


func _experiment_deck(label:String, random_seed:int)->Array[CardDefinition]:
	if label == "随机合法开局9张":
		return _draft(random_seed)
	var deck:Array[CardDefinition] = _base_deck()
	if label == "参考9张":
		for id in settings.reference_deck:
			deck.append(cards[id])
	return deck


func _run()->void:
	if not preload("res://tools/history_guard.gd").require_sandbox():
		quit(2)
		return
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://综合数值模型/藏品实验/评估参数.json"))
	_setup_evaluator()
	var definition:RunDefinition = load("res://tests/fixtures/phase5_run.tres")
	assert(not definition.is_invalid())
	assert(definition.character_definition == character)
	assert(definition.collection_pool.size() == 3 and definition.collection_option_count == 3)
	var control_definition:RunDefinition = definition.duplicate()
	control_definition.collection_pool = []
	var collection_by_id:Dictionary = {}
	for collection in definition.collection_pool:
		collection_by_id[collection.collection_id] = collection
	var results:Array = []
	for label in settings.deck_labels:
		for n in range(int(settings.samples)):
			var random_seed:int = int(settings.seed_start)+n
			var deck:Array[CardDefinition] = _experiment_deck(label, random_seed)
			var route_id:String = settings.route_ids[n % settings.route_ids.size()]
			for collection_id in settings.collection_ids:
				var collection:CollectionDefinition = null if collection_id == "none" else collection_by_id[collection_id]
				var run_definition:RunDefinition = control_definition if collection == null else definition
				var result:Dictionary = _branch_route(run_definition, random_seed, route_id, collection, deck)
				result["deck_label"] = label
				result["pair_index"] = n
				result["starting_deck_is_formal"] = label != "基础6张诊断"
				results.append(result)
			# 让大批评估定期交还事件循环，页面不改变战斗或选择状态。
			if n % 8 == 7:
				await process_frame
		print("藏品四组对照完成：%s，各%d条配对路线" % [label, int(settings.samples)])
	var output:Dictionary = {"settings":settings, "battle_parameters":params, "source_hashes":source_hashes, "godot_version":Engine.get_version_info().string, "battle_count":raw.size(), "route_count":results.size(), "failures":failures, "routes":results}
	var file:FileAccess = FileAccess.open("res://综合数值模型/藏品实验/原始藏品数据.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	file.close()
	print("藏品路线评估完成：%d条路线、%d场真实战斗，异常%d" % [results.size(), raw.size(), failures])
	controller.dispose()
	await process_frame
	quit(0 if failures == 0 else 1)
