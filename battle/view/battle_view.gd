## 战场布局、状态显示和查看器；不执行战斗规则。
class_name BattleView
extends Control

signal card_selected(card:CardInstance)
signal weapon_attack_requested
signal end_turn_requested
signal ui_feedback(id:StringName)

## 战场内部布局采用的设计尺寸；实际窗口按此尺寸等比适配。
const DESIGN_SIZE:Vector2 = Vector2(1920, 1080)
const COLLECTION_INSPECTOR_SCENE:PackedScene = preload("res://ui/inspect/collection_inspector.tscn")
const CARD_INSPECTOR_SCENE:PackedScene = preload("res://ui/inspect/card_inspector.tscn")
## 本页显示的战斗规则会话；规则操作由控制器提交。
var session:BattleSession
## 本页当前拥有的藏品查看器，关闭后清除引用。
var _collection_inspector:CollectionInspector
## 本页当前拥有的牌堆查看器，关闭后清除引用。
var _card_inspector:CardInspector
## 用于模态归属与全局输入阻挡的共享浮层服务。
var _overlay:OverlayHost
## 按设计尺寸缩放和居中的内部战场画布。
@onready var stage:Control = $main_layout
@onready var player_view:CombatantView = $main_layout/player_area/player_view
@onready var enemy_view:CombatantView = $main_layout/enemy_area/enemy_view
@onready var energy_label:Label = $main_layout/battle_info_area/energy_label
@onready var draw_pile_label:Button = $main_layout/battle_info_area/draw_pile_label
@onready var discard_pile_label:Button = $main_layout/battle_info_area/discard_pile_label
@onready var exhaust_pile_label:Button = $main_layout/battle_info_area/exhaust_pile_label
@onready var weapon_label:Label = $main_layout/player_area/weapon_label
## 按具体卡牌实例维护手牌输入与显示的共用组件。
@onready var hand_area:HandView = $main_layout/hand_area
@onready var end_turn_button:Button = $main_layout/end_turn_button
@onready var collection_button:Button = $main_layout/collection_button
@onready var round_label:Label = $main_layout/round_label

## 当前会话的战斗状态；没有会话时为 [code]null[/code]。
var battle_state:BattleState:
	get: return session.battle_state if session != null else null
## 当前会话持有的只读藏品定义；没有会话时为 [code]null[/code]。
var selected_collection:CollectionDefinition:
	get: return session.selected_collection if session != null else null

## 初始化按钮禁用状态，连接玩家意图和布局变化，并延迟适配战场尺寸。
func _ready()->void:
	for button:Button in [draw_pile_label, discard_pile_label, exhaust_pile_label]:
		button.disabled = true
	collection_button.disabled = true
	end_turn_button.disabled = true
	hand_area.card_selected.connect(_on_card_selected)
	## 将手牌区的武器攻击信号转发为本页操作意图。
	hand_area.weapon_attack_requested.connect(func()->void: weapon_attack_requested.emit())
	## 将结束回合按钮点击转发为本页操作意图。
	end_turn_button.pressed.connect(func()->void: end_turn_requested.emit())
	collection_button.pressed.connect(_on_collection_button_pressed)
	draw_pile_label.pressed.connect(_on_pile_button_pressed.bind("draw"))
	discard_pile_label.pressed.connect(_on_pile_button_pressed.bind("discard"))
	exhaust_pile_label.pressed.connect(_on_pile_button_pressed.bind("exhaust"))
	resized.connect(_fit_stage)
	hand_area.resized.connect(hand_area.fit_cards)
	_fit_stage.call_deferred()

## 返回本页的战斗控制器；节点缺失或类型不匹配时为 [code]null[/code]。
func get_controller()->BattleController:
	return get_node_or_null("battle_controller") as BattleController

## 替换共享浮层服务的阻挡通知连接，并将服务同步给手牌视图。
func configure_overlay(host:OverlayHost)->void:
	if is_instance_valid(_overlay) and _overlay.blocking_changed.is_connected(_on_blocking_changed):
		_overlay.blocking_changed.disconnect(_on_blocking_changed)
	_overlay = host
	if is_instance_valid(_overlay):
		_overlay.blocking_changed.connect(_on_blocking_changed)
	hand_area.configure_overlay(host)

## 浮层阻挡状态变化时，在本页仍有效且已有会话的条件下刷新交互显示。
func _on_blocking_changed(_blocked:bool)->void:
	if session != null and is_inside_tree() and not is_queued_for_deletion():
		render()

## 清理旧查看器和手牌控件，绑定新会话及双方角色状态，然后刷新显示。
func bind_session(value:BattleSession)->void:
	_clear_inspectors()
	hand_area.clear()
	session = value
	player_view.bind_combatant_state(battle_state.player_state)
	enemy_view.bind_combatant_state(battle_state.enemy_state)
	render()

## 返回本页查看器或共享模态窗口是否阻挡战斗输入。
func input_is_blocked()->bool:
	return _has_inspector() or (is_instance_valid(_overlay) and _overlay.has_blocking_modal())

## 返回当前是否允许打开藏品查看器，沿用通用查看条件。
func _can_inspect_collection()->bool:
	return _can_inspect()

## 返回是否已有会话、处于可操作玩家阶段且没有输入阻挡。
func _can_inspect()->bool:
	return session != null and session.can_end_turn() and not input_is_blocked()

## 向控制器转发手牌视图选中的卡牌实例，不执行出牌规则。
func _on_card_selected(card:CardInstance)->void:
	card_selected.emit(card)

## 按设计尺寸等比缩放并居中战场，随后延迟调整手牌尺寸。
func _fit_stage()->void:
	if not is_node_ready():
		return
	var factor:float = minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)
	stage.size = DESIGN_SIZE
	stage.scale = Vector2(factor, factor)
	stage.position = (size - DESIGN_SIZE * factor) * 0.5
	hand_area.fit_cards.call_deferred()

## 将查看器交给共享浮层并登记本页所有权；没有浮层服务时直接挂载到本页。
func _attach_modal(modal:Control)->void:
	if is_instance_valid(_overlay):
		_overlay.attach_page_modal(modal, self)
		return
	else:
		add_child(modal)

## 在查看器与共享浮层均有效时取消模态登记。
func _unregister_modal(modal:Control)->void:
	if is_instance_valid(modal) and is_instance_valid(_overlay):
		_overlay.unregister_modal(modal)

## 本页退出场景树时清理其拥有的全部查看器。
func _exit_tree()->void:
	_clear_inspectors()

## 从当前会话刷新角色、敌人意图、能量、牌堆、武器、手牌和操作按钮；没有战斗状态时报错并返回。
func render()->void:
	if battle_state == null:
		push_error("尚未创建战斗状态，无法刷新战斗界面");
		return;

	player_view.refresh_combatant_view();#角色View会从已绑定的CombatantState中重新读取生命和格挡
	enemy_view.refresh_combatant_view();
	enemy_view.set_intent(
		session.enemy_intent_text()
	);#显示和敌人回合共同读取同一个当前行动资源
	energy_label.text = "能量：%d / %d" % [
		battle_state.current_available_energy,
		battle_state.energy_per_turn
	];#%d会按数组顺序填入“当前能量 / 每回合能量”
	energy_label.tooltip_text = "";
	if battle_state.attack_card_energy_this_turn > 0:
		energy_label.tooltip_text = "本回合每打出一张攻击牌回复%d能量。\n先支付费用，再回能并执行卡牌效果；武器攻击不触发。" % battle_state.attack_card_energy_this_turn;
	draw_pile_label.text = "抽牌堆：%d" % battle_state.draw_pile.size();#size()返回数组中的卡牌数量
	if battle_state.draw_blocked_this_turn:
		draw_pile_label.text += "\n禁抽";# 独立第二行提示，避免按钮变宽遮住相邻牌堆入口。
	draw_pile_label.tooltip_text = "本回合不能抽牌，下个玩家回合开始时解除。" if battle_state.draw_blocked_this_turn else "";
	discard_pile_label.text = "弃牌堆：%d" % battle_state.discard_pile.size();
	exhaust_pile_label.text = "消耗牌：%d" % battle_state.exhaust_pile.size();
	var equipped:CardInstance = battle_state.equipped_weapon;
	weapon_label.text = "武器：未装备";
	if equipped != null:
		weapon_label.text = "武器：%s\n攻击：%d  耐久：%d / %d" % [
			equipped.definition.card_name,
			equipped.weapon.current_attack,
			equipped.weapon.current_durability,
			equipped.weapon.max_durability
		];
	end_turn_button.disabled = input_is_blocked() or not session.can_end_turn();
	collection_button.disabled = not _can_inspect_collection();
	for pile_button:Button in [draw_pile_label, discard_pile_label, exhaust_pile_label]:
		pile_button.disabled = not _can_inspect();# 空堆和禁抽都不妨碍只读浏览。
	hand_area.render(session, input_is_blocked());#以BattleState.hand为标准，让屏幕上的手牌与数据完全一致
	var phase_text:String = "你的回合" if battle_state.current_phase == BattleState.BattlePhase.PLAYER_TURN else "敌人回合" if battle_state.current_phase == BattleState.BattlePhase.ENEMY_TURN else "准备战斗" if battle_state.current_phase == BattleState.BattlePhase.SETUP else "战斗结束"
	round_label.text = "第 %d 回合 · %s" % [battle_state.current_turn_number, phase_text]

## 返回当前藏品查看器引用是否有效。
func _has_collection_inspector()->bool:
	return is_instance_valid(_collection_inspector);

## 返回当前是否持有有效的藏品或牌堆查看器。
func _has_inspector()->bool:
	return _has_collection_inspector() or is_instance_valid(_card_inspector);

## 在允许查看时创建并配置藏品查看器，连接关闭通知并刷新输入状态。
func _on_collection_button_pressed()->void:
	if not _can_inspect_collection():
		return;
	_collection_inspector = COLLECTION_INSPECTOR_SCENE.instantiate();
	_attach_modal(_collection_inspector);
	_collection_inspector.setup(selected_collection);
	_collection_inspector.closed.connect(_on_collection_inspector_closed);
	ui_feedback.emit(&"ui_confirm");
	render();

## 取消藏品查看器的信号及模态登记，清除引用并恢复界面交互显示。
func _on_collection_inspector_closed()->void:
	ui_feedback.emit(&"ui_confirm");
	if _has_collection_inspector() and _collection_inspector.closed.is_connected(_on_collection_inspector_closed):
		_collection_inspector.closed.disconnect(_on_collection_inspector_closed);
	_unregister_modal(_collection_inspector);
	_collection_inspector = null;
	if battle_state != null:
		render();

## 打开抽牌、弃牌或消耗牌堆的只读查看器；未知牌堆名称或初始化失败时不保留查看器。
func _on_pile_button_pressed(pile_name:String)->void:
	if not _can_inspect():
		return;
	var cards:Array[CardInstance];
	var title:String;
	match pile_name:
		"draw":
			cards = battle_state.draw_pile;
			title = "抽牌堆";
		"discard":
			cards = battle_state.discard_pile;
			title = "弃牌堆";
		"exhaust":
			cards = battle_state.exhaust_pile;
			title = "消耗牌堆";
		_:
			return;
	_card_inspector = CARD_INSPECTOR_SCENE.instantiate();
	_attach_modal(_card_inspector);
	if not _card_inspector.setup_instances(cards, title):
		_clear_card_inspector();
		return;
	_card_inspector.closed.connect(_on_card_inspector_closed);
	ui_feedback.emit(&"ui_confirm");
	render();

## 取消牌堆查看器的信号及模态登记，清除引用并恢复界面交互显示。
func _on_card_inspector_closed()->void:
	ui_feedback.emit(&"ui_confirm");
	if is_instance_valid(_card_inspector) and _card_inspector.closed.is_connected(_on_card_inspector_closed):
		_card_inspector.closed.disconnect(_on_card_inspector_closed);
	_unregister_modal(_card_inspector);
	_card_inspector = null;
	if battle_state != null:
		render();

## 清理本页持有的藏品和牌堆查看器。
func _clear_inspectors()->void:
	_clear_collection_inspector();
	_clear_card_inspector();

## 断开牌堆查看器连接、取消模态登记并移出场景树，随后排队释放。
func _clear_card_inspector()->void:
	if not is_instance_valid(_card_inspector):
		_card_inspector = null;
		return;
	if _card_inspector.closed.is_connected(_on_card_inspector_closed):
		_card_inspector.closed.disconnect(_on_card_inspector_closed);
	_unregister_modal(_card_inspector);
	_card_inspector.get_parent().remove_child(_card_inspector);
	_card_inspector.queue_free();
	_card_inspector = null;

## 断开藏品查看器连接、取消模态登记并移出场景树，随后排队释放。
func _clear_collection_inspector()->void:
	if not _has_collection_inspector():
		_collection_inspector = null;
		return;
	if _collection_inspector.closed.is_connected(_on_collection_inspector_closed):
		_collection_inspector.closed.disconnect(_on_collection_inspector_closed);
	_unregister_modal(_collection_inspector);
	_collection_inspector.get_parent().remove_child(_collection_inspector);
	_collection_inspector.queue_free();
	_collection_inspector = null;
