"""只读提取当前 Godot 卡牌资源，重建本目录的模型报告；不修改游戏。"""
from __future__ import annotations

import hashlib
import json
import math
import re
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
TYPES = ["攻击", "技能", "能力", "武器"]
RARITIES = ["普通", "稀有", "史诗", "传说"]
PARAMS = json.loads((HERE / "模型参数.json").read_text(encoding="utf-8"))
SOURCE_FILES: set[Path] = set()


def number(value, digits=2, signed=False):
    rounded = Decimal(str(round(value, 10))).quantize(Decimal(1).scaleb(-digits), rounding=ROUND_HALF_UP)
    return format(rounded, ("+." if signed else ".") + str(digits) + "f")


def parse_value(value):
    value = value.strip()
    if value in ("true", "false"):
        return value == "true"
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1].replace(r"\n", "\n").replace(r'\"', '"')
    return value


def resource(path):
    path = path.resolve()
    SOURCE_FILES.add(path)
    content = path.read_text(encoding="utf-8-sig")
    headers = list(re.finditer(r"(?m)^\[([^\n]+)\]\s*$", content))
    sections = {}
    external = {}
    root = None
    for index, header in enumerate(headers):
        heading = header.group(1)
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', heading))
        body = content[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(content)]
        fields = list(re.finditer(r"(?m)^([\w/]+) = ", body))
        properties = {}
        for j, field in enumerate(fields):
            raw = body[field.end():fields[j + 1].start() if j + 1 < len(fields) else len(body)]
            properties[field.group(1)] = parse_value(raw)
        if heading == "resource":
            root = properties
        elif heading.startswith("sub_resource "):
            sections[attrs["id"]] = properties
        elif heading.startswith("ext_resource "):
            external[attrs["id"]] = attrs["path"]
    if root is None:
        raise ValueError(f"缺少根资源：{path}")
    return root, sections, external


def resolve_reference(value, sections, external):
    ref = re.fullmatch(r'(SubResource|ExtResource)\("([^"]+)"\)', value)
    if ref is None:
        raise ValueError(f"不支持的资源引用：{value}")
    kind, key = ref.groups()
    if kind == "SubResource":
        return dict(sections[key])
    target = external[key]
    if not target.startswith("res://"):
        raise ValueError(f"不支持的资源路径：{target}")
    return dict(resource(PROJECT / target[6:])[0])


def load_cards():
    cards = []
    for path in sorted((PROJECT / "cards/data").glob("*.tres")):
        root, sections, external = resource(path)
        effects = []
        if "effects" in root:
            match = re.search(r"\]\((.*)\)$", root["effects"], re.S)
            if not match:
                raise ValueError(f"不能读取 effects：{path}")
            refs = re.findall(r'(?:SubResource|ExtResource)\("[^"]+"\)', match.group(1))
            if not refs:
                raise ValueError(f"未解析到效果：{path}")
            for ref in refs:
                raw = resolve_reference(ref, sections, external)
                effect = {"effect_type": 0, "amount": 0, "target_type": 0,
                          "repeat_count": 1, "damage_source": 0,
                          "heals_from_damage": False, "durability_bonus": 0, **raw}
                if "power_definition" in effect:
                    effect["power"] = resolve_reference(effect["power_definition"], sections, external)
                effects.append(effect)
        weapon = None
        if "weapon_definition" in root:
            weapon = {"base_attack": 0, "base_max_durability": 1,
                      "break_destination": 0, "ignores_block": False,
                      "strength_on_attack": 0, "draw_on_attack": 0,
                      **resolve_reference(root["weapon_definition"], sections, external)}
        cards.append({
            "id": root["card_id"], "name": root["card_name"],
            "description": root["description"], "cost": root.get("base_energy_cost", 0),
            "type": root.get("card_type", 0), "rarity": root.get("rarity", 0),
            "exhaust": root.get("exhausts_on_play", False),
            "innate": root.get("is_innate", False), "retain": root.get("retains_on_turn_end", False),
            "source": path.relative_to(PROJECT).as_posix(), "effects": effects, "weapon": weapon,
        })
    ids = [card["id"] for card in cards]
    if len(ids) != len(set(ids)):
        raise ValueError("卡牌 ID 重复")
    return cards


def assess(card, scene):
    p, h = PARAMS, scene["turns"]
    discount = lambda turn: p["future_discount"] ** turn
    terms = []
    def add(label, value):
        terms.append({"label": label, "value": value})
    raw_direct = 0.0
    w = card["weapon"]
    if w:
        k = min(h, w["base_max_durability"])
        raw_direct = w["base_attack"] / p["damage_per_unit"]
        damage = sum((w["base_attack"] + i * w["strength_on_attack"]) * discount(i) for i in range(k))
        add(f"首个装备周期 {k} 次武器伤害（含本武器先前触发的力量）", damage / p["damage_per_unit"])
        draws = sum(discount(i) for i in range(k)) * w["draw_on_attack"]
        add("武器攻击抽牌", draws * p["draw_value"] * scene["draw_realization"])
        # 武器已损坏后力量仍持续；只计其他攻击的增量，不计那些攻击的基础伤害。
        other_damage = sum(min(i + 1, k) * w["strength_on_attack"] *
                           scene["attack_segments_per_turn"] * discount(i) for i in range(h))
        add("武器触发力量对后续其他攻击的增量", other_damage / p["damage_per_unit"])
        # 基准为无敌人格挡；无视格挡敏感性另列，不能凭空添加穿透固定溢价。
    missing_health = scene["missing_health"]
    for effect in card["effects"]:
        kind = effect["effect_type"]
        amount = effect["amount"] * effect["repeat_count"]
        if kind == 0:
            damage = scene["current_block"] if effect["damage_source"] == 1 else effect["amount"]
            damage *= effect["repeat_count"]
            raw_direct += damage / p["damage_per_unit"] if effect["damage_source"] == 0 else 0
            add("攻击伤害" if effect["damage_source"] == 0 else "按已有格挡造成伤害", damage / p["damage_per_unit"])
            if effect["heals_from_damage"]:
                healed = min(missing_health, scene["enemy_health"], max(0, damage - scene["enemy_block"]))
                add(f"实际治疗 {healed} 点", healed * p["healing_value"])
                missing_health -= healed
        elif kind == 1:
            raw_direct += amount / p["block_per_unit"]
            add("即时格挡", amount / p["block_per_unit"])
        elif kind == 2:
            add("抽牌选择价值", amount * p["draw_value"] * scene["draw_realization"])
        elif kind == 3:
            add("获得能量（费用在净值中另扣）", amount * scene["energy_realization"])
        elif kind == 4:
            ref = p["enhancement_reference"]
            attack, durability = ref["attack"], ref["remaining_durability"]
            before = sum(attack * discount(i) for i in range(min(h, durability)))
            after = sum((attack + effect["amount"]) * discount(i)
                        for i in range(min(h, durability + effect["durability_bonus"])))
            add("强化相对原武器的增量，不重复计原武器", (after - before) / p["damage_per_unit"])
        elif kind == 5:
            add("直接失血代价", -amount * p["health_loss_cost"])
        elif kind == 6:
            damage = amount * scene["attack_segments_per_turn"] * sum(discount(i) for i in range(h))
            add("力量对后续攻击段的增量", damage / p["damage_per_unit"])
        elif kind == 7:
            prevented = scene["incoming_attack"] - math.floor(scene["incoming_attack"] * 0.75)
            add("虚弱避免的攻击伤害", prevented * sum(discount(i) for i in range(min(amount, h))) / p["block_per_unit"])
        elif kind == 8:
            extra = math.floor(scene["outgoing_after_card"] * 1.5) - scene["outgoing_after_card"]
            add("易伤对施加后攻击的增量", extra * sum(discount(i) for i in range(min(amount, h))) / p["damage_per_unit"])
        elif kind == 9:
            power = effect["power"]
            power_type = power.get("power_type", 0)
            if power_type == 0:
                add("保留后确实被使用的新增格挡",
                    scene["new_carry_block_per_turn"] * scene["future_block_utilization"] *
                    sum(discount(i) for i in range(1, h)) / p["block_per_unit"])
            elif power_type == 1:
                each = power["block_gain"] * scene["future_block_utilization"] / p["block_per_unit"]
                each -= power["health_loss"] * p["health_loss_cost"]
                add("从下回合开始的格挡减失血", each * sum(discount(i) for i in range(1, h)))
            else:
                raise ValueError(f"未定价的能力类型：{power_type}")
        elif kind == 10:
            add("禁抽导致的后续抽牌损失", -scene["forgone_later_draw"] *
                p["draw_value"] * scene["draw_realization"])
        elif kind == 11:
            add("本局最大生命容量代价", -amount * p["max_health_capacity_cost"])
            clamp_loss = max(0, amount - missing_health)
            add("最大生命降低导致的当前生命压低", -clamp_loss * p["health_loss_cost"])
        elif kind == 12:
            add("随后攻击牌回能，不包括本牌与武器攻击",
                amount * scene["later_attack_cards"] * scene["energy_realization"])
        else:
            raise ValueError(f"未定价的效果类型：{kind}")
    value = sum(term["value"] for term in terms)
    return {"value": value, "net": value - card["cost"], "efficiency": value / card["cost"] if card["cost"] else None,
            "raw_direct": raw_direct, "terms": terms}


NOTES = {
    "strike": "锚点：6/6=1。高力量环境另按每段加成计算。",
    "defend": "锚点：5/5=1。当前表按全部格挡可用计，面对不攻击的敌人时实际价值更低。",
    "heavy_strike": "12/6=2，资源效率等于打击；把两次打击压进一张卡，节省一张手牌，但大费用降低灵活性。",
    "double_strike": "5×2/6=1.67。每点力量增加两段共2伤，基准比打击多4伤；相同总格挡下逐段扣盾本身没有额外穿透价值。",
    "attack_and_block": "4/6+3/5=1.27，攻防同时可用时略高于基准；不攻击的回合格挡部分会浪费。",
    "tactical_defense": "3/5+0.5=1.10；若抽牌的估值低于0.4，就低于1费基准。",
    "pommel_strike": "9/6+0.5=2.00；即使抽牌没有兑现，伤害部分仍是1.50。",
    "iron_wave": "5/6+5/5=1.83；双向价值依赖当回合确实需要格挡。",
    "shrug_it_off": "8/5+0.5=2.10，与战术防御费用相同却多5格挡；资源效率与牌效都明显高，但上限比较不等于所有局面都严格优越。",
    "trade_wounds": "12/6−0.25=1.75。它是技能，但伤害属于攻击伤害，吃力量/虚弱/易伤，不吃攻击牌回能；1生命时先失血致死，后续伤害为0。",
    "blood_sacrifice": "14/5−0.6=2.20；满生命时另减0.25的即时压低代价。文案里的“消耗1点最大生命”不是消耗词条，当前这张牌会正常弃置并可能再次抽到。",
    "overpower": "32/6=5.33，3费净超出2.33。无盾无状态下可击杀30生命敌人；Boss按实际生命与格挡另算，不能沿用旧40生命配置。临近击杀时按有效伤害折减超杀，当前战斗表现见综合数值模型。",
    "open_wound": "先造成8伤，再施加易伤；本牌8伤不享受本牌易伤。2层易伤基准增加6+5.1=11.1伤，含场景未来攻击预算，不是打出即造成。",
    "uppercut": "先13伤，再易伤/虚弱，本牌不自享易伤。标准局面加6伤与避免3伤，共13/6+6/6+3/5=3.77。",
    "thorns": "7/5+6/6=2.40；卡名并不表示反伤，当前真实效果只有7格挡与1层易伤。",
    "intimidate": "只提供易伤，没有独立基础伤害。现无易伤、后续有攻击才增值；标准三轮折现增伤15.435，折为2.57，短战只值0.5。消耗限制重用。",
    "technical_fighting": "标准为虚弱0.6×(1+0.85)+抽3×0.5=2.61；敌人防御回合、已有虚弱或禁抽/满手均会降低收益。",
    "strength_power": "2力量×未来每回合2段×(1+0.85+0.85²)/6=1.72。无倍率时未来至少3段攻击才回到1费；武器与多段攻击也计段。",
    "battle_trance": "0费先抽3，再禁抽。标准3×0.5−1×0.5=1.00；最后一张抽牌动作使用时可到1.50，抽后接嗜血长剑等会损失抽牌。",
    "ancient_ritual": "先付1再回3，真实净增2能量，不能在0能量时打出；标准表先计3，再扣1。必须有可打出的牌，消耗限制重复。",
    "blood_feast": "基础伤害10/6=1.67；标准缺6生命且敌人无盾，实际回血6×0.3=1.80，总3.47。治疗只看实际失血，完全格挡、超杀与满血都不能虚增治疗。",
    "endless_power": "0费伤害6/6=1，再按标准随后2张攻击牌回2能量，共3。第一张自身不回能；多张叠加要按出牌次序和旧额度计算，不能直接乘一个无限循环系数。",
    "fortress": "不会凭空产生格挡，也不恢复已被扣掉的格挡。只计每轮新增且以后确实用上的那一份结余，禁止把同一存量重复算多轮；零结余时价值0。",
    "blood_cloak": "当回合打出只注册；标准剩余2个开始触发，每次10×0.8/5−0.25=1.35，折现总2.12。生命不足致死时后续格挡/触发不可计。",
    "bloodthirsty_sword": "标准首次装备3击8+9+10；另抽3牌，并将获得的力量计入之后其他攻击的增量。本次攻击后才加力量，不能把第一击写成9。只比较无武器对照，换装已有武器时须扣旧武器放弃的收益。",
    "lethal_blade": "标准2击15伤，折现为15×(1+0.85)/6=4.63。无盾场景穿透溢价0；有盾价值须比较真实生命差，敌人格挡不被消耗，不能一律每击把同一面盾重复加分。",
    "eternity": "单次装备只计最多3击，标准9伤折现1.29；固有/保留不另给固定点数。可回手重装并保留强化，重装仍花1费且不刷新攻击机会，重复周期另见敏感性分析。",
    "war_god_blessing": "基准锚定永恒3攻击、剩1耐久；强化后11攻击、剩3耐久。标准增量[11×(1+0.85+0.85²)−3]/6=4.22；不重复计原武器的3伤，不计无装备时不能兑现的效果。",
    "shield_slam": "已有格挡X时为X/6，不消耗格挡；标准X=10→1.67，X=0→0。该格挡的取得费用记在生产格挡的牌上，不再给本牌增加一次格挡收益。",
}


def flag(result, cost):
    if cost == 0:
        return "零费收益；关注手牌与组合"
    net = round(result["net"], 10)
    if net >= 0.5:
        return "高于基础费用模型"
    if net > 0.1:
        return "略高于基础费用模型"
    if net <= -0.5:
        return "低于基础费用模型"
    if net < -0.1:
        return "略低于基础费用模型"
    return "接近基础费用模型"


def main():
    import sys
    sys.path.insert(0, str(PROJECT))
    from tools.history_guard import require_sandbox
    require_sandbox(PROJECT)
    cards = load_cards()
    results = [{"card": card, "scenarios": {s["id"]: assess(card, s) for s in PARAMS["scenarios"]}} for card in cards]
    by_id = {item["card"]["id"]: item for item in results}
    if set(by_id) != set(NOTES):
        raise ValueError(f"逐卡说明需同步。缺少：{set(by_id) - set(NOTES)}；多余：{set(NOTES) - set(by_id)}")
    for anchor in ("strike", "defend"):
        if not math.isclose(by_id[anchor]["scenarios"]["standard"]["value"], 1):
            raise ValueError(f"基准锚点偏离：{anchor}")
    for item in results:
        for outcome in item["scenarios"].values():
            if not math.isfinite(outcome["value"]):
                raise ValueError("评估值不是有限数")
            if not math.isclose(sum(t["value"] for t in outcome["terms"]), outcome["value"]):
                raise ValueError("分项加总不一致")
    SOURCE_FILES.update(PROJECT / name for name in (
        "cards/card_definition.gd", "battle/actions/combat_effect_definition.gd",
        "battle/actions/attack_damage_resolver.gd", "battle/model/battle_state.gd",
        "battle/model/combatant_state.gd", "battle/weapons/weapon_definition.gd",
        "battle/powers/power_definition.gd", "characters/data/warrior.tres"))
    snapshot = {
        "model_version": PARAMS["model_version"], "evaluation_date": PARAMS["evaluation_date"],
        "cards_count": len(cards), "parameters": PARAMS,
        "resource_hashes": {path.relative_to(PROJECT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in sorted(SOURCE_FILES)},
        "results": results,
    }
    (HERE / "评估数据.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# 卡牌量化评估",
        "",
        f'评估快照：{PARAMS["evaluation_date"]}；模型 v{PARAMS["model_version"]}。覆盖当前全部{len(cards)}张卡牌：当前基础2张＋角色池27张。数值以实际资源与代码为准。',
        "",
        "单位为标准费用 U。V 为收益减生命等代价，尚未扣出牌费用；N=V−费用；E=V/费用。短战、标准、长战是不同条件样例，不是统计置信区间。只计算一次出牌；武器计该次装备周期，能力计剩余窗口。表中直接值只含固定伤害/格挡，武器为第一击伤害；不含抽牌、状态或支付代价。",
        "",
        "所有费用与稀有度均来自现有资源。判定只表示相对基础锚点的资源效率，不表示该稀有度必须削弱或增强。",
        "逐卡说明中的示例数值采用初始v0.1参数；调整参数后，以重新计算的总表与分项表为准。",
        "",
        "| 卡牌 | 类型/稀有度 | 费用 | 直接值 | V短战 | V标准 | V长战 | N标准 | E标准 | 基准判断 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for item in sorted(results, key=lambda r: (r["card"]["rarity"], r["card"]["cost"], r["card"]["id"])):
        c, r = item["card"], item["scenarios"]
        standard = r["standard"]
        efficiency = number(standard["efficiency"]) if c["cost"] else "—"
        lines.append(f'| {c["name"]} | {TYPES[c["type"]]}/{RARITIES[c["rarity"]]} | {c["cost"]} | {number(standard["raw_direct"])} | {number(r["short"]["value"])} | {number(standard["value"])} | {number(r["long"]["value"])} | {number(standard["net"], signed=True)} | {efficiency} | {flag(standard, c["cost"])} |')
    lines += ["", "## 初步关注项", "",
              "- 直接数值最值得复核的是剑柄打击、耸肩无视、双重打击、以伤换伤、力量碾压；其中多张普通卡已明显超过基础锚点。",
              "- 战神祝福与嗜血长剑存在显著长线收益；必须结合装备位置、剩余回合、换装损失和攻击预算判断，不能把表中全部收益视为当回合爆发。",
              "- 坚城在没有剩余格挡时价值0；当前标准场景未达到2费价值，长战与高结余格挡配合才回本。",
              "- 最大生命牺牲与治疗影响整局生命经济；血祭可重复打出，应结合休整和后续战斗重新校准代价。",
              "- 无尽之力具有0费伤害与回能双重收益，要优先评估多张叠加、零费攻击与抽牌组合。",
              "", "## 逐卡拆解", ""]
    for item in sorted(results, key=lambda r: (r["card"]["rarity"], r["card"]["id"])):
        c, r = item["card"], item["scenarios"]
        flags = []
        if c["exhaust"]:
            flags.append("打出后消耗")
        if c["innate"]:
            flags.append("固有")
        if c["retain"]:
            flags.append("保留")
        if c["type"] == 2:
            flags.append("能力牌退出本场循环")
        lines += [f'### {c["name"]}', "",
                  f'资源：[源文件](../{c["source"]})。{c["cost"]}费，{TYPES[c["type"]]}，{RARITIES[c["rarity"]]}。' + ("词条：" + "、".join(flags) + "。" if flags else ""),
                  "", f'当前文案：{c["description"].replace(chr(10), " / ")}', "",
                  NOTES[c["id"]], "",
                  "| 标准局面分项 | 标准费用 U |", "| --- | ---: |"]
        for term in r["standard"]["terms"]:
            if term["value"]:
                lines.append(f'| {term["label"]} | {number(term["value"], 3, signed=True)} |')
        lines += [f'| 模型价值 V | {number(r["standard"]["value"], 3)} |',
                  f'| 出牌费用 | −{c["cost"]:.3f} |',
                  f'| 净值 N | {number(r["standard"]["net"], 3, signed=True)} |', "",
                  f'短战 / 标准 / 长战：{number(r["short"]["value"], 3)} / {number(r["standard"]["value"], 3)} / {number(r["long"]["value"], 3)} U。', ""]
    (HERE / "全卡牌量化评估.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"完成 {len(cards)} 张卡牌 × {len(PARAMS['scenarios'])} 个场景；两张基准锚点与所有分项加总通过核对。")


if __name__ == "__main__":
    main()
