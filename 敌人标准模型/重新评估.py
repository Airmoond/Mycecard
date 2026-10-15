"""只读评估敌人行动、力量与状态轨迹；不修改游戏资源。"""
from __future__ import annotations
import hashlib
import json
import math
import re
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
PARAMS = json.loads((HERE / "模型参数.json").read_text(encoding="utf-8"))
SOURCES: set[Path] = set()


def number(value, places=3):
    x = Decimal(str(round(value, 10))).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
    return format(x, f".{places}f")


def parse_value(raw):
    raw = raw.strip()
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1].replace(r"\n", "\n").replace(r'\"', '"')
    return raw


def resource(path):
    path = path.resolve()
    SOURCES.add(path)
    content = path.read_text(encoding="utf-8-sig")
    headers = list(re.finditer(r"(?m)^\[([^\n]+)\]\s*$", content))
    root, sub, ext = None, {}, {}
    for i, header in enumerate(headers):
        title = header.group(1)
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', title))
        body = content[header.end():headers[i + 1].start() if i + 1 < len(headers) else len(content)]
        fields = list(re.finditer(r"(?m)^([\w/]+) = ", body))
        props = {f.group(1): parse_value(body[f.end():fields[j + 1].start() if j + 1 < len(fields) else len(body)])
                 for j, f in enumerate(fields)}
        if title == "resource":
            root = props
        elif title.startswith("sub_resource "):
            sub[attrs["id"]] = props
        elif title.startswith("ext_resource "):
            ext[attrs["id"]] = attrs["path"]
    if root is None:
        raise ValueError(f"缺少根资源：{path}")
    return root, sub, ext


def refs(raw):
    match = re.search(r"\]\((.*)\)$", raw, re.S)
    if not match:
        raise ValueError(f"不能解析资源数组：{raw}")
    found = re.findall(r'(?:SubResource|ExtResource)\("[^"]+"\)', match.group(1))
    if not found:
        raise ValueError("资源数组为空或不能解析")
    return found


def external_path(ref, external):
    match = re.fullmatch(r'ExtResource\("([^"]+)"\)', ref)
    if not match:
        raise ValueError(f"需要外部资源引用：{ref}")
    path = external[match.group(1)]
    if not path.startswith("res://"):
        raise ValueError(f"不支持资源路径：{path}")
    return PROJECT / path[6:]


def resolve(ref, sub, ext):
    match = re.fullmatch(r'(SubResource|ExtResource)\("([^"]+)"\)', ref)
    if not match:
        raise ValueError(f"不能解析引用：{ref}")
    return dict(sub[match.group(2)]) if match.group(1) == "SubResource" else resource(external_path(ref, ext))[0]


def map_roles():
    run, _, run_ext = resource(PROJECT / "tests/fixtures/phase5_run.tres")
    root, sub, ext = resource(external_path(run["map_definition"], run_ext))
    roles, bases = {}, {}

    def bind(encounter_path, role, basis):
        encounter, _, encounter_ext = resource(encounter_path)
        enemy_path = external_path(encounter["enemy_definition"], encounter_ext).resolve()
        roles.setdefault(enemy_path, set()).add(role)
        bases.setdefault(enemy_path, set()).add(basis)

    used_random_pools = set()
    for ref in refs(root["nodes"]):
        if ref.startswith("ExtResource"):
            node, _, node_ext = resource(external_path(ref, ext))
        else:
            node, node_ext = resolve(ref, sub, ext), ext
        kind = node.get("node_type", 0)
        if kind not in (0, 2):
            continue
        role = "Boss" if kind == 2 else "普通敌人"
        if node.get("random_encounter", False):
            pool = "boss_encounter_pool" if kind == 2 else "normal_encounter_pool"
            used_random_pools.add((pool, role))
        else:
            bind(external_path(node["encounter_definition"], node_ext), role, "默认地图固定节点")
    for pool, role in sorted(used_random_pools):
        for ref in refs(run[pool]):
            bind(external_path(ref, run_ext), role, "默认地图随机遭遇池")
    return roles, bases


def load_enemies():
    roles, bases = map_roles()
    enemies = []
    for path in sorted((PROJECT / "combatants/enemies/data").glob("*.tres")):
        if 'script_class="EnemyDefinition"' not in path.read_text(encoding="utf-8-sig").splitlines()[0]:
            continue
        root, sub, ext = resource(path)
        actions = []
        for action_ref in refs(root["action_pattern"]):
            if action_ref.startswith("ExtResource"):
                raw, action_sub, action_ext = resource(external_path(action_ref, ext))
            else:
                raw, action_sub, action_ext = resolve(action_ref, sub, ext), sub, ext
            effects = []
            for effect_ref in refs(raw["effects"]):
                effect = {"effect_type": 0, "amount": 0, "repeat_count": 1,
                          "target_type": 0, "damage_source": 0, "is_attack_damage": True,
                          **resolve(effect_ref, action_sub, action_ext)}
                # 只接受已实现的有序效果；未知机制必须明确停止，不能静默估为0。
                kind, target = effect["effect_type"], effect["target_type"]
                if (kind not in (0, 1, 6, 7, 8)
                    or (kind == 0 and (target != 1 or effect["damage_source"] != 0))
                    or (kind in (1, 6) and target != 0)
                    or (kind in (7, 8) and target != 1)):
                    raise ValueError(f'{root["display_name"]} / {raw["action_id"]} 有未实现的行动估值，请先扩展模型：{effect}')
                if effect.get("heals_from_damage", False):
                    raise ValueError("治疗伤害需要独立建模")
                if effect["amount"] <= 0 or effect["repeat_count"] <= 0:
                    raise ValueError("数值效果与重复次数必须为正")
                effects.append(effect)
            damage = sum(e["amount"] * e["repeat_count"] for e in effects if e["effect_type"] == 0)
            block = sum(e["amount"] * e["repeat_count"] for e in effects if e["effect_type"] == 1)
            value = damage / PARAMS["damage_per_enemy_turn"] + block / PARAMS["block_per_enemy_turn"]
            actions.append({"id": raw["action_id"], "name": raw["intent_text"], "effects": effects,
                            "damage": damage, "block": block, "value": value,
                            "nominal_value": value,
                            "segments": sum(e["repeat_count"] for e in effects if e["effect_type"] == 0)})
        declared = PARAMS.get("enemy_role_overrides", {}).get(root["combatant_id"])
        if declared not in (None, "normal", "boss"):
            raise ValueError(f"未识别的显式敌人用途：{declared}")
        mapped = roles.get(path.resolve(), set())
        override_role = "Boss" if declared == "boss" else "普通敌人"
        if declared and mapped and mapped != {override_role}:
            raise ValueError(f"显式用途与地图用途冲突：{root['combatant_id']}")
        role = "、".join(sorted(mapped)) if mapped else (override_role if declared else "未在默认地图绑定")
        enemies.append({"id": root["combatant_id"], "name": root["display_name"], "health": root["max_health"],
                        "role": role,
                        "role_basis": "、".join(sorted(bases[path.resolve()])) if mapped else ("模型参数显式用途；尚未绑定默认地图" if declared else "未知用途，需补充声明"),
                        "source": path.relative_to(PROJECT).as_posix(), "actions": actions})
    if not enemies or len({e["id"] for e in enemies}) != len(enemies):
        raise ValueError("敌人为空或ID重复")
    return enemies


def state(health=None):
    return {"health": health, "block": 0, "strength": 0, "weak": 0, "vulnerable": 0,
            "weak_skip_first_tick": False, "vulnerable_skip_first_tick": False}


def apply_status(target, key, amount):
    # CombatantState.apply_*：仅从0首次施加时建立跳过本轮递减标记。
    if target[key] == 0:
        target[f"{key}_skip_first_tick"] = True
    target[key] += amount


def tick_statuses(target):
    for key in ("weak", "vulnerable"):
        if target[f"{key}_skip_first_tick"]:
            target[f"{key}_skip_first_tick"] = False
        elif target[key] > 0:
            target[key] -= 1


def attack_damage(base, attacker, target):
    damage = base + attacker["strength"]
    if attacker["weak"] > 0:
        damage *= 0.75
    if target["vulnerable"] > 0:
        damage *= 1.5
    return max(0, math.floor(damage))


def profile_attack(profile, player, enemy):
    segments = profile["attack_segments"]
    if sum(segments) != profile["attack"]:
        raise ValueError("参考玩家攻击总量与分段配置不符")
    actual = sum(attack_damage(base, player, enemy) for base in segments)
    without_weak = {**player, "weak": 0}
    normal = sum(attack_damage(base, without_weak, enemy) for base in segments)
    return actual, normal - actual


def execute_action(action, enemy, player):
    """顺序结算效果，支持有限生命或固定存活窗口的无限生命。"""
    record = {"action": action["id"], "damage": 0, "block_supply": 0, "health_loss": 0,
              "strength_before": enemy["strength"], "damage_segments": [],
              "strength_damage_increment": 0, "vulnerable_damage_increment": 0,
              "weak_applied": 0, "vulnerable_applied": 0}
    for effect in action["effects"]:
        for _ in range(effect["repeat_count"]):
            kind, amount = effect["effect_type"], effect["amount"]
            if kind == 0:
                damage = attack_damage(amount, enemy, player) if effect["is_attack_damage"] else amount
                record["damage"] += damage
                record["damage_segments"].append(damage)
                if effect["is_attack_damage"]:
                    # 增量只用于解释；已经包含在damage里，不能额外加分。
                    no_strength = {**enemy, "strength": 0}
                    no_vulnerable = {**player, "vulnerable": 0}
                    record["strength_damage_increment"] += damage - attack_damage(amount, no_strength, player)
                    record["vulnerable_damage_increment"] += damage - attack_damage(amount, enemy, no_vulnerable)
                blocked = min(player["block"], damage)
                player["block"] -= blocked
                loss = damage - blocked
                if player["health"] is not None:
                    loss = min(player["health"], loss)
                    player["health"] -= loss
                record["health_loss"] += loss
            elif kind == 1:
                enemy["block"] += amount
                record["block_supply"] += amount
            elif kind == 6:
                enemy["strength"] += amount
            elif kind == 7:
                apply_status(player, "weak", amount)
                record["weak_applied"] += amount
            elif kind == 8:
                apply_status(player, "vulnerable", amount)
                record["vulnerable_applied"] += amount
            else:
                raise ValueError(f"未建模效果：{kind}")
            # 伤害队列不会在普通DAMAGE击杀时中断；控制器在完整行动之后检查胜负。
    record["strength_after"] = enemy["strength"]
    record["direct_value"] = record["damage"] / PARAMS["damage_per_enemy_turn"] + record["block_supply"] / PARAMS["block_per_enemy_turn"]
    return record


def planned_trace(enemy, count, profile):
    """假定双方存活；每次敌人行动后报告下一玩家回合的虚弱防御潜力。"""
    enemy_state, player_state = state(), state()
    records = []
    for index in range(count):
        enemy_state["block"] = 0
        player_state["block"] = 0
        action = enemy["actions"][index % len(enemy["actions"])]
        record = execute_action(action, enemy_state, player_state)
        tick_statuses(player_state)
        tick_statuses(enemy_state)
        actual_attack, prevented = profile_attack(profile, player_state, enemy_state)
        record.update({"round": index + 1, "player_weak_after_tick": player_state["weak"],
                       "player_vulnerable_after_tick": player_state["vulnerable"],
                       "next_reference_player_attack": actual_attack,
                       "next_reference_attack_prevented_by_weak": prevented,
                       "weak_defense_potential_value": prevented / PARAMS["block_per_enemy_turn"],
                       "pressure_value": record["direct_value"] + prevented / PARAMS["block_per_enemy_turn"]})
        records.append(record)
    return records


def trace(enemy, profile):
    # 玩家按打击的真实分段攻击。敌人旧盾先吸收，自己回合开始清旧盾；
    # 敌人行动后递减状态，再进入下一玩家回合，与正式控制器一致。
    enemy_state, player_state = state(enemy["health"]), state(PARAMS["initial_player_health"])
    prevented, weak_prevented, harm, turns_enemy = 0, 0, 0, 0
    turns = []
    outcome = "参考窗口耗尽"
    for turn in range(1, PARAMS["maximum_reference_rounds"] + 1):
        player_state["block"] = profile["block"]
        attack, weak_lost, before_block, dealt = 0, 0, 0, 0
        if sum(profile["attack_segments"]) != profile["attack"]:
            raise ValueError("参考玩家攻击总量与分段配置不符")
        for base in profile["attack_segments"]:
            segment = attack_damage(base, player_state, enemy_state)
            attack += segment
            weak_lost += attack_damage(base, {**player_state, "weak": 0}, enemy_state) - segment
            absorbed = min(segment, enemy_state["block"])
            enemy_state["block"] -= absorbed
            before_block += absorbed
            actual = min(enemy_state["health"], segment - absorbed)
            enemy_state["health"] -= actual
            dealt += actual
            if enemy_state["health"] == 0:
                break
        weak_prevented += weak_lost
        prevented += before_block
        record = {"round": turn, "player_damage": dealt, "player_attack_supply": attack,
                  "player_attack_prevented_by_weak": weak_lost,
                  "enemy_block_absorbed": before_block,
                  "enemy_health_after_player": enemy_state["health"], "enemy_action": None,
                  "player_health_loss": 0, "player_weak_before_action": player_state["weak"],
                  "player_vulnerable_before_action": player_state["vulnerable"]}
        if enemy_state["health"] == 0:
            turns.append(record)
            outcome = "玩家胜利"
            break
        enemy_state["block"] = 0
        action = enemy["actions"][(turn - 1) % len(enemy["actions"])]
        record["enemy_action"] = action["id"]
        turns_enemy += 1
        executed = execute_action(action, enemy_state, player_state)
        record["enemy_execution"] = executed
        record["player_health_loss"] = executed["health_loss"]
        harm += executed["health_loss"]
        record["player_health_after_enemy"] = player_state["health"]
        if player_state["health"] > 0:
            tick_statuses(player_state)
            tick_statuses(enemy_state)
        record["player_weak_after_tick"] = player_state["weak"]
        record["player_vulnerable_after_tick"] = player_state["vulnerable"]
        record["enemy_strength_after"] = enemy_state["strength"]
        turns.append(record)
        if player_state["health"] == 0:
            outcome = "玩家失败"
            break
    return {"profile": profile, "outcome": outcome, "player_rounds": len(turns),
            "successful_enemy_turns": turns_enemy, "player_health_loss": harm,
            "effective_enemy_block": prevented, "player_attack_prevented_by_weak": weak_prevented,
            "player_health_remaining": player_state["health"], "turns": turns}


def assess(enemy):
    actions = enemy["actions"]
    cycle = len(actions)
    profile = next(p for p in PARAMS["player_profiles"] if p["id"] == PARAMS["status_pressure_profile"])
    records = planned_trace(enemy, max(max(PARAMS["reference_windows"]), cycle), profile)
    first_cycle = records[:cycle]
    windows = {}
    for window in PARAMS["reference_windows"]:
        planned = records[:window]
        direct = sum(a["direct_value"] for a in planned)
        pressure = sum(a["pressure_value"] for a in planned)
        windows[str(window)] = {"total_value": direct, "average_value": direct / window,
                                "damage": sum(a["damage"] for a in planned),
                                "block_supply": sum(a["block_supply"] for a in planned),
                                "weak_reference_attack_prevented": sum(a["next_reference_attack_prevented_by_weak"] for a in planned),
                                "total_pressure_value": pressure, "average_pressure_value": pressure / window,
                                "peak_direct_value": max(a["direct_value"] for a in planned),
                                "peak_pressure_value": max(a["pressure_value"] for a in planned),
                                "turns": planned}
    total = sum(a["direct_value"] for a in first_cycle)
    return {"enemy": enemy, "cycle_total": total, "cycle_average": total / cycle,
            "cycle_damage": sum(a["damage"] for a in first_cycle),
            "cycle_block_supply": sum(a["block_supply"] for a in first_cycle),
            "opening_nominal_value": actions[0]["nominal_value"],
            "opening_value": records[0]["direct_value"],
            "opening_pressure_value": records[0]["pressure_value"],
            "peak_action_value": max(a["direct_value"] for a in records),
            "peak_pressure_value": max(a["pressure_value"] for a in records),
            "peak_damage": max(a["damage"] for a in records),
            "peak_window_length": len(records), "status_pressure_profile": profile,
            "grows_each_cycle": any(e["effect_type"] == 6 for a in actions for e in a["effects"]),
            "action_trace": records,
            "reference_windows": windows, "player_profiles": [trace(enemy, p) for p in PARAMS["player_profiles"]]}


def main():
    import sys
    sys.path.insert(0, str(PROJECT))
    from tools.history_guard import require_sandbox
    require_sandbox(PROJECT)
    enemies = load_enemies()
    results = [assess(e) for e in enemies]
    SOURCES.update(PROJECT / rel for rel in (
        "combatants/enemies/enemy_definition.gd", "combatants/enemies/enemy_action_definition.gd",
        "battle/model/enemy_state.gd", "battle/model/combatant_state.gd",
        "battle/battle_controller.gd", "battle/actions/attack_damage_resolver.gd",
        "battle/actions/combat_effect_definition.gd", "battle/actions/action_queue.gd",
        "battle/data/encounter_definition.gd", "run/data/run_definition.gd",
        "run/map/data/map_definition.gd", "run/map/data/map_node_definition.gd"))
    if not math.isclose(12 / PARAMS["damage_per_enemy_turn"], 1) or not math.isclose(10 / PARAMS["block_per_enemy_turn"], 1):
        raise ValueError("两项基础估值锚点发生改变")
    for item in results:
        if item["enemy"]["role"] not in ("Boss", "普通敌人"):
            raise ValueError(f"未绑定地图的敌人需要显式用途：{item['enemy']['id']}")
        role = "boss" if item["enemy"]["role"] == "Boss" else "normal"
        target = PARAMS["design_targets"][role]
        exception = PARAMS["design_targets"].get("enemy_exceptions", {}).get(item["enemy"]["id"])
        limit = exception["maximum_value"] if exception else target["maximum_value"]
        item["design_check"] = {"opening_target": target["opening_value"], "maximum_allowed": limit,
                                "exception": exception,
                                "opening_matches": math.isclose(item["opening_value"], target["opening_value"], abs_tol=0.05 + 1e-10),
                                "preferred_health_maximum": target.get("preferred_health_maximum"),
                                "health_within_preference": target.get("preferred_health_maximum") is None or item["enemy"]["health"] <= target["preferred_health_maximum"],
                                "direct_peak_within_limit": limit is None or item["peak_action_value"] <= limit,
                                "peak_within_limit": limit is None or item["peak_pressure_value"] <= limit}
    snapshot = {"model_version": PARAMS["model_version"], "date": PARAMS["evaluation_date"],
                "parameters": PARAMS, "enemy_count": len(enemies), "results": results,
                "resource_hashes": {p.relative_to(PROJECT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(SOURCES)}}
    (HERE / "评估数据.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["# 当前敌人量化评估", "",
             f'快照：{PARAMS["evaluation_date"]}，模型v{PARAMS["model_version"]}。覆盖当前实际资源中的{len(enemies)}种敌人，逐项读取真实有序行动。用途由默认地图固定节点或所用随机遭遇池识别；未进入默认地图的资源由模型参数显式声明。随机池用途表示可出现，不表示每局遇到全部敌人。',
             "", "1 E为一个标准敌人回合：12伤害或10格挡。A=D/12+B/10；均值与峰值是行动供给强度，不是胜率或完整难度。",
             "", "设计目标：普通敌人首行动约0.7 E、完整行动上限1.8 E；Boss首行动1.3 E、上限2.6 E。上限是允许范围，不要求成长、不要求每种敌人达到上限。狂怒蛮兵按成长机制例外处理，持续每回合先增加2力量，允许突破1.8 E。",
             "", "普通敌人的设计偏好为最大生命尽量不超过100，以生命和循环共同校准基础牌组约80%胜率。100是设计偏好，报告单列是否满足，不在引擎中强制截断生命。",
             "", "行动直接E包括当时力量与玩家易伤后的实际攻击供给及新增格挡。参考压力E另加本次行动后下一均衡玩家回合被虚弱减少的攻击/10：均衡玩家以两次基础打击6+6攻击，虚弱时4+4，减少4伤=0.4 E。这个潜力不另增加敌人生命；易伤与力量的解释增量不再计分。",
             "", "## 敌人总表", "",
             "| 敌人 | 模型用途 | 生命 | 循环长度 | 首行动直接E | 第一循环总E | 第一循环均值E/回合 | 相对基准 | 12行动最高直接E | 最高伤害 |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for item in results:
        e = item["enemy"]
        lines.append(f'| {e["name"]} | {e["role"]} | {e["health"]} | {len(e["actions"])} | {number(item["opening_value"])} | {number(item["cycle_total"])} | {number(item["cycle_average"])} | {number(item["cycle_average"]*100, 1)}% | {number(item["peak_action_value"])} | {item["peak_damage"]} |')
    lines += ["", "第一循环均值仅描述首次遍历。力量成长敌人的后续循环会更强，不能把首次均值当作无限周期均值。峰值按固定存活12行动窗口报告，成长敌人的数学长期峰值无上限。", "", "## 目标核对", "", "| 敌人 | 首行动直接 / 目标 | 首行动参考压力 | 12行动参考压力峰值 / 允许上限 | 结果 |", "| --- | --- | --- | --- | --- |"]
    for item in results:
        check = item["design_check"]
        passed = check["opening_matches"] and check["peak_within_limit"]
        limit_text = number(check["maximum_allowed"]) if check["maximum_allowed"] is not None else "无上限（成长机制例外）"
        status = "成长机制例外" if check["exception"] else ("达标" if passed else "需复核")
        if check["exception"] and not check["opening_matches"]:
            status += "；起手直接值偏离约0.7"
        lines.append(f'| {item["enemy"]["name"]} | {number(item["opening_value"])} / {number(check["opening_target"])} | {number(item["opening_pressure_value"])} | {number(item["peak_pressure_value"])} / {limit_text} | {status} |')
    lines += ["", "## 各次行动", "", "| 敌人 | 循环位置 | 行动 | 总伤害 | 伤害段数 | 格挡 | 模型E |", "| --- | ---: | --- | ---: | ---: | ---: | ---: |"]
    for item in results:
        e = item["enemy"]
        for i, action in enumerate(e["actions"], 1):
            lines.append(f'| {e["name"]} | {i} | {action["name"]} | {action["damage"]} | {action["segments"]} | {action["block"]} | {number(action["value"])} |')
    lines += ["", "动作配置表的模型E是无既有状态、未结算力量的原始伤害/格挡价格；力量、弱化与易伤必须合并下方实际轨迹阅读，不以静态0伤认定状态效果价值为0。", "", "## 固定存活窗口的计划供给", "", "假定敌人可以完整行动到窗口结束，不扣除玩家提前击杀。格挡为生成量，不是实际吸收量，也不保证一直累积。每次行动的虚弱防御潜力归给它后面的下一参考玩家回合，窗口最后行动施加的状态也按该下一回合计潜力；不是已兑现的生命收益。", "",
              "| 敌人 | 敌人行动次数 | 实际总伤害 | 总格挡供给 | 总直接E | 均直接E | 虚弱减少参考攻击 | 均参考压力E |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for item in results:
        for window, values in item["reference_windows"].items():
            lines.append(f'| {item["enemy"]["name"]} | {window} | {values["damage"]} | {values["block_supply"]} | {number(values["total_value"])} | {number(values["average_value"])} | {values["weak_reference_attack_prevented"]} | {number(values["average_pressure_value"])} |')
    lines += ["", "## 12行动逐轮真实状态轨迹", "", "在敌人首次施加状态后跳过当轮递减，后续叠加不刷新该例外。下列虚弱、易伤层数均为该敌人行动结束、完成状态递减后的剩余层数。增伤原因在JSON另存，已包含在伤害里。", "", "| 敌人 | 次数 | 行动 | 力量前→后 | 实际伤害分段 | 格挡 | 虚弱 / 易伤 | 下轮参考攻击 | 直接E | 参考压力E |", "| --- | ---: | --- | --- | --- | ---: | --- | ---: | ---: | ---: |"]
    for item in results:
        for turn in item["action_trace"]:
            action_name = next(a["name"] for a in item["enemy"]["actions"] if a["id"] == turn["action"])
            segments = "+".join(map(str, turn["damage_segments"])) or "0"
            lines.append(f'| {item["enemy"]["name"]} | {turn["round"]} | {action_name} | {turn["strength_before"]}→{turn["strength_after"]} | {segments} | {turn["block_supply"]} | {turn["player_weak_after_tick"]} / {turn["player_vulnerable_after_tick"]} | {turn["next_reference_player_attack"]} | {number(turn["direct_value"])} | {number(turn["pressure_value"])} |')
    lines += ["", "## 三种参考玩家的结算", "",
              "以下是可重复的简化行动序列，不是实际牌组或完整游戏测试。玩家每回合固定供给6伤＋10格挡、12伤＋5格挡或18伤＋0格挡，均相当于3费基础牌预算；假设每轮都有相应卡牌。玩家先攻击，击杀后敌人不行动，格挡与多段按当前代码规则顺序扣除。", "",
              "| 敌人 | 玩家方案 | 玩家回合数 | 敌人实际出手次数 | 玩家损失生命 | 敌人格挡实际吸收 | 虚弱实际减少玩家攻击 | 结果 |", "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    for item in results:
        for run in item["player_profiles"]:
            lines.append(f'| {item["enemy"]["name"]} | {run["profile"]["name"]} | {run["player_rounds"]} | {run["successful_enemy_turns"]} | {run["player_health_loss"]} | {run["effective_enemy_block"]} | {run["player_attack_prevented_by_weak"]} | {run["outcome"]} |')
    lines += ["", "这些结果展示节奏影响：均值较高的敌人也可能被进攻方案提前击杀；防守优先不一定损失更多生命，但可能显著拉长战斗。不能据此推导真实最优策略或胜率；基础牌组胜率请以综合数值模型的实际洗牌样本校准。", "", "## 逐敌人说明", ""]
    for item in results:
        e = item["enemy"]
        lines += [f'### {e["name"]}', "", f'资源：[敌人定义](../{e["source"]})。行动从第一项开始，依次循环；最大生命{e["health"]}。', "",
                  f'完整循环伤害{item["cycle_damage"]}、格挡生成{item["cycle_block_supply"]}，总价值{number(item["cycle_total"])} E；循环均值{number(item["cycle_average"])} E/回合。', ""]
        if e["id"] == "cave_crawler":
            lines += ["实验配置为8伤→12伤的固定二步循环：首行动0.667 E（约0.7），峰值1.0 E，低于1.8 E上限；没有成长或力量增益。第三次行动回到8伤。最大生命30。", ""]
        elif e["id"] == "ruin_guard":
            lines += ["实验配置保留防御→连击→重击，改为13格挡→8伤×2→18伤。首行动1.3 E，峰值1.5 E，低于2.6 E上限；没有成长或力量增益。盾保护下一玩家回合。最大生命99。", ""]
        elif e["id"] == "bulwark_sentinel":
            lines += ["连续三次格挡后重击，护盾在下一玩家回合兑现；前三轮没有攻击，不意味着格挡可以累积到第四轮。综合模型以基础打击/防御牌组核对玩家能否利用蓄力空档击杀或准备防御。", ""]
        elif e["id"] == "hexbound_acolyte":
            lines += ["低基础伤害，依有序效果给玩家虚弱与易伤；实际攻击压力按当时易伤倍率逐段取整。虚弱以均衡玩家下一回合两张打击减少的伤害计防御潜力，另用三种参考打法核对真实延长的战斗。", ""]
        elif e["id"] == "ragebound_brute":
            lines += ["每回合先增加2力量再攻击，因此首次攻击已获得2点增伤，力量持续本场战斗且不设上限。该成长机制允许突破普通敌人1.8 E；12行动峰值只是一段观测窗口，不是长期上限。生命限制决定它在真实战斗能完成多少次成长。", ""]
    lines += ["## 使用边界", "",
              "当前自动工具支持固定基础伤害、自身格挡、自身力量、对玩家虚弱/易伤，并复现状态首次跳过递减与后续延时规则。持续能力、治疗、格挡转伤害及其他特殊行动仍明确停止，需先补充对应结算；不会将未知效果当作零收益继续出分。", "",
              "不自动给Boss加倍率，不将最大生命并入行动分数，不修改资源。所有设计估值与实际游戏体验验证分别记录。", ""]
    (HERE / "当前敌人量化评估.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"完成{len(enemies)}种敌人：逐行动、第一循环、3/6/12行动状态窗口与{len(enemies)*len(PARAMS['player_profiles'])}组参考玩家结算。")


if __name__ == "__main__":
    main()
