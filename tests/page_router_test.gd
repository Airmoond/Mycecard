extends SceneTree

const MENU:PackedScene = preload("res://run/screens/main_menu.tscn");
const MENU_SCRIPT:Script = preload("res://run/screens/main_menu.gd");
const ERROR_SCENE:PackedScene = preload("res://ui/navigation/navigation_error.tscn");
var failures:int = 0;

func _initialize()->void:
	call_deferred("_run");

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1;
		push_error(message);

func _run()->void:
	var container:Control = Control.new();
	container.size = Vector2(1024, 600);
	root.add_child(container);
	var router:PageRouter = PageRouter.new();
	root.add_child(router);
	router.configure(container);
	var commits:Array[Dictionary] = [];
	router.page_committed.connect(func(previous:Control, current:Control)->void: commits.append({"previous": previous, "current": current}));
	var initial:MainMenu = router.prepare(MENU, MENU_SCRIPT) as MainMenu;
	expect(initial != null and initial.is_node_ready() and not initial.is_visible_in_tree() and not initial.can_process(), "候选已ready但准备阶段隐藏且禁止处理输入");
	expect(router.current_page == null and router.generation == 0 and not router.is_current(initial), "准备不提前提交当前页面或生成号");
	expect(router.commit(initial) and router.is_current(initial) and initial.is_visible_in_tree() and initial.can_process(), "提交后页面可见并恢复继承处理");
	expect(router.generation == 1 and commits.size() == 1 and commits[0]["previous"] == null, "首次提交记录一次生成号和通知");
	await process_frame;
	var generation:int = router.generation;
	var wrong:PackedScene = PackedScene.new();
	var wrong_root:Control = Control.new();
	expect(wrong.pack(wrong_root) == OK, "准备无脚本Control作为具体类型错误夹具");
	wrong_root.free();
	print("以下两条PageRouter准备错误为预期。");
	expect(router.prepare(wrong, MENU_SCRIPT) == null, "同为Control但缺少具体脚本的页面应拒绝");
	expect(router.current_page == initial and router.generation == generation and initial.is_inside_tree(), "类型错误保留原页面及生成号");
	var failed_ref:Array[WeakRef] = [];
	var failed:Control = router.prepare(MENU, MENU_SCRIPT, func(page:Control)->bool:
		failed_ref.append(weakref(page));
		return false;
	);
	expect(failed == null and router.current_page == initial and router.generation == generation, "setup返回false不替换或释放旧页面");
	await process_frame;
	expect(failed_ref[0].get_ref() == null, "准备失败的临时页面释放完成");
	var prepared:MainMenu = router.prepare(MENU, MENU_SCRIPT, func(page:Control)->bool:
		return page.is_node_ready() and not page.is_visible_in_tree() and not page.can_process();
	) as MainMenu;
	expect(prepared != null and router.current_page == initial and not router.is_current(prepared), "初始化期间输入仍受禁用且旧页持续有效");
	await process_frame;
	var accepted:Array[int] = [0];
	initial.start_requested.connect(func()->void:
		if router.is_current(initial):
			accepted[0] += 1;
	);
	prepared.start_requested.connect(func()->void:
		if router.is_current(prepared):
			accepted[0] += 1;
	);
	var contender:MainMenu = router.prepare(MENU, MENU_SCRIPT) as MainMenu;
	var incoming_lifecycle:Array[int] = [0, 0, 0];
	prepared.tree_entered.connect(func()->void: incoming_lifecycle[0] += 1);
	prepared.tree_exiting.connect(func()->void: incoming_lifecycle[1] += 1);
	prepared.ready.connect(func()->void: incoming_lifecycle[2] += 1);
	var exit_callbacks:Array[int] = [0];
	initial.tree_exiting.connect(func()->void:
		exit_callbacks[0] += 1;
		expect(not router.is_current(initial) and not router.is_current(prepared), "退出回调期间旧页与尚未提交完成的新页都不能报告操作");
		expect(router.current_page == prepared and router.generation == generation + 1, "退出回调触发前已更新当前页身份和代次");
		initial.start_requested.emit();
		expect(accepted[0] == 0, "旧页在tree_exiting中发送的迟到信号被拒绝");
		expect(not router.commit(prepared) and not router.commit(contender), "旧页退出回调不能重入提交同一页或另一个候选");
	);
	var old_ref:WeakRef = weakref(initial);
	expect(router.commit(prepared), "完整准备后可提交新页面");
	expect(exit_callbacks[0] == 1 and incoming_lifecycle == [0, 0, 0], "提交仅退出旧页一次，候选页不重新入树或重新ready");
	expect(contender.is_inside_tree() and not contender.is_visible_in_tree() and not contender.can_process(), "拒绝重入后其他候选继续保持准备状态");
	router.discard(contender);
	expect(router.generation == generation + 1 and commits.size() == 2 and commits[1]["previous"] == initial and commits[1]["current"] == prepared, "提交一次改变来源身份并通知旧新页面");
	expect(initial.is_queued_for_deletion() and not initial.is_inside_tree() and not router.is_current(initial) and router.is_current(prepared), "旧页立即失去来源资格并排队释放");
	initial.start_requested.emit();
	prepared.start_requested.emit();
	expect(accepted[0] == 1, "旧页面延迟信号被来源检查拒绝，仅新来源有效");
	expect(not router.commit(prepared) and router.generation == generation + 1, "相同页面不能二次提交");
	commits.clear();
	await process_frame;
	expect(old_ref.get_ref() == null, "提交后旧页在下一帧释放");
	var discarded:Control = router.prepare(MENU, MENU_SCRIPT);
	var discarded_ref:WeakRef = weakref(discarded);
	router.discard(discarded);
	expect(not router.commit(discarded) and router.is_current(prepared), "显式丢弃候选不影响当前页面且不可再提交");
	await process_frame;
	expect(discarded_ref.get_ref() == null, "丢弃页无残留");
	await _test_navigation_error(container);
	container.remove_child(prepared);
	expect(not router.is_current(prepared) and not prepared.is_queued_for_deletion(), "页面离开场景树后立即失去来源资格，不依赖排队释放");
	prepared.free();
	router.free();
	container.free();
	print("PageRouter检查完成，失败数：%d" % failures);
	quit(1 if failures else 0);

func _test_navigation_error(container:Control)->void:
	var view:Control = ERROR_SCENE.instantiate();
	container.add_child(view);
	await process_frame;
	var events:Array[String] = [];
	view.retry_requested.connect(func()->void: events.append("retry"));
	view.menu_requested.connect(func()->void: events.append("menu"));
	var retry:Button = view.get_node("center/panel/layout/retry_button");
	var menu:Button = view.get_node("center/panel/layout/menu_button");
	retry.pressed.emit();
	menu.pressed.emit();
	expect(events == ["retry", "menu"] and view.get_node("center/panel/layout/title").text == "界面暂时无法显示", "导航错误页只报告意图并显示固定文案");
	expect(view.get_node("shade").get_global_rect().size == container.size, "错误浮层遮罩覆盖整个页面容器");
	var panel:Control = view.get_node("center/panel");
	expect(container.get_global_rect().encloses(panel.get_global_rect()), "1024窗口错误页按钮和面板保持可见");
	view.free();
