## 冒险与战斗独立的随机流；规则调用明确传入，不依赖全局随机状态。
class_name RunRNG
extends RefCounted

## 初始化内容随机流时记录的种子，用于重现冒险。
var initial_seed:int
## 冒险内容的随机流，用于节点绑定、候选和奖励抽样。
var run:RandomNumberGenerator = RandomNumberGenerator.new();
## 从初始种子派生的战斗随机流，用于洗牌，与内容抽样分离。
var battle:RandomNumberGenerator = RandomNumberGenerator.new();

## 用指定种子初始化内容随机流，并派生独立战斗随机流；[code]-1[/code] 表示随机创建种子。
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

## 从 [code]0[/code] 到 [param count] 减一之间均匀抽取下标；调用者需保证数量为正。
##
## 未传入随机源时使用全局随机源。
static func pick_index(count:int, rng:RandomNumberGenerator = null)->int:
	return randi_range(0, count - 1) if rng == null else rng.randi_range(0, count - 1);
