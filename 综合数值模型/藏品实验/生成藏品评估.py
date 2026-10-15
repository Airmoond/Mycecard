"""核对四组真实路线配对、生命账目及当前资源，生成藏品效果报告。"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import math
from collections import Counter
from pathlib import Path
from statistics import mean

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE_FOLDERS = ("battle", "cards", "combatants", "characters", "run", "collections", "综合数值模型")


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_sources(hashes):
    expected = {
        path.relative_to(ROOT).as_posix()
        for folder in SOURCE_FOLDERS
        for path in (ROOT / folder).rglob("*")
        if path.is_file() and path.suffix in (".gd", ".tres")
    }
    expected.update({"tests/fixtures/phase5_run.tres", "tests/fixtures/phase5_map.tres", "tools/history_guard.gd"})
    assert set(hashes) == expected, "来源清单不完整或新增了未复算的规则／资源"
    for rel, digest in hashes.items():
        assert hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() == digest, f"来源过期：{rel}"


def configuration():
    """读取资源本身，避免将报告中的初值当作当前游戏配置。"""
    parser = load_module("collection_resource_parser", ROOT / "敌人标准模型/重新评估.py")
    run, _, run_ext = parser.resource(ROOT / "tests/fixtures/phase5_run.tres")
    character, char_sub, char_ext = parser.resource(parser.external_path(run["character_definition"], run_ext))
    player = parser.resolve(character["combatant_definition"], char_sub, char_ext)
    basic = []
    for ref in parser.refs(character["starting_deck_entries"]):
        entry = parser.resolve(ref, char_sub, char_ext)
        card = parser.resolve(entry["card_definition"], char_sub, char_ext)
        basic += [card["card_id"]] * entry["count"]
    reward_cards = {}
    for ref in parser.refs(character["reward_card_pool"]):
        card = parser.resolve(ref, char_sub, char_ext)
        reward_cards[card["card_id"]] = card
    collections = {}
    for ref in parser.refs(run["collection_pool"]):
        collection = parser.resolve(ref, {}, run_ext)
        cid = collection["collection_id"]
        collections[cid] = {
            "id": cid,
            "name": collection["display_name"],
            "description": collection["description"],
            "effect_type": collection.get("effect_type", 0),
            "amount": collection.get("amount", 1),
            "turn_limit": collection.get("turn_limit", 0),
        }
    enemies = {}
    pools = {}
    for pool in ("normal_encounter_pool", "boss_encounter_pool"):
        pools[pool] = []
        for ref in parser.refs(run[pool]):
            encounter, _, encounter_ext = parser.resource(parser.external_path(ref, run_ext))
            enemy, _, _ = parser.resource(parser.external_path(encounter["enemy_definition"], encounter_ext))
            eid = enemy["combatant_id"]
            enemies[eid] = {"id": eid, "name": enemy["display_name"], "health": enemy["max_health"]}
            pools[pool].append(eid)
    map_resource, map_sub, map_ext = parser.resource(parser.external_path(run["map_definition"], run_ext))
    nodes = {node["node_id"]: node for ref in parser.refs(map_resource["nodes"]) for node in [parser.resolve(ref, map_sub, map_ext)]}
    return {"player_health": player["max_health"], "basic": basic, "reward_cards": reward_cards,
            "collections": collections, "enemies": enemies, "pools": pools, "nodes": nodes,
            "reward_selection_count": run.get("reward_selection_count", 3),
            "collection_option_count": run.get("collection_option_count", 3)}


def check_battle(row, config, collection_id):
    assert row["collection_id"] == collection_id
    assert row["enemy_initial_health"] == config["enemies"][row["enemy_id"]]["health"]
    assert row["hp_deductions"] - row["positive_health_recovery"] == row["net_health_loss"]
    assert row["max_health_loss"] == row["player_initial_max_health"] - row["remaining_max_health"]
    assert 0 <= row["remaining_health"] <= row["remaining_max_health"] <= row["player_initial_max_health"]
    assert row["remaining_enemy_health"] >= 0 and row["outcome"] in ("胜利", "失败")
    assert row["victory"] == (row["remaining_enemy_health"] == 0 and row["remaining_health"] > 0)
    assert (row["outcome"] == "胜利") == row["victory"]
    trace = row["trace"]
    assert len(trace) == row["turns"] > 0
    assert trace[0]["start_health"] == row["player_initial_health"]
    assert trace[0]["start_enemy_health"] == row["enemy_initial_health"]
    assert trace[-1]["end_health"] == row["remaining_health"]
    assert trace[-1]["end_max_health"] == row["remaining_max_health"]
    assert trace[-1]["end_enemy_health"] == row["remaining_enemy_health"]
    for index, turn in enumerate(trace):
        assert turn["turn"] == index + 1
        assert 0 <= turn["end_health"] <= turn["end_max_health"]
        if index:
            assert turn["start_health"] == trace[index - 1]["end_health"]
            assert turn["start_enemy_health"] == trace[index - 1]["end_enemy_health"]


def check_route(route, settings, config):
    label = route["deck_label"]
    cid = route["collection_id"]
    assert label in settings["deck_labels"] and cid in settings["collection_ids"]
    assert route["scenario"] == "branch_map" and route["normal_battles"] == 2
    assert 0 <= route["pair_index"] < settings["samples"]
    seed = settings["seed_start"] + route["pair_index"]
    assert route["seed"] == seed and route["map_seed"] == seed + settings["map_seed_offset"]
    assert route["route_id"] == settings["route_ids"][route["pair_index"] % len(settings["route_ids"])]
    ids = ["start", f"route_{route['route_id']}_1", f"route_{route['route_id']}_2", f"route_{route['route_id']}_rest", "final_boss"]
    assert route["node_ids"] == ids
    bindings = route["encounter_bindings"]
    assert set(bindings) == {f"route_{rid}_{index}" for rid in settings["route_ids"] for index in (1, 2)} | {"final_boss"}
    for rid in settings["route_ids"]:
        selected = [bindings[f"route_{rid}_{index}"] for index in (1, 2)]
        assert len(set(selected)) == 2 and all(eid in config["pools"]["normal_encounter_pool"] for eid in selected)
    assert bindings["final_boss"] in config["pools"]["boss_encounter_pool"]
    assert route["normal_enemy_ids"] == [bindings[ids[1]], bindings[ids[2]]]
    assert route["boss_enemy_id"] == bindings["final_boss"]
    assert route["planned_battle_seeds"] == [seed + offset for offset in settings["battle_seed_offsets"]]
    assert route["planned_reward_seeds"] == [seed + offset for offset in settings["reward_seed_offsets"]]
    assert route["initial_health"] == route["initial_max_health"] == config["player_health"]
    deck = route["starting_deck"]
    assert deck[:len(config["basic"])] == config["basic"]
    assert route["starting_deck_is_formal"] == (label != "基础6张诊断")
    if label == "基础6张诊断":
        assert deck == config["basic"]
    else:
        assert len(deck) == len(config["basic"]) + 3
        assert [config["reward_cards"][card].get("rarity", 0) for card in deck[len(config["basic"]):]] == [3, 2, 1]
        if label == "参考9张":
            assert deck == config["basic"] + settings["reference_deck"]
    fights = route["battles"]
    assert 1 <= len(fights) <= 3
    expected = route["normal_enemy_ids"] + [route["boss_enemy_id"]]
    assert [fight["enemy_id"] for fight in fights] == expected[:len(fights)]
    assert [fight["seed"] for fight in fights] == route["planned_battle_seeds"][:len(fights)]
    for fight in fights:
        check_battle(fight, config, cid)
    assert all(fight["victory"] for fight in fights[:-1]), "失败后不能继续后续节点"
    assert route["boss_reached"] == (len(fights) == 3)
    assert route["victory"] == (route["boss_reached"] and fights[-1]["victory"])
    assert route["remaining_health"] == fights[-1]["remaining_health"]
    assert route["remaining_max_health"] == fights[-1]["remaining_max_health"]
    normals_won = sum(fight["victory"] for fight in fights[:2])
    assert len(route["reward_cards"]) == normals_won == len(route["collection_heals"])
    for card in route["reward_cards"]:
        assert card in config["reward_cards"] and config["reward_cards"][card].get("rarity", 0) in (0, 1, 2)
    assert fights[0]["deck"] == deck
    assert fights[0]["player_initial_health"] == route["initial_health"]
    assert fights[0]["player_initial_max_health"] == route["initial_max_health"]
    for index, heal in enumerate(route["collection_heals"]):
        fight = fights[index]
        assert fight["victory"] and heal["node_id"] == ids[index + 1]
        assert heal["before_health"] == fight["remaining_health"]
        assert heal["max_health"] == fight["remaining_max_health"]
        collection = config["collections"].get(cid)
        amount = collection["amount"] if collection and collection["effect_type"] == 2 else 0
        assert heal["amount"] == min(amount, heal["max_health"] - heal["before_health"])
        assert heal["after_health"] == heal["before_health"] + heal["amount"]
        assert 0 < heal["after_health"] <= heal["max_health"]
    assert route["collection_healing"] == sum(heal["amount"] for heal in route["collection_heals"])
    assert route["rest_config_heal"] == config["nodes"][ids[3]]["heal_amount"]
    assert 0 <= route["rest_healing"] <= route["rest_config_heal"]
    if route["boss_reached"]:
        last_heal = route["collection_heals"][-1]
        assert route["rest_health_before"] == last_heal["after_health"]
        assert route["rest_max_health"] == last_heal["max_health"]
        assert route["rest_healing"] == min(route["rest_config_heal"], route["rest_max_health"] - route["rest_health_before"])
        assert route["rest_health_after"] == route["rest_health_before"] + route["rest_healing"] == route["boss_entry_health"]
        assert route["boss_entry_health"] == fights[-1]["player_initial_health"]
    else:
        assert route["rest_healing"] == route["rest_health_before"] == route["rest_health_after"] == route["rest_max_health"] == route["boss_entry_health"] == 0
    for index, fight in enumerate(fights[1:], 1):
        last_heal = route["collection_heals"][index - 1]
        extra_heal = route["rest_healing"] if index == 2 else 0
        assert fight["player_initial_health"] == last_heal["after_health"] + extra_heal
        assert fight["player_initial_max_health"] == last_heal["max_health"]
        assert fight["deck"] == deck + route["reward_cards"][:index]
    completed = ["start"] + ids[1:1 + normals_won]
    if route["boss_reached"]:
        completed.append(ids[3])
        if route["victory"]:
            completed.append(ids[4])
    assert route["completed_node_ids"] == completed
    # 当前生命跨场完整守恒：战内扣血与回血、藏品和唯一休整均计入。
    health = route["initial_health"] - sum(fight["hp_deductions"] for fight in fights)
    health += sum(fight["positive_health_recovery"] for fight in fights) + route["collection_healing"] + route["rest_healing"]
    assert health == route["remaining_health"]


def check(raw, settings, config):
    assert raw["settings"] == settings
    assert raw["battle_parameters"] == read(HERE.parent / "评估参数.json")
    assert raw["failures"] == 0
    verify_sources(raw["source_hashes"])
    assert set(settings["collection_ids"]) == {"none"} | set(config["collections"])
    assert len(settings["collection_ids"]) == 4 and config["collection_option_count"] == 3
    assert config["reward_selection_count"] == 1
    rows = raw["routes"]
    assert raw["route_count"] == len(rows) == len(settings["deck_labels"]) * len(settings["collection_ids"]) * settings["samples"]
    assert raw["battle_count"] == sum(len(row["battles"]) for row in rows)
    grouped = {}
    paired = {}
    for row in rows:
        check_route(row, settings, config)
        key = (row["deck_label"], row["collection_id"])
        grouped.setdefault(key, []).append(row)
        pair_key = (row["deck_label"], row["seed"])
        assert row["collection_id"] not in paired.setdefault(pair_key, {})
        paired[pair_key][row["collection_id"]] = row
    assert set(grouped) == {(label, cid) for label in settings["deck_labels"] for cid in settings["collection_ids"]}
    for values in grouped.values():
        assert len(values) == settings["samples"]
        assert [row["seed"] for row in values] == list(range(settings["seed_start"], settings["seed_start"] + settings["samples"]))
    fields = ("seed", "map_seed", "route_id", "starting_deck", "starting_deck_is_formal", "node_ids", "encounter_bindings", "normal_enemy_ids", "boss_enemy_id", "initial_health", "initial_max_health", "planned_battle_seeds", "planned_reward_seeds", "rest_config_heal")
    for pair in paired.values():
        assert set(pair) == set(settings["collection_ids"])
        base = pair["none"]
        for row in pair.values():
            assert all(row[field] == base[field] for field in fields), "四组地图、开局或计划种子不一致"
            shared = min(len(base["reward_cards"]), len(row["reward_cards"]))
            assert row["reward_cards"][:shared] == base["reward_cards"][:shared], "共同经过的胜利节点奖励不一致"
            for index in range(min(len(base["battles"]), len(row["battles"]))):
                assert row["battles"][index]["deck"] == base["battles"][index]["deck"]
                assert row["battles"][index]["seed"] == base["battles"][index]["seed"]
    # 三种牌组的对应实验也保持同一整张地图与路线，只有起始牌组不同。
    for index in range(settings["samples"]):
        corresponding = [grouped[label, "none"][index] for label in settings["deck_labels"]]
        assert all(row["encounter_bindings"] == corresponding[0]["encounter_bindings"] and row["route_id"] == corresponding[0]["route_id"] for row in corresponding)
    return grouped


def wilson(wins, total):
    p, z = wins / total, 1.96
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    width = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return [max(0, center - width), min(1, center + width)]


def summarize(rows):
    n = len(rows)
    wins = sum(row["victory"] for row in rows)
    reached = [row for row in rows if row["boss_reached"]]
    normal_fights = [fight for row in rows for fight in row["battles"][:2]]
    deaths = Counter("通关" if row["victory"] else ("Boss" if row["boss_reached"] else f"普通战{len(row['battles'])}") for row in rows)
    return {"samples": n, "wins": wins, "win_rate": wins / n, "wilson_95": wilson(wins, n),
            "normal_battle_samples": len(normal_fights), "normal_battle_wins": sum(fight["victory"] for fight in normal_fights),
            "boss_reached": len(reached), "boss_reach_rate": len(reached) / n,
            "mean_boss_entry_health_reached_only": mean(row["boss_entry_health"] for row in reached) if reached else None,
            "mean_remaining_health": mean(row["remaining_health"] for row in rows),
            "mean_remaining_max_health": mean(row["remaining_max_health"] for row in rows),
            "mean_total_turns": mean(sum(fight["turns"] for fight in row["battles"]) for row in rows),
            "mean_collection_healing": mean(row["collection_healing"] for row in rows),
            "mean_rest_healing": mean(row["rest_healing"] for row in rows),
            "mean_battle_health_deductions": mean(sum(fight["hp_deductions"] for fight in row["battles"]) for row in rows),
            "mean_battle_health_recovery": mean(sum(fight["positive_health_recovery"] for fight in row["battles"]) for row in rows),
            "outcomes": {key: deaths[key] for key in ("普通战1", "普通战2", "Boss", "通关")}}


def paired_summary(base, collection):
    assert [row["seed"] for row in base] == [row["seed"] for row in collection]
    pairs = list(zip(base, collection))
    common_boss = [(before, after) for before, after in pairs if before["boss_reached"] and after["boss_reached"]]
    return {"samples": len(pairs),
            "win_rate_delta": mean(int(after["victory"]) - int(before["victory"]) for before, after in pairs),
            "wins_added": sum(after["victory"] and not before["victory"] for before, after in pairs),
            "wins_lost": sum(before["victory"] and not after["victory"] for before, after in pairs),
            "boss_reach_rate_delta": mean(int(after["boss_reached"]) - int(before["boss_reached"]) for before, after in pairs),
            "mean_remaining_health_delta": mean(after["remaining_health"] - before["remaining_health"] for before, after in pairs),
            "mean_total_turns_delta": mean(sum(fight["turns"] for fight in after["battles"]) - sum(fight["turns"] for fight in before["battles"]) for before, after in pairs),
            "mean_rest_healing_delta": mean(after["rest_healing"] - before["rest_healing"] for before, after in pairs),
            "common_boss_pairs": len(common_boss),
            "common_boss_mean_entry_health_delta": mean(after["boss_entry_health"] - before["boss_entry_health"] for before, after in common_boss) if common_boss else None,
            "common_boss_mean_collection_healing": mean(after["collection_healing"] for _, after in common_boss) if common_boss else None,
            "common_boss_mean_rest_healing_delta": mean(after["rest_healing"] - before["rest_healing"] for before, after in common_boss) if common_boss else None}


def value(number, signed=False):
    return "—" if number is None else format(number, "+.2f" if signed else ".2f")


def main():
    import sys
    sys.path.insert(0, str(ROOT))
    from tools.history_guard import require_sandbox
    require_sandbox(ROOT)
    settings = read(HERE / "评估参数.json")
    raw = read(HERE / "原始藏品数据.json")
    config = configuration()
    grouped = check(raw, settings, config)
    names = {"none": "无藏品对照", **{cid: item["name"] for cid, item in config["collections"].items()}}
    summaries, deltas = [], []
    for label in settings["deck_labels"]:
        for cid in settings["collection_ids"]:
            summaries.append({"deck_label": label, "collection_id": cid, "name": names[cid], **summarize(grouped[label, cid])})
            if cid != "none":
                deltas.append({"deck_label": label, "collection_id": cid, "name": names[cid], **paired_summary(grouped[label, "none"], grouped[label, cid])})
    sources = [HERE / "评估参数.json", HERE / "原始藏品数据.json", HERE.parent / "评估参数.json"]
    snapshot = {"date": settings["evaluation_date"], "model_version": settings["model_version"], "settings": settings,
                "route_count": raw["route_count"], "battle_count": raw["battle_count"], "godot_version": raw["godot_version"],
                "collections": list(config["collections"].values()), "results": summaries, "paired_deltas": deltas,
                "source_hashes": raw["source_hashes"],
                "input_hashes": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}}
    (HERE / "藏品评估数据.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    control = grouped["随机合法开局9张", "none"]
    selected_enemies = Counter(eid for row in control for eid in row["normal_enemy_ids"])
    selected_bosses = Counter(row["boss_enemy_id"] for row in control)
    distribution = "、".join(f"{config['enemies'][eid]['name']}{count}次" for eid, count in sorted(selected_enemies.items()))
    boss_distribution = "、".join(f"{config['enemies'][eid]['name']}{count}局" for eid, count in sorted(selected_bosses.items()))
    lines = ["# 三件藏品的真实路线对照", "",
             f"日期：{settings['evaluation_date']}，模型v{settings['model_version']}。Godot {raw['godot_version']}正式结算，{raw['route_count']}条路线、{raw['battle_count']}场战斗；3种牌组×无藏品及3件藏品×每组{settings['samples']}个配对种子。", "",
             "正式流程为三轮选牌后进入地图，点击开始节点，再从三件藏品中领取一件；领取后开放三条支线。无藏品仅作为隔离效果的实验对照，不是正式开始节点的第四个选项。", "",
             "## 1. 当前效果与比较条件", "",
             "| 藏品 | 正式资源中的效果 |", "| --- | --- |"]
    for cid in settings["collection_ids"]:
        if cid != "none":
            item = config["collections"][cid]
            lines.append(f"| {item['name']} | {item['description']} |")
    lines += ["", f"初始生命{config['player_health']}/{config['player_health']}。每条支线两种不同普通敌人→一次休整→随机最终Boss；四组使用同一整张地图的全部7个战斗绑定，同一支线、起始牌组、战斗与奖励种子。种子从{settings['seed_start']}开始，路线按a、b、c轮换，不针对藏品换线。每场普通胜利领取第一候选奖励，正式九牌满程为11张，六牌诊断满程为8张。", "",
              "随机合法九牌按传说→史诗→稀有三轮抽候选，每轮固定选第一张；参考九牌为基础六牌＋永恒、战神祝福、上勾拳。六牌诊断先合法完成构筑，再在实验中替换回基础六牌，不是正式主流程可获得的开局。每个配对种子在三类牌组中也使用同一地图。", "",
              f"所走支线的{settings['samples'] * 2}次普通敌人选择：" + distribution + f"。{settings['samples']}个最终Boss选择：" + boss_distribution + "。这些敌人分布在四组和三种牌组中保持一致；不同藏品可能导致中途死亡，实际打到的敌人数量会不同。", "",
              "## 2. 整局结果", "",
              "| 起始牌组 | 藏品 | 通关/样本 | 通关率 | 95%区间 | 到达Boss | Boss入场生命¹ | 终局生命² | 总回合² |",
              "| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |"]
    for row in summaries:
        interval = "～".join(f"{number * 100:.1f}%" for number in row["wilson_95"])
        lines.append(f"| {row['deck_label']} | {row['name']} | {row['wins']}/{row['samples']} | {row['win_rate']*100:.1f}% | {interval} | {row['boss_reached']}/{row['samples']} | {value(row['mean_boss_entry_health_reached_only'])} | {value(row['mean_remaining_health'])} | {value(row['mean_total_turns'])} |")
    lines += ["", "¹ Boss入场平均只统计该组到达Boss的路线，不同组可能包含不同样本，不能直接把两个平均值相减当作配对收益。² 终局生命与总回合统计全部路线，死亡剩余生命为0；回合包括最终致死或致胜回合。增加总回合可能来自存活至后续节点，不能单独认定更慢。区间为每组通关率的Wilson 95%区间。", "",
              "## 3. 同种子配对净变化", "",
              f"下表各藏品与该牌组的无藏品组逐条配对；通关及终局生命使用全部{settings['samples']}对，Boss入场净增量仅比较两组都到达Boss的共同样本。", "",
              "| 起始牌组 | 藏品 | 通关率净变化 | 新增胜利/失去胜利 | 终局生命净变化 | 共同Boss样本 | Boss入场生命净变化 |",
              "| --- | --- | ---: | --- | ---: | ---: | ---: |"]
    for row in deltas:
        lines.append(f"| {row['deck_label']} | {row['name']} | {row['win_rate_delta']*100:+.1f}个百分点 | {row['wins_added']}/{row['wins_lost']} | {value(row['mean_remaining_health_delta'], True)} | {row['common_boss_pairs']} | {value(row['common_boss_mean_entry_health_delta'], True)} |")
    lines += ["", "藏品改变实际伤害、盾量或生命，也可能改变同一贪心策略的出牌选择；因此配对衡量整个藏品条件的结果变化。相同战斗种子保证同一牌组的初始洗牌条件，不保证不同出牌决策后的所有抽牌序列逐张相同。本实验没有用这些结果重调藏品、敌人或卡牌参数。", "",
              "## 4. 实际回血、休整与死亡位置", "",
              "| 起始牌组 | 藏品 | 圣杯实际回血² | 休整实际回血² | 普通战1死亡 | 普通战2死亡 | Boss死亡 | 通关 |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in summaries:
        positions = row["outcomes"]
        lines.append(f"| {row['deck_label']} | {row['name']} | {value(row['mean_collection_healing'])} | {value(row['mean_rest_healing'])} | {positions['普通战1']} | {positions['普通战2']} | {positions['Boss']} | {positions['通关']} |")
    lines += ["", "圣杯只在普通胜利后、牌组奖励前治疗，先同步战斗的当前与最大生命；每节点仅一次，死亡和Boss胜利没有战后回血。实际治疗与休整均被最大生命截断，血祭的上限损失照常保留。两场普通战的圣杯回血名义上限为12，不等于Boss入场必然多12血。", "",
              "| 起始牌组 | 圣杯共同Boss样本 | 实际圣杯回血 | 休整回血配对变化 | Boss入场生命配对变化 |",
              "| --- | ---: | ---: | ---: | ---: |"]
    for row in deltas:
        if row["collection_id"] == "ember_chalice":
            lines.append(f"| {row['deck_label']} | {row['common_boss_pairs']} | {value(row['common_boss_mean_collection_healing'])} | {value(row['common_boss_mean_rest_healing_delta'], True)} | {value(row['common_boss_mean_entry_health_delta'], True)} |")
    lines += ["", "上表限定共同Boss样本，避免把新增到达Boss的路线混入治疗比较。休整回血变化与入场净变化分开保留，不把治疗替代误计为新增生命；圣杯也可能改变第二场的生存和策略，因此不把所有差额都归因于休整截断。", "",
              "## 5. 已核对与观察限制", "",
              "逐场核对生命扣除减战内治疗等于净失血，逐路线核对初始生命减战内扣血、加战内治疗、藏品治疗和唯一休整等于终局生命；同时核对最大生命、奖励次数、两种不同普通敌人、地图绑定不变、失败不继续及正式RunState的完整进度。首回合力量与前三回合格挡由BattleSession生效，跨场重新创建战斗状态。", "",
              "本实验统计胜负、生命、回合、实际治疗和死亡位置；没有直接追踪獠牙相对无力量的逐段增伤，也没有统计盾徽的格挡抵伤、溢出、保留或盾牌猛击增益，不能把模型估值写成这些指标的实测数据。关键时序、重复触发和卡牌配合另由机制测试验证。", "",
              f"自动策略继承综合模型，查看当前手牌、能量、双方状态和可见意图，不预知抽牌、不搜索最优出牌顺序、不主动换装、不优化选牌和奖励。每组{settings['samples']}种子的结果用于首版试玩对照，不保证人类胜率，也不把原普通敌人基础牌约80%目标套用到藏品或整局路线。", "",
              "## 6. 来源与复算", "",
              "[评估参数](./评估参数.json)、[原始路线与逐轮战斗](./原始藏品数据.json)、[汇总数据](./藏品评估数据.json)、[评估脚本](./评估藏品.gd)、[生成工具](./生成藏品评估.py)、[运行说明](./README.md)。[藏品设计](../藏品设计/三件开局藏品设计.md)保留标准模型估值；[主综合报告](../综合量化评估.md)维持无藏品基准，两份数据不混为同一观察条件。", "",
              "原始数据保存规则与资源SHA-256，覆盖collections目录在内的全部相关GDScript与tres；生成报告前核对当前来源、每条件64样本与四组配对。来源变化后必须重新运行，不继续引用旧样本。", ""]
    (HERE / "三件藏品实测评估.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"藏品对照核对完成：{raw['route_count']}条路线、{raw['battle_count']}场战斗、12条件；来源、四组配对与生命账目通过。")


if __name__ == "__main__":
    main()
