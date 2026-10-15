## 冒险与战斗独立的随机流；规则调用明确传入，不依赖全局随机状态。
class_name RunRNG
extends RefCounted

var initial_seed:int
var run:RandomNumberGenerator = RandomNumberGenerator.new();
var battle:RandomNumberGenerator = RandomNumberGenerator.new();

func _init(seed_value:int = -1)->void:
	if seed_value == -1:
		run.randomize();
	else:
		run.seed = seed_value;
	initial_seed = run.seed;
	battle.seed = initial_seed ^ 0x5DEECE66D;

## 空参数仅供旧模型测试兼容；新生产入口始终传入随机流。
static func shuffle(values:Array, rng:RandomNumberGenerator = null)->void:
	if rng == null:
		values.shuffle();
		return;
	for index in range(values.size() - 1, 0, -1):
		var target:int = rng.randi_range(0, index);
		var item:Variant = values[index];
		values[index] = values[target];
		values[target] = item;

static func pick_index(count:int, rng:RandomNumberGenerator = null)->int:
	return randi_range(0, count - 1) if rng == null else rng.randi_range(0, count - 1);
