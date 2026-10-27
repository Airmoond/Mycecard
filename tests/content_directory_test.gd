## 内容目录约定、迁移后的资源入口和稳定 UID 回归。
extends SceneTree

var _failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func _expect(value:bool, message:String)->void:
	if not value:
		_failures += 1
		push_error(message)

func _run()->void:
	for domain:String in ["battle", "cards", "characters", "collections", "combatants", "run"]:
		_check_data_directories("res://" + domain)
	for obsolete:String in ["res://combatants/data", "res://battle/data", "res://artworks", "res://assets/images"]:
		_expect(not DirAccess.dir_exists_absolute(obsolete), "已迁移的目录不应重新出现：" + obsolete)
	var player_path:String = "res://combatants/players/data/player.tres"
	var player:CombatantDefinition = load(player_path)
	_expect(player != null and not player.is_invalid(), "玩家定义能从专属目录加载")
	_expect(ResourceUID.id_to_text(ResourceLoader.get_resource_uid(player_path)) == "uid://df8b6i2mgvp8g", "玩家资源的稳定 UID 不变")
	var definition:RunDefinition = load("res://run/data/default_run.tres")
	_expect(definition != null and not definition.is_invalid(), "默认冒险资源及传递引用有效")
	if definition != null:
		_expect(definition.get_script().resource_path == "res://run/run_definition.gd", "整局定义脚本不混入 data")
		_expect(definition.character_definition.combatant_definition == player, "角色配置引用迁移后的玩家资源")
		_expect(definition.character_definition.starting_deck_entries[0].get_script().resource_path == "res://cards/deck_entry_definition.gd", "牌组条目归属卡牌领域")
		_expect(definition.map_definition.get_script().resource_path == "res://run/map/map_definition.gd", "地图定义归属地图模块")
		_expect(definition.map_definition.nodes[0].get_script().resource_path == "res://run/map/map_node_definition.gd", "地图节点定义归属地图模块")
		for encounter:EncounterDefinition in definition.normal_encounter_pool + definition.boss_encounter_pool:
			_expect(encounter.resource_path.begins_with("res://battle/encounters/data/"), "战斗遭遇实例位于专属 data")
			_expect(encounter.get_script().resource_path == "res://battle/encounters/encounter_definition.gd", "战斗遭遇定义不混入 data")
	for directory:String in ["res://assets/cards", "res://assets/combatants", "res://assets/backgrounds"]:
		var folder:DirAccess = DirAccess.open(directory)
		_expect(folder != null, "美术分类目录存在：" + directory)
		if folder == null:
			continue
		for filename:String in folder.get_files():
			if filename.ends_with(".png"):
				var asset_path:String = directory.path_join(filename)
				var identity:int = ResourceLoader.get_resource_uid(asset_path)
				_expect(identity != ResourceUID.INVALID_ID, "美术资源保留有效 UID：" + asset_path)
				if identity != ResourceUID.INVALID_ID:
					_expect(ResourceUID.get_id_path(identity) == asset_path, "美术 UID 解析到新路径：" + asset_path)
	print("内容目录检查完成，失败数：%d" % _failures)
	quit(0 if _failures == 0 else 1)

func _check_data_directories(directory:String)->void:
	var folder:DirAccess = DirAccess.open(directory)
	_expect(folder != null, "领域目录存在：" + directory)
	if folder == null:
		return
	if directory.get_file() == "data":
		for filename:String in folder.get_files():
			_expect(not filename.ends_with(".gd") and not filename.ends_with(".gd.uid"), "data 仅保存资源实例，不放定义脚本：" + directory.path_join(filename))
	for child:String in folder.get_directories():
		_check_data_directories(directory.path_join(child))
