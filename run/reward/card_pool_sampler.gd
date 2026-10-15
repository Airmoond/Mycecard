## 按稀有度筛选并无放回抽取卡牌；只操作新数组，不修改角色卡池或卡牌定义。
## 输入卡池已由CharacterDefinition验证为合法且card_id唯一，count由调用方保证为正数。
class_name CardPoolSampler
extends RefCounted

## 普通奖励按卡牌等概率抽取，不先随机选择稀有度。
const REWARD_RARITIES:Array[int] = [
	CardDefinition.CardRarity.COMMON,
	CardDefinition.CardRarity.RARE,
	CardDefinition.CardRarity.EPIC
];


## 配置容量检查与实际抽取使用同一套筛选规则。
static func filter_pool(pool:Array[CardDefinition], allowed_rarities:Array[int])->Array[CardDefinition]:
	var candidates:Array[CardDefinition] = [];
	for card in pool:
		if card.rarity in allowed_rarities:
			candidates.append(card);
	return candidates;


## 开局分组传入单一稀有度，普通奖励传入REWARD_RARITIES。
## 数量不足返回空数组并报告配置错误，不补重复卡、不返回不完整候选。
static func sample(pool:Array[CardDefinition], count:int, allowed_rarities:Array[int], rng:RandomNumberGenerator = null)->Array[CardDefinition]:
	var candidates:Array[CardDefinition] = filter_pool(pool, allowed_rarities);
	if candidates.size() < count:
		push_error("筛选后的卡池不足：需要%d张，只有%d张" % [count, candidates.size()]);
		return [];
	RunRNG.shuffle(candidates, rng);
	candidates.resize(count);
	return candidates;
