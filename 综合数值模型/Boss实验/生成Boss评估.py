"""核对Boss独立验证与正式资源，生成设计和量化记录。"""
from __future__ import annotations
import hashlib
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def check_hashes(hashes):
    for rel, expected in hashes.items():
        assert hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()==expected, f"来源过期：{rel}"


def main():
    import sys
    sys.path.insert(0, str(ROOT))
    from tools.history_guard import require_sandbox
    require_sandbox(ROOT)
    settings=read(HERE/"评估参数.json")
    raw=read(HERE/"验证数据.json")
    coarse=read(HERE/"生命对照数据.json")
    assert raw["settings"]==coarse["settings"]==settings
    assert raw["mode"]=="validation" and coarse["mode"]=="calibration"
    assert raw["failures"]==coarse["failures"]==0
    check_hashes(raw["source_hashes"])
    check_hashes(coarse["source_hashes"])
    model=read(ROOT/"敌人标准模型/评估数据.json")
    check_hashes(model["resource_hashes"])
    enemies={row["enemy"]["id"]:row for row in model["results"]}
    card_data=read(ROOT/"卡牌标准模型/评估数据.json")
    check_hashes(card_data["resource_hashes"])
    rarities={row["card"]["id"]:row["card"]["rarity"] for row in card_data["results"]}
    spec=importlib.util.spec_from_file_location("combined",HERE.parent/"生成综合评估.py")
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    expected_ids=[settings["reference_enemy"]]+settings["enemies"]
    expected_keys={(eid,label,50) for eid in expected_ids for label in settings["deck_labels"]}
    expected_keys|={(eid,"随机合法开局",35) for eid in expected_ids}
    assert {(r["enemy_id"],r["label"],r["player_health"]) for r in raw["results"]}==expected_keys
    assert len(raw["results"])==len(expected_keys)==12
    basic=["strike"]*3+["defend"]*3
    summaries=[]
    for condition in raw["results"]:
        eid=condition["enemy_id"]
        rows=condition["outcomes"]
        assert len(rows)==condition["samples"]==settings["validation_samples"]
        assert condition["health"]==enemies[eid]["enemy"]["health"]
        start=settings["validation_seed_start"]+(10000 if condition["player_health"]==35 else 0)
        assert start>=settings["training_seed_start"]+settings["coarse_samples"]
        for index,row in enumerate(rows):
            assert row["seed"]==start+index
            assert row["enemy_id"]==eid and row["enemy_initial_health"]==condition["health"]
            assert row["player_initial_health"]==condition["player_health"]
            assert row["player_initial_max_health"]==50
            assert row["hp_deductions"]-row["positive_health_recovery"]==row["net_health_loss"]
            assert row["player_initial_max_health"]-row["remaining_max_health"]==row["max_health_loss"]
            assert 0<=row["remaining_health"]<=row["remaining_max_health"]
            assert row["victory"]==(row["remaining_enemy_health"]==0 and row["remaining_health"]>0)
            assert row["outcome"] in ("胜利","失败")
            assert row["deck"][:6]==basic
            if condition["label"]=="基础6张":
                assert row["deck"]==basic
            elif condition["label"]=="参考9张":
                assert row["deck"]==basic+settings["reference_deck"]
            else:
                assert len(row["deck"])==9
                assert [rarities[card] for card in row["deck"][6:]]==[3,2,1]
        for example in condition["examples"]:
            assert len(example["trace"])==example["turns"]
            assert example["trace"][0]["start_health"]==condition["player_health"]
            assert example["trace"][-1]["end_health"]==example["remaining_health"]
        summary=module.summary(rows)
        assert summary["wins"]==condition["wins"] and summary["win_rate"]==condition["win_rate"]
        summaries.append({"enemy_id":eid,"name":enemies[eid]["enemy"]["name"],"health":condition["health"],"label":condition["label"],"player_health":condition["player_health"],**summary})
    for eid in settings["enemies"]:
        profile=enemies[eid]
        assert profile["enemy"]["role"]=="Boss"
        assert profile["design_check"]["opening_matches"] and profile["design_check"]["peak_within_limit"]
        assert not profile["grows_each_cycle"]
    snapshot={"date":settings["evaluation_date"],"settings":settings,"sample_count":sum(r["n"] for r in summaries),"results":summaries,
              "models":{eid:{k:enemies[eid][k] for k in ("opening_value","opening_pressure_value","cycle_average","peak_action_value","peak_pressure_value","design_check")} for eid in settings["enemies"]},
              "source_hashes":raw["source_hashes"],"input_hashes":{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (HERE/"评估参数.json",HERE/"生命对照数据.json",HERE/"验证数据.json",ROOT/"敌人标准模型/评估数据.json")}}
    (HERE/"Boss评估数据.json").write_text(json.dumps(snapshot,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    lines=["# 两种Boss设计与量化评估","",f"日期：{settings['evaluation_date']}。评估包含铁冠暴君、灾厄祭司两种Boss，并以遗迹守卫为对照，共三种。两种新增Boss已经配置为正式敌人／遭遇资源，独立试炼可玩；默认分支地图从这三种Boss中开局随机选一并保存，新Boss美术为旧素材占位。","",
           "## 设计基准","","Boss首行动约1.3 E、允许最高2.6 E；每行动实际伤害/12＋新增格挡/10。力量、易伤与逐段取整按正式规则计入，减益防御潜力另报。普通敌人100血偏好与基础六牌约80%目标不套用到Boss；实验使用三轮开局构筑后的九牌评估，并与99血遗迹守卫对照。","",
           "## 铁冠暴君：攻守切换与三连斩","","最大生命 **110**，四步固定循环：","",
           "| 回合位置 | 实际行动 | 直接E |","| --- | --- | ---: |",
           "| 1 | 8伤＋6格挡 | 1.267 |","| 2 | 7伤×3＝21伤 | 1.750 |","| 3 | 12伤＋3格挡 | 1.300 |","| 4 | 13格挡 | 1.300 |","",
           "前三轮连续施压，第二轮为伤害高峰，第四轮只防守。玩家可用虚弱压低三连斩，以格挡减小失血，在防守轮输出。三段攻击逐段计算力量、虚弱、易伤并取整，普通累计格挡依次抵伤；三段本身不会额外穿盾。","",
           "第四玩家回合仍面对第三行动留下的3格挡，第四敌人行动新生成的13格挡保护第五玩家回合；首个玩家回合没有预先加盾。固定循环没有隐藏成长，直接峰值1.75 E。","",
           "## 灾厄祭司：减益铺垫与连续咒击","","最大生命 **100**，四步固定循环：","",
           "| 回合位置 | 有序效果 | 实际攻击 | 直接E |","| --- | --- | ---: | ---: |",
           "| 1 | 虚弱1 → 8基础伤 → 6格挡 | 8 | 1.267 |",
           "| 2 | 易伤1 → 10基础伤 | 15 | 1.250 |",
           "| 3 | 12基础伤 → 6格挡 | 18 | 2.100 |",
           "| 4 | 13格挡 | 0 | 1.300 |","",
           "真实攻击按8→15→18→0重复。敌人施加的1回合状态在首次施加轮跳过递减：虚弱只影响第二玩家回合，基础打击6→4，第二敌人行动后消退；易伤先上，立即把当次10伤变15，并延续至第三敌人攻击，将12伤变18，随后消退。不会跨循环累计。","",
           "玩家在第一轮提前铺防守或准备能力，应覆盖第二、第三轮连续伤害；第四轮是反击窗口，但仍有上轮6格挡。第一行动参考压力另计下一均衡玩家回合因虚弱少造成4伤的0.4 E，得到1.667 E；整体参考压力峰值2.1 E，仍低于2.6。","",
           "## 独立验证","",f"冻结正式资源后，以{settings['validation_seed_start']}开始、每条件{settings['validation_samples']}个独立种子，使用正式战斗控制器和原有意图贪心策略。3种Boss×满血3牌组＋35/50生命随机开局，共{snapshot['sample_count']}场；验证种子未参与选择血量。","",
           "| Boss | 牌组 | 起始血量 | 胜利/样本 | 胜率 | 95%区间 | 平均余血 | 平均玩家回合 |",
           "| --- | --- | --- | ---: | ---: | --- | ---: | ---: |"]
    for row in summaries:
        interval="～".join(f"{v*100:.1f}%" for v in row["wilson_95"])
        lines.append(f"| {row['name']} | {row['label']} | {row['player_health']}/50 | {row['wins']}/{row['n']} | {row['win_rate']*100:.1f}% | {interval} | {row['remaining_health']:.2f} | {row['turns']:.2f} |")
    lines += ["","基础六牌为3打击＋3防御；参考九牌另加永恒、战神祝福、上勾拳；随机合法开局按传说→史诗→稀有三轮正式候选抽取，并固定取第一候选。玩家满血条件50/50，伤后条件35/50，每回合3能量、5抽、手牌上限10。平均余血包含失败的0血，回合包含致死或致胜末轮。","",
              "基础六牌对两种新Boss胜率很低，表明当前Boss依赖开局构筑，不能把随机九牌的约80%写成基础六牌约80%。参考构筑拥有较强武器配合，其样本全胜也不代表所有九牌构筑都能赢。35血入场时胜率明显下降，应结合路线失血与休整继续试玩；该实验不包含奖励、藏品或完整地图路线结算。","",
              "## 血量对照与选择","",f"训练种子从{settings['training_seed_start']}开始，每个生命／牌组条件{settings['coarse_samples']}场，仅改复制资源血量。初版更高攻击与盾量的循环在普通九牌下过难，降低部分持续压力后重新评估，定稿选择110／100血，保留两种不同机制。没有根据独立验证结果回调参数。","",
              "| Boss | 候选血量 | 基础六牌胜率 | 参考九牌胜率 | 随机开局九牌胜率 |","| --- | ---: | ---: | ---: | ---: |"]
    lookup={(r["enemy_id"],r["health"],r["label"]):r for r in coarse["results"]}
    for eid in settings["enemies"]:
        for hp in settings["health_candidates"]:
            rates=[f"{lookup[eid,hp,label]['win_rate']*100:.1f}%" for label in settings["deck_labels"]]
            lines.append(f"| {enemies[eid]['enemy']['name']} | {hp} | {' | '.join(rates)} |")
    lines += ["","## 试玩与复算","",
              "在Godot打开[Boss试炼](./Boss试炼.tscn)按F6：选择基础牌、参考构筑或随机合法开局；选择50/50或35/50生命，再点击Boss。选择菜单包含两名新增Boss与遗迹守卫对照，返回重开会重新创建单场状态。","",
              "[完整运行说明](./README.md)、[评估参数](./评估参数.json)、[生命对照](./生命对照数据.json)、[独立验证](./验证数据.json)、[量化汇总](./Boss评估数据.json)、[生成工具](./生成Boss评估.py)。敌人逐行动预算与固定参考打法见[敌人标准模型](../../敌人标准模型/当前敌人量化评估.md)。","",
              "## 检查记录","",
              "相关[Boss机制测试](../../tests/new_boss_mechanics_test.gd)与[Boss试炼入口测试](../../tests/new_boss_trial_test.gd)。检查真实意图、减益递减、逐段取整、旧盾清空、资源不被污染，以及3种牌组×2种入场生命×3种Boss的18场入口与重开隔离。","",
              "3072场Boss独立验证与3000场普通敌人复算分别保存来源核对和生命账目；完整随机分支路线的额外奖励与15血休整结果见[综合路线报告](../综合量化评估.md)，本表仍为无跨场奖励、休整和藏品的单场条件。单场实验结果需与实际整局试玩分别观察。","",
              "自动策略不预知抽牌、不搜索完整回合最优顺序、不主动换装、不优化开局选牌，统计只代表上述条件，不能保证人类玩家胜率。来源SHA-256、逐样本牌组、生命账目与示例轨迹保留供审查。",""]
    (HERE/"两种Boss设计.md").write_text("\n".join(lines),encoding="utf-8")
    print(f"Boss设计核对完成：{snapshot['sample_count']}场、12条件；来源、生命账目、首行动及峰值通过。")


if __name__=="__main__":
    main()
