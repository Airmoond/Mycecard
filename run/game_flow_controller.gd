## 将页面意图交给RunSession，并按真实阶段组织展示；不执行整局规则。
class_name GameFlowController
extends Node

const UNEXPECTED_SCENE:PackedScene = preload("res://run/encounter/unexpected_encounter_view.tscn")
const MENU_SCRIPT:Script = preload("res://run/screens/main_menu.gd")
const DRAFT_SCRIPT:Script = preload("res://run/draft/starting_draft_view.gd")
const COLLECTION_SCRIPT:Script = preload("res://run/collection/collection_choice_view.gd")
const MAP_SCRIPT:Script = preload("res://run/map/map_view.gd")
const BATTLE_SCRIPT:Script = preload("res://battle/view/battle_view.gd")
const REWARD_SCRIPT:Script = preload("res://run/reward/reward_view.gd")
const RESULT_SCRIPT:Script = preload("res://run/screens/run_result.gd")
const UNEXPECTED_SCRIPT:Script = preload("res://run/encounter/unexpected_encounter_view.gd")

@export var run_definition:RunDefinition
@export var main_menu_scene:PackedScene
@export var starting_draft_scene:PackedScene
@export var collection_choice_scene:PackedScene
@export var map_scene:PackedScene
@export var battle_scene:PackedScene
@export var reward_scene:PackedScene
@export var result_scene:PackedScene
## -1随机创建新局；测试和问题复现可明确指定种子。
@export var run_seed:int = -1

var run_session:RunSession
var router:PageRouter
var audio:GameAudioManager
var overlay_host:OverlayHost
@onready var page_container:Control = $"../page_container"

var run_state:RunState:
	get: return run_session.state if run_session != null else null
var current_page:Control:
	get: return router.current_page if router != null else null

func _ready()->void:
	if not _validate_configuration():
		return
	audio = get_node_or_null("../audio_manager") as GameAudioManager
	overlay_host = get_node_or_null("../overlay_host") as OverlayHost
	router = PageRouter.new()
	add_child(router)
	router.configure(page_container)
	_show_main_menu()

func _prepare_page(scene:PackedScene, expected:Script, initializer:Callable = Callable(), retry:Callable = Callable())->Control:
	var page:Control = router.prepare(scene, expected, func(candidate:Control)->bool:
		if candidate is MapView:
			candidate.configure_overlay(overlay_host)
		if initializer.is_valid():
			var result:Variant = initializer.call(candidate)
			return not (result is bool and not result)
		return true
	)
	if page == null and overlay_host != null:
		overlay_host.show_navigation_error(retry if retry.is_valid() else _show_for_state, _show_main_menu)
	return page

func _commit_page(page:Control, combat:bool = false)->bool:
	if page == null or not router.commit(page):
		return false
	if audio != null:
		audio.set_music_state(&"combat" if combat else &"exploration")
	return true

## 显示主菜单，并连接开始新一局的请求。
##
## 页面切换成功后，将 [member run_session] 设为 [code]null[/code]，
## 并清除覆盖层宿主（若存在）中的临时内容。
## 如果主菜单准备失败，则直接返回。
func _show_main_menu() -> void:
	var menu: MainMenu = _prepare_page(main_menu_scene, MENU_SCRIPT, Callable(), _show_main_menu) as MainMenu
	if menu == null:
		return
	menu.start_requested.connect(_start_new_run.bind(menu))
	if _commit_page(menu):
		run_session = null
		if overlay_host != null:
			overlay_host.clear_transient()

func _start_new_run(source_page:MainMenu = null)->void:
	if source_page != null and not router.is_current(source_page):
		return
	var prepared:RunSession = RunSession.new()
	if not prepared.initialize(run_definition, run_seed):
		if current_page is MainMenu:
			current_page.reset_start_request()
		return
	_display_new_run(prepared)

## 首次进入构筑失败时重试同一待显示会话，不重新创建随机内容。
func _display_new_run(prepared:RunSession)->void:
	var page:StartingDraftView = _prepare_draft(prepared, _display_new_run.bind(prepared))
	if page == null or not _commit_page(page):
		if current_page is MainMenu:
			current_page.reset_start_request()
		return
	run_session = prepared
	if overlay_host != null:
		overlay_host.clear_transient()
	_play_flow_sound(&"ui_confirm")

func _prepare_draft(session:RunSession, retry:Callable = Callable())->StartingDraftView:
	var page:StartingDraftView = _prepare_page(starting_draft_scene, DRAFT_SCRIPT, func(candidate:StartingDraftView)->void:
		candidate.setup(session.state.get_draft_rarity(), session.get_draft_candidates(), session.state.owned_cards)
	, retry) as StartingDraftView
	if page != null:
		page.card_selected.connect(_handle_starting_card_selected.bind(page, session.step_token))
		page.back_requested.connect(_handle_page_back.bind(page, session.step_token))
	return page

func _show_starting_draft()->void:
	if run_session != null and run_state.status == RunState.RunStatus.DRAFTING:
		_commit_page(_prepare_draft(run_session))

func _handle_starting_card_selected(card:CardDefinition, source_page:StartingDraftView = null, token:int = -1)->void:
	if not current_page is StartingDraftView or not _current_source(source_page):
		return
	if run_session.choose_starting_card(card, token):
		_after_command()

func _show_map()->void:
	if run_state == null or run_state.status != RunState.RunStatus.IN_PROGRESS:
		return
	var page:MapView = _prepare_page(map_scene, MAP_SCRIPT, func(candidate:MapView)->bool:
		return candidate.setup(run_definition.map_definition, run_state)
	) as MapView
	if page != null:
		page.node_selected.connect(_handle_map_node_selected.bind(page, run_session.step_token))
		_commit_page(page)

func _handle_map_node_selected(node_id:String, source_page:MapView = null, token:int = -1)->void:
	if run_session == null or not current_page is MapView or not _current_source(source_page):
		return
	if run_session.enter_node(node_id, token):
		_after_command()

func _show_collection_choice()->void:
	var page:CollectionChoiceView = _prepare_page(collection_choice_scene, COLLECTION_SCRIPT, func(candidate:CollectionChoiceView)->bool:
		return candidate.setup(run_state.collection_candidates)
	) as CollectionChoiceView
	if page != null:
		page.collection_selected.connect(_handle_collection_selected.bind(page, run_session.step_token))
		page.back_requested.connect(_handle_collection_back.bind(page, run_session.step_token))
		_commit_page(page)

func _handle_collection_selected(collection:CollectionDefinition, source_page:CollectionChoiceView = null, token:int = -1)->void:
	if not current_page is CollectionChoiceView or not _current_source(source_page):
		return
	if run_session.choose_collection(collection, token):
		_after_command()

func _handle_collection_back(source_page:CollectionChoiceView, token:int = -1)->void:
	_handle_page_back(source_page, token)

func _show_unexpected_encounter()->void:
	var page:UnexpectedEncounterView = _prepare_page(UNEXPECTED_SCENE, UNEXPECTED_SCRIPT, func(candidate:UnexpectedEncounterView)->bool:
		return candidate.setup(run_state)
	) as UnexpectedEncounterView
	if page != null:
		page.option_selected.connect(_handle_unexpected_selected.bind(page, run_session.step_token))
		page.continue_requested.connect(_handle_unexpected_continue.bind(page, run_session.step_token))
		_commit_page(page)

func _handle_unexpected_selected(option_id:String, card:CardDefinition, deck_index:int, source_page:UnexpectedEncounterView, token:int = -1)->void:
	if run_session == null or not current_page is UnexpectedEncounterView or not _current_source(source_page):
		return
	if run_session.resolve_unexpected(option_id, card, deck_index, token):
		_after_command()
	else:
		source_page.setup(run_state)

func _handle_unexpected_continue(source_page:UnexpectedEncounterView, token:int = -1)->void:
	if run_session != null and _current_source(source_page) and run_session.continue_unexpected(token):
		_after_command()

func _start_battle_for_node(_node:MapNodeDefinition = null)->void:
	var request:Dictionary = run_session.get_battle_request()
	if request.is_empty():
		return
	var page:BattleView = _prepare_page(battle_scene, BATTLE_SCRIPT, func(candidate:BattleView)->bool:
		var controller:BattleController = candidate.get_controller()
		if controller == null:
			return false
		controller.configure_context(request.battle_id, request.node_id, request.rng)
		controller.configure_services(audio, overlay_host)
		return controller.prepare_battle(request.encounter_definition, request.player_definition, request.owned_cards, request.current_health, request.max_health, request.selected_collection)
	) as BattleView
	if page == null:
		return
	var controller:BattleController = page.get_controller()
	controller.battle_finished.connect(_handle_battle_finished.bind(controller))
	if _commit_page(page, true):
		controller.activate_battle()

func _handle_battle_finished(_victory:bool, _health:int, _max_health:int, source_controller:BattleController = null)->void:
	if run_session == null or not current_page is BattleView:
		return
	var controller:BattleController = (current_page as BattleView).get_controller()
	if source_controller != null and source_controller != controller:
		return
	if run_session.submit_battle_result(controller.get_battle_result()):
		_after_command(false)

func _show_reward()->void:
	if run_state == null or run_state.status != RunState.RunStatus.CHOOSING_REWARD:
		return
	var page:RewardView = _prepare_page(reward_scene, REWARD_SCRIPT, func(candidate:RewardView)->bool:
		return candidate.setup(run_state.reward_state.candidates)
	) as RewardView
	if page != null:
		page.reward_selected.connect(_handle_reward_selected.bind(page, run_session.step_token))
		page.reward_skipped.connect(_handle_reward_skipped.bind(page, run_session.step_token))
		_commit_page(page)

func _handle_reward_selected(card:CardDefinition, source_page:RewardView = null, token:int = -1)->void:
	if not current_page is RewardView or not _current_source(source_page):
		return
	if run_session.choose_reward(card, token):
		_after_command()

func _handle_reward_skipped(source_page:RewardView, token:int = -1)->void:
	if current_page is RewardView and _current_source(source_page) and run_session.skip_reward(token):
		_after_command()

func _show_result(victory:bool)->void:
	var page:RunResult = _prepare_page(result_scene, RESULT_SCRIPT, func(candidate:RunResult)->void:
		candidate.setup(victory)
	) as RunResult
	if page != null:
		page.restart_requested.connect(_handle_page_back.bind(page, run_session.step_token))
		_commit_page(page)

func _handle_page_back(source_page:Control, token:int = -1)->void:
	if _current_source(source_page) and (token == -1 or (run_session != null and token == run_session.step_token)):
		_show_main_menu()

func _current_source(source:Node)->bool:
	return current_page != null and (source == null or router.is_current(source))

func _after_command(confirm:bool = true)->void:
	if confirm:
		_play_flow_sound(&"ui_confirm")
	if int(run_session.last_command_result.get("actual_heal", 0)) > 0:
		_play_flow_sound(&"heal_gain", 1)
	_show_for_state()

## 按业务事实重新展示；重试只创建页面，不重复提交规则命令。
func _show_for_state()->void:
	if run_state == null:
		_show_main_menu()
		return
	match run_state.status:
		RunState.RunStatus.DRAFTING: _show_starting_draft()
		RunState.RunStatus.IN_PROGRESS: _show_map()
		RunState.RunStatus.CHOOSING_COLLECTION: _show_collection_choice()
		RunState.RunStatus.IN_BATTLE: _start_battle_for_node()
		RunState.RunStatus.CHOOSING_REWARD: _show_reward()
		RunState.RunStatus.CHOOSING_UNEXPECTED, RunState.RunStatus.UNEXPECTED_RESULT: _show_unexpected_encounter()
		RunState.RunStatus.VICTORY: _show_result(true)
		RunState.RunStatus.DEFEAT: _show_result(false)

func _play_flow_sound(id:StringName, priority:int = 0)->void:
	if audio != null:
		audio.play_sfx(id, "", priority)

func _validate_configuration()->bool:
	if run_definition == null: # 整局玩家、牌组、地图和奖励都从这一个入口配置读取。
		push_error("GameFlowController：未配置 run_definition。")
		return false

	if run_definition.is_invalid(): # 具体静态字段交给RunDefinition自身验证。
		push_error("GameFlowController：run_definition 的内容无效，请检查其错误信息。")
		return false

	if main_menu_scene == null:
		push_error("GameFlowController：未配置 main_menu_scene。")
		return false
	if starting_draft_scene == null:
		push_error("GameFlowController：未配置 starting_draft_scene。");
		return false;
	if not run_definition.collection_pool.is_empty() and collection_choice_scene == null:
		push_error("GameFlowController：未配置 collection_choice_scene。")
		return false

	if map_scene == null:
		push_error("GameFlowController：未配置 map_scene。")
		return false

	if battle_scene == null:
		push_error("GameFlowController：未配置 battle_scene。")
		return false

	if reward_scene == null:
		push_error("GameFlowController：未配置 reward_scene。")
		return false

	if result_scene == null:
		push_error("GameFlowController：未配置 result_scene。")
		return false

	if page_container == null or not is_instance_valid(page_container): # 所有页面都必须拥有同一个挂载位置。
		push_error("GameFlowController：未找到可用的 page_container。")
		return false

	return true # 所有流程依赖均已准备好，可以进入主菜单。
