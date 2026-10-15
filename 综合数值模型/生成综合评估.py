"""汇总真实Godot战斗样本与两个标准模型；不修改游戏资源。"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import math
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from statistics import mean

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def verify_hashes(hashes):
    for rel, expected in hashes.items():
        if hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() != expected:
            raise ValueError(f"数据与当前来源不一致，请重跑相应评估：{rel}")


def percent(value):
    return f"{value * 100:.1f}%"


def summary(rows):
    if not rows:
        raise ValueError("样本组为空")
    n = len(rows)
    wins = sum(bool(row["victory"]) for row in rows)
    p = wins / n
    z = 1.96
    divisor = 1 + z*z/n
    center = (p + z*z/(2*n)) / divisor
    width = z * math.sqrt(p*(1-p)/n + z*z/(4*n*n)) / divisor
    return {"n": n, "wins": wins, "win_rate": p, "wilson_95": [max(0,center-width), min(1,center+width)],
            "remaining_health": mean(row["remaining_health"] for row in rows),
            "remaining_fraction": mean(row["remaining_health"]/row["player_initial_max_health"] for row in rows),
            "net_health_loss": mean(row["net_health_loss"] for row in rows),
            "max_health_loss": mean(row["max_health_loss"] for row in rows),
            "turns": mean(row["turns"] for row in rows),
            "enemy_remaining_health": mean(row["remaining_enemy_health"] for row in rows)}


def check(raw):
    params = read(HERE / "评估参数.json")
    if raw["parameters"] != params:
        raise ValueError("战斗样本参数过期")
    verify_hashes(raw["source_hashes"])
    assert raw["failures"] == 0 and raw["battle_count"] == len(raw["battles"])
    samples = params["samples"]
    assert len(raw["routes"]) == samples*2
    for row in raw["battles"]:
        assert row["collection_id"] == "none", "主基准不能混入藏品条件"
        assert row["hp_deductions"] - row["positive_health_recovery"] == row["net_health_loss"]
        assert row["max_health_loss"] == row["player_initial_max_health"] - row["remaining_max_health"]
        assert 0 <= row["remaining_health"] <= row["remaining_max_health"]
        assert row["remaining_enemy_health"] >= 0 and row["outcome"] != "窗口耗尽"
        assert len(row["trace"]) == row["turns"]
        assert row["trace"][0]["start_health"] == row["player_initial_health"]
        assert row["trace"][-1]["end_health"] == row["remaining_health"]
        assert row["victory"] == (row["remaining_enemy_health"] == 0 and row["remaining_health"] > 0)
    for route in raw["routes"]:
        fights = route["battles"]
        normals = route["normal_battles"]
        assert normals in (1, params["proposed_route_battles"])
        assert len(route["starting_deck"]) == 9
        assert len(route["normal_enemy_ids"]) == normals
        assert 0 <= route["rest_healing"] <= route["rest_config_heal"]
        if normals == 1:
            assert route["scenario"] == "historical_reference"
            assert route["normal_enemy_ids"] == ["cave_crawler"] and route["boss_enemy_id"] == "ruin_guard"
        else:
            assert route["scenario"] == "branch_map" and route["route_id"] in ("a", "b", "c")
            assert route["collection_id"] == "none" and route["collection_healing"] == 0
            assert len(set(route["normal_enemy_ids"])) == 2
            assert len(route["node_ids"]) == 5
            assert route["node_ids"] == ["start", f"route_{route['route_id']}_1", f"route_{route['route_id']}_2", f"route_{route['route_id']}_rest", "final_boss"]
            assert route["completed_node_ids"] == route["node_ids"][:len(route["completed_node_ids"])]
        expected_enemies = route["normal_enemy_ids"] + [route["boss_enemy_id"]]
        assert [fight["enemy_id"] for fight in fights] == expected_enemies[:len(fights)]
        assert route["boss_reached"] == (len(fights) == normals+1)
        assert route["victory"] == (route["boss_reached"] and all(b["victory"] for b in fights))
        assert route["remaining_health"] == fights[-1]["remaining_health"]
        assert route["remaining_max_health"] == fights[-1]["remaining_max_health"]
        assert len(route["reward_cards"]) == sum(b["victory"] for b in fights[:normals])
        assert fights[0]["deck"] == route["starting_deck"]
        if route["boss_reached"]:
            assert route["rest_healing"] == min(route["rest_config_heal"], fights[normals-1]["remaining_max_health"]-fights[normals-1]["remaining_health"])
            assert route["boss_entry_health"] == fights[-1]["player_initial_health"]
        else:
            assert route["rest_healing"] == route["boss_entry_health"] == 0
        for i, fight in enumerate(fights[1:],1):
            previous = fights[i-1]
            heal = route["rest_healing"] if i == normals else 0
            assert fight["player_initial_health"] == previous["remaining_health"] + heal
            assert fight["player_initial_max_health"] == previous["remaining_max_health"]
            assert fight["deck"] == route["starting_deck"] + route["reward_cards"][:i]
    for count in (1, params["proposed_route_battles"]):
        rows = [r for r in raw["routes"] if r["normal_battles"] == count]
        assert len(rows) == samples
        assert [r["seed"] for r in rows] == list(range(params["seed_start"], params["seed_start"]+samples))
    current = [r for r in raw["routes"] if r["scenario"] == "branch_map"]
    assert [r["route_id"] for r in current] == [("a", "b", "c")[i % 3] for i in range(samples)]
    return params


def main():
    import sys
    sys.path.insert(0, str(ROOT))
    from tools.history_guard import require_sandbox
    require_sandbox(ROOT)
    raw = read(HERE / "原始战斗数据.json")
    params = check(raw)
    card_data = read(ROOT / "卡牌标准模型/评估数据.json")
    enemy_data = read(ROOT / "敌人标准模型/评估数据.json")
    for data in (card_data, enemy_data):
        verify_hashes(data["resource_hashes"])
    for folder, data in (("卡牌标准模型",card_data),("敌人标准模型",enemy_data)):
        assert data["parameters"] == read(ROOT/folder/"模型参数.json"), "标准模型参数过期"
    weights = params["score_components"]
    assert weights["victory_weight"] + weights["remaining_health_weight"] == 100
    groups = defaultdict(list)
    for row in raw["battles"]:
        # 连续路线的入场生命与牌组不同，按路线单独汇总，不混进独立条件。
        if row["group"] == "route":
            continue
        if row["group"] == "sensitivity":
            key = ("sensitivity",row["label"],row["player_initial_max_health"],row["enemy_initial_health"])
        else:
            key = (row["group"],row["label"],row["enemy_id"])
        groups[key].append(row)
    summaries = []
    for key, rows in groups.items():
        assert len(rows) == params["samples"], "独立条件样本数不匹配"
        item = summary(rows)
        item["key"] = list(key)
        item["composite_score"] = weights["victory_weight"]*item["win_rate"] + weights["remaining_health_weight"]*item["remaining_fraction"]
        summaries.append(item)
    lookup = {tuple(row["key"]):row for row in summaries}
    card_rows = []
    for item in card_data["results"]:
        card = item["card"]
        entry = {"id":card["id"],"name":card["name"],"cost":card["cost"],"standard_value":item["scenarios"]["standard"]["value"],"contexts":{}}
        for enemy in ("cave_crawler","ruin_guard"):
            key = ("card",card["id"],enemy)
            sample = lookup[key]
            baseline = lookup[("baseline","基础6张",enemy)]
            assert sample["n"] == params["samples"]
            entry["contexts"][enemy] = {**sample, "health_delta":sample["remaining_health"]-baseline["remaining_health"],
                                       "win_rate_delta":sample["win_rate"]-baseline["win_rate"],
                                       "score_delta":sample["composite_score"]-baseline["composite_score"],
                                       "play_rate":mean(row["played"].get(card["id"],0)>0 for row in groups[key])}
        card_rows.append(entry)
    # 无限生命仅用于固定基础预算的理论最低生命需求；不是玩家属性修改。
    spec = importlib.util.spec_from_file_location("enemy_model",ROOT/"敌人标准模型/重新评估.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.PARAMS["initial_player_health"] = 1000000
    theoretical = []
    for enemy in enemy_data["results"]:
        for profile in enemy_data["parameters"]["player_profiles"]:
            trace = module.trace(enemy["enemy"],profile)
            assert trace["outcome"] == "玩家胜利", "理论窗口不足，应延长评估窗口"
            theoretical.append({"enemy":enemy["enemy"]["name"],"profile":profile["name"],
                                "turns":trace["player_rounds"],"enemy_turns":trace["successful_enemy_turns"],
                                "required_starting_health":trace["player_health_loss"]+1})
    routes = []
    for count in (1,params["proposed_route_battles"]):
        rows = [r for r in raw["routes"] if r["normal_battles"] == count]
        reached = [r for r in rows if r["boss_reached"]]
        routes.append({"normal_battles":count,"n":len(rows),"wins":sum(r["victory"] for r in rows),
                       "scenario":rows[0]["scenario"],
                       "route_counts":{route_id:sum(r["route_id"]==route_id for r in rows) for route_id in sorted({r["route_id"] for r in rows})},
                       "normal_selection_counts":{enemy_id:sum(r["normal_enemy_ids"].count(enemy_id) for r in rows) for enemy_id in sorted({eid for r in rows for eid in r["normal_enemy_ids"]})},
                       "boss_selection_counts":{enemy_id:sum(r["boss_enemy_id"]==enemy_id for r in rows) for enemy_id in sorted({r["boss_enemy_id"] for r in rows})},
                       "win_rate":mean(r["victory"] for r in rows),"boss_reached":len(reached),
                       "mean_boss_entry_health":mean(r["boss_entry_health"] for r in reached) if reached else 0,
                       "mean_remaining_health":mean(r["remaining_health"] for r in rows),
                       "mean_rest_healing":mean(r["rest_healing"] for r in rows),
                       "mean_max_health_loss":mean(r["battles"][0]["player_initial_max_health"]-r["remaining_max_health"] for r in rows)})
    snapshot = {"model_version":params["model_version"],"date":params["evaluation_date"],"parameters":params,
                "battle_count":raw["battle_count"],"sources":raw["source_hashes"],
                "input_hashes":{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (HERE/"评估参数.json",ROOT/"卡牌标准模型/评估数据.json",ROOT/"敌人标准模型/评估数据.json")},"groups":summaries,
                "cards":card_rows,"routes":routes,"theoretical_health_requirements":theoretical}
    (HERE/"综合评估数据.json").write_text(json.dumps(snapshot,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    config=[]
    for enemy in enemy_data['results']:
        definition=enemy['enemy']
        sequence=[]
        for action in definition['actions']:
            effects=[]
            for effect in action['effects']:
                amount=effect['amount']*effect['repeat_count']
                label={0:"基础伤",1:"格挡",6:"力量",7:"回合虚弱",8:"回合易伤"}[effect['effect_type']]
                effects.append(f"{amount}{label}")
            sequence.append('＋'.join(effects))
        config.append(f"{definition['name']}{definition['health']}血、"+'→'.join(sequence))
    lines = ["# 综合量化评估报告","",f"日期：{params['evaluation_date']}。模型v{params['model_version']}。真实Godot结算{raw['battle_count']}场，另含{len(raw['routes'])}条连续遭遇记录；每个独立条件{params['samples']}个固定种子。","",
             "当前配置："+'；'.join(config)+"。玩家基础生命、每回合能量与抽牌规则从资源加载；该实验玩家50血、3能量、5抽牌。","",
             f"独立单场基准、单卡增量与生命扫描仍只覆盖哥布林战士、遗迹守卫两种原有敌人；当前分支路线使用正式随机普通敌人与Boss池。新增三种普通敌人的独立基础牌组验证另见[新敌人设计评估](./新敌人实验/三种普通敌人设计.md)，两种新增Boss的构筑与伤后入场对照见[Boss设计评估](./Boss实验/两种Boss设计.md)。下方理论基础预算表覆盖全部{enemy_data['enemy_count']}种资源，明确区分基础攻击数字与力量、易伤修正后的实际伤害。","",
             "## 1. 牌组与敌人共同决定压力","",
             "| 牌组 | 敌人 | 胜利 / 样本 | 样本胜率 | 95%区间 | 平均剩余血 | 平均净失血 | 平均回合 | 综合分 |",
             "| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |"]
    for group,label in (("baseline","基础6张"),("reference","参考9张"),("draft","随机合法开局")):
        for enemy,name in (("cave_crawler","哥布林战士"),("ruin_guard","遗迹守卫")):
            s=lookup[(group,label,enemy)]
            interval="～".join(percent(v) for v in s["wilson_95"])
            lines.append(f"| {label} | {name} | {s['wins']} / {s['n']} | {percent(s['win_rate'])} | {interval} | {s['remaining_health']:.2f} | {s['net_health_loss']:.2f} | {s['turns']:.2f} | {s['composite_score']:.2f} |")
    lines += ["","基础牌组为角色资源中的3打击＋3防御。参考9张为基础6张＋"+params["reference_deck_name"]+"，符合传说、史诗、稀有各一张的开局规则；它是一种配合示例，不代表随机开局必得。随机合法开局按正式三轮候选抽取，固定选每轮第一张。","",
              "平均值包括失败样本，失败剩余生命为0；回合数包含致死或致胜的末轮。综合分Q=70×样本胜率＋30×平均剩余生命占起始最大生命比例，仅用于同条件比较。权重是暂定偏好，不是难度定律；失败时剩余Boss血量在JSON中另列。","",
              "## 2. 不同生命组合的敏感性","",
              "行是玩家起始及最大生命，列是Boss最大生命；其他规则相同。每格为样本胜率／平均结算余血，平均包含失败的0血。只修改模拟副本，不修改正式玩家数值。",""]
    for deck_label in ("基础6张","参考9张"):
        lines += ["### "+deck_label,"","| 玩家血量 / Boss血量 | "+" | ".join(map(str,params["boss_health_grid"]))+" |",
                  "| --- | "+" | ".join("---:" for _ in params["boss_health_grid"])+" |"]
        for hp in params["player_health_grid"]:
            cells=[]
            for ehp in params["boss_health_grid"]:
                cell=lookup[("sensitivity",deck_label,hp,ehp)]
                cells.append(f"{percent(cell['win_rate'])} / {cell['remaining_health']:.1f}")
            lines.append("| "+str(hp)+" | "+" | ".join(cells)+" |")
        lines.append("")
    lines += ["","图示见[血量对照](./血量对照.png)，颜色表示平均余血比例；图由独立绘图工具从综合数据生成。各格的剩余生命、回合数、净失血、综合分与区间均保存在[综合数据](./综合评估数据.json)。一次增加生命既改变容错，也可能改变策略的防守倾向；不能据此推出全牌组通用的生命倍率。","",
              "## 3. 历史参照与当前随机分支路线","",
              "| 连续路线 | 胜利 / 样本 | 胜率 | 到达Boss | 平均Boss入场血 | 平均实际休整回血 | 平均结算血 | 平均上限损失 |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for route in routes:
        label="历史参照：哥布林→休整→遗迹守卫" if route["normal_battles"]==1 else "当前：随机普通→随机普通→休整→随机Boss"
        lines.append(f"| {label} | {route['wins']} / {route['n']} | {percent(route['win_rate'])} | {route['boss_reached']} | {route['mean_boss_entry_health']:.2f} | {route['mean_rest_healing']:.2f} | {route['mean_remaining_health']:.2f} | {route['mean_max_health_loss']:.2f} |")
    current_route = next(route for route in routes if route["scenario"] == "branch_map")
    branch_distribution = "、".join(f"{key}支线{value}局" for key,value in current_route["route_counts"].items())
    names = {row["enemy"]["id"]:row["enemy"]["name"] for row in enemy_data["results"]}
    boss_distribution = "、".join(f"{names[key]}{value}局" for key,value in current_route["boss_selection_counts"].items())
    lines += ["","两组均使用随机合法开局；历史参照固定一场哥布林与遗迹守卫，保留用于比较拓扑变化。实验路线通过RunState初始化冻结地图，开局一次绑定每条支线的两种不同普通敌人与最终Boss；跨支线可重复，本局中不重抽。评估在a、b、c间轮换："+branch_distribution+"；随机Boss分布："+boss_distribution+"。路线选择不根据敌人或构筑优化。","",
              "实验路线以RunState保存牌组、当前及最大生命，完成开始节点后进入选定支线，两场普通胜利各按正式非传说池抽三选一并选第一张；奖励在完成对应节点前加入牌组。满程Boss牌组为9＋2＝11张。单场结算使用该节点开局绑定的正式遭遇，能力与武器状态按新战斗重置；只经过本支线的一次15血休整，恢复被实际上限截断，其他支线的休整不会相加。失败立即结束，不再发奖励或解锁后续节点。本报告使用冻结实验冒险并清空藏品池，显式维持无藏品的对照口径；正式开始节点三选一及三件藏品的真实路线配对另见[藏品实测报告](./藏品实验/三件藏品实测评估.md)。","",
              "## 4. 基础行动预算需要多少生命","",
              "为消除死亡造成的失血截断，另将三种固定基础预算持续到击杀敌人为止。没有抽牌、治疗、能力或额外牌，最低起始生命=所有敌人行动造成的累计失血＋1。","",
              "| 敌人 | 每轮方案 | 玩家回合 | 敌人出手 | 理论最低起始血 |",
              "| --- | --- | ---: | ---: | ---: |"]
    for row in theoretical:
        lines.append(f"| {row['enemy']} | {row['profile']} | {row['turns']} | {row['enemy_turns']} | {row['required_starting_health']} |")
    lines += ["","这些需求假定每轮必有对应基础牌组合，与上面的真实抽牌贪心策略不同。固定防守或固定进攻可能失败，而按意图在Boss防守轮进攻、攻击轮格挡的策略可能胜利。因此不能用某一固定方案宣布某种敌人不可打。","",
              "## 5. 全卡牌加入效果","",
              "在基础6张上加入表中一张卡，形成7张实验牌组；比较相同24个随机种子下的平均剩余生命与胜率。所有29张都覆盖，包括再加入一张基础打击／防御。此处是单卡作用诊断，7张牌不是正式开局；稀有度不参与效果倍率。","",
              f"| 卡牌 | 费用 | 标准局面U | 普通战平均剩余血增量 | Boss胜利 / {params['samples']} | Boss胜率增量 | Boss平均剩余血增量 | Boss实际打出样本率 |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in card_rows:
        normal=row["contexts"]["cave_crawler"]; boss=row["contexts"]["ruin_guard"]
        value=Decimal(str(row['standard_value'])).quantize(Decimal('0.01'),rounding=ROUND_HALF_UP)
        lines.append(f"| {row['name']} | {row['cost']} | {value} | {normal['health_delta']:+.2f} | {boss['wins']} / {boss['n']} | {boss['win_rate_delta']*100:+.1f}个百分点 | {boss['health_delta']:+.2f} | {percent(boss['play_rate'])} |")
    lines += ["","U来自独立卡牌模型的标准局面：1 U=6伤或5格挡。该局面只是假设条件，原先40血敌人参数不代表当前99血Boss；本表右侧的战斗结果按实际99血结算。","",
              "战神祝福单独加入无武器牌组时不能使用，不能因此认定它无价值；参考构筑提供了武器配合。坚城、盾牌猛击、力量与多段等同样依赖环境。单卡加入还会改变抽牌密度，负增量既可能来自费用、条件或稀释，也可能来自策略与有限样本；不可直接据此削弱或增强卡牌。","",
              "## 6. 策略与可信范围","",
              "策略每步只看当前手牌、能量、双方状态和可见意图：优先致死；按可兑现伤害、足够抵御当前意图的格挡、短期抽牌／能量／力量／武器收益贪心选牌；低血提高防守权重。遇到新效果明确报错，不静默忽略。全部出牌、武器、状态、多段、消耗、固有、保留、禁抽、回血和上限损失均由正式控制器结算。评估控制器只关闭UI刷新。","",
              "它不搜索完整回合的最优出牌顺序、不看隐藏抽牌顺序、不主动替换已装备武器、不做聪明的奖励选择。本报告独立基准维持无藏品，已接入三件藏品的路线结果在单独报告中比较；后续新增效果需重新建模。24种子结果及区间只能描述此策略与抽样条件，100%样本胜率不代表玩家必胜。","",
              "结论：当前99血Boss把战斗长度与构筑兑现放大；应同时观察峰值、实际击杀回合、余血、失败时Boss余血以及跨战生命预算。先试玩，再决定是否调整生命、盾量或攻击间隔，不把允许上限当作每轮必须达到的强度。","",
              "## 7. 复算与来源","",
              "见[模型规则](./综合模型.md)与[运行说明](./README.md)。原始逐轮记录在[战斗数据](./原始战斗数据.json)，汇总在[综合数据](./综合评估数据.json)。模型保存来源SHA-256，资源或参数变化后拒绝用旧样本生成新结论。",""]
    (HERE/"综合量化评估.md").write_text("\n".join(lines),encoding="utf-8")
    print(f"综合评估完成：{raw['battle_count']}场，{len(card_rows)}张卡，{len(raw['routes'])}条连续遭遇；来源与生命账目已核对。")


if __name__ == "__main__":
    main()
