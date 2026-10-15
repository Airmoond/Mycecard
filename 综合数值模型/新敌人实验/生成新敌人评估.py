"""汇总定稿资源的独立验证，保留训练与验证来源、逐样本胜负和示例轨迹。"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import math
from pathlib import Path
from statistics import mean

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def wilson(wins, n):
    p=wins/n; z=1.96; divisor=1+z*z/n
    center=(p+z*z/(2*n))/divisor
    width=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/divisor
    return [center-width,center+width]


def main():
    import sys
    sys.path.insert(0, str(ROOT))
    from tools.history_guard import require_sandbox
    require_sandbox(ROOT)
    raw=read(HERE/"验证数据.json")
    params=read(HERE/"校准参数.json")
    training=read(HERE/"训练数据.json")
    assert raw["settings"]==params and raw["failures"]==0
    assert params["training_seed_start"]+params["training_samples"] <= params["validation_seed_start"]
    for rel, expected in raw["source_hashes"].items():
        assert hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()==expected, f"验证来源过期：{rel}"
    selected={row["enemy_id"]:row for row in training["selected"]}
    model=read(ROOT/"敌人标准模型/评估数据.json")
    models={row["enemy"]["id"]:row for row in model["results"]}
    for rel, expected in model["resource_hashes"].items():
        assert hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()==expected, f"敌人模型过期：{rel}"
    spec=importlib.util.spec_from_file_location("full_model",HERE.parent/"生成综合评估.py")
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    results=[]
    for row in raw["results"]:
        outcomes=row["outcomes"]
        assert len(outcomes)==params["validation_samples"]
        assert models[row["enemy_id"]]["enemy"]["health"]==row["health"]==selected[row["enemy_id"]]["health"]
        assert 0 < row["health"] <= params["normal_health_soft_cap"] == 100
        enemy_actions=models[row["enemy_id"]]["enemy"]["actions"]
        if row["enemy_id"]=="bulwark_sentinel":
            assert [action["block"] for action in enemy_actions] == [7,selected[row["enemy_id"]]["later_block"],selected[row["enemy_id"]]["later_block"],0]
            assert [action["damage"] for action in enemy_actions] == [2,3,3,21]
        else:
            assert enemy_actions[0]["damage"]==selected[row["enemy_id"]]["base_attack"]
            if row["enemy_id"]=="hexbound_acolyte":
                assert [action["damage"] for action in enemy_actions] == [9,11]
        assert len({r["seed"] for r in outcomes})==len(outcomes)
        for i,record in enumerate(outcomes):
            assert record["seed"]==params["validation_seed_start"]+i
            assert record["deck"]==params["deck"]
            assert record["player_initial_health"]==params["player_health"]==50
            assert record["player_initial_max_health"]==params["player_max_health"]==50
            assert record["hp_deductions"]-record["positive_health_recovery"]==record["net_health_loss"]
            assert record["max_health_loss"]==0 and record["positive_health_recovery"]==0
            assert record["enemy_initial_health"]==row["health"]
            assert record["outcome"] in ("胜利","失败")
            assert record["victory"]==(record["remaining_enemy_health"]==0 and record["remaining_health"]>0)
        score=module.summary(outcomes)
        assert score["wins"]==row["wins"] and math.isclose(score["win_rate"],row["win_rate"])
        interval=wilson(row["wins"],len(outcomes))
        for example in row["examples"]:
            assert example["trace"][0]["start_health"]==50
            assert example["trace"][-1]["end_health"]==example["remaining_health"]
        results.append({**{key:value for key,value in row.items() if key not in ("outcomes","examples")},
                        "wilson_95":interval,"training":selected[row["enemy_id"]],
                        "mean_net_health_loss":score["net_health_loss"],"mean_enemy_remaining_health":score["enemy_remaining_health"],
                        "model":{"opening_direct":models[row["enemy_id"]]["opening_value"],
                                 "opening_pressure":models[row["enemy_id"]]["opening_pressure_value"],
                                 "12_action_peak":models[row["enemy_id"]]["peak_action_value"],
                                 "design_check":models[row["enemy_id"]]["design_check"]}})
    snapshot={"date":params["evaluation_date"],"parameters":params,"results":results,
              "training_origin":"retained_historical_selection; training metrics were not rerun by independent validation",
              "sample_count":int(sum(row["samples"] for row in results)),"source_hashes":raw["source_hashes"],
              "input_hashes":{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in (HERE/"校准参数.json",HERE/"训练数据.json",HERE/"验证数据.json",ROOT/"敌人标准模型/评估数据.json")}}
    (HERE/"新敌人评估数据.json").write_text(json.dumps(snapshot,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    lines=["# 三种普通敌人设计与约80%胜率校准","",f"日期：{params['evaluation_date']}。玩家50/50生命，3打击＋3防御，3能量、5抽、10手牌上限，玩家先手；无选牌、武器、藏品、奖励或休整。","",
           "独立复核使用现有代码与保留的定稿资源。训练列引用历史参数选择及历史训练指标，未在独立验证中重新调参；参数日期为原条件登记日期，实际重跑时间与来源见工具实验manifest。","",
           "目标不要求精确80%；冻结的意图贪心策略以独立样本约80%胜率为设计参考，75%～85%作比较带，超出时记录实际偏差，不作为固定阈值。它不是所有人类玩家的保证胜率；抽牌随机性与不同策略会改变结果。","",
           "## 定稿配置与独立验证","",
           "| 敌人 | 血量 | 基础牌组独立胜利 / 样本 | 胜率 | 95%区间 | 平均剩余血 | 平均玩家回合 | 训练胜率 |",
           "| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |"]
    by_id={row["enemy_id"]:row for row in results}
    guard=models["bulwark_sentinel"]
    guard_blocks=[a["block"] for a in guard["enemy"]["actions"]]
    guard_chip=[a["damage"] for a in guard["enemy"]["actions"]]
    hex_pattern=[action["damage"] for action in models["hexbound_acolyte"]["enemy"]["actions"]]
    for row in results:
        interval="～".join(f"{x*100:.1f}%" for x in row["wilson_95"])
        lines.append(f"| {row['name']} | {row['health']} | {row['wins']} / {int(row['samples'])} | {row['win_rate']*100:.1f}% | {interval} | {row['mean_remaining_health']:.2f} | {row['mean_turns']:.2f} | {row['training']['win_rate']*100:.1f}% |")
    outside=[row for row in results if not row['within_target_band']]
    if outside:
        lines += ["","超出75%～85%比较带："+"、".join(f"{row['name']} {row['win_rate']*100:.1f}%" for row in outside)+"。保留实际结果供试玩判断，优先满足普通敌人不超过100血与既定机制。"]
    lines += ["","均值包含失败样本的0血，回合包含末轮。表中95% Wilson区间只描述该抽样策略条件，不包含人类策略差异。初版训练记录与改进后的最终训练记录分开保留，验证种子不参与选择参数。","",
              "## 铁壁哨卫：三防一攻","",
              f"最大生命 **{by_id['bulwark_sentinel']['health']}**。四步循环：{guard_chip[0]}伤盾击＋{guard_blocks[0]}格挡 → {guard_chip[1]}伤盾击＋{guard_blocks[1]}格挡 → {guard_chip[2]}伤盾击＋{guard_blocks[2]}格挡 → {guard_chip[3]}伤重击，然后重复。首行动{guard['opening_value']:.3f} E，12行动窗口峰值{guard['peak_action_value']:.3f} E，首循环均值{guard['cycle_average']:.3f} E。","",
              "保留连续三回合防守、第四回合重击的节奏。前三轮少量盾击用于在100血以内形成持续压力；纯格挡方案在这个生命上限下过于容易。每次敌人回合开始清掉旧盾，格挡不会跨三轮累积；首个玩家回合没有预加盾。玩家应在防守轮寻找输出空档，在重击前安排防御。","",
              f"首行动{guard['opening_value']:.3f} E高于原先0.7±0.05的近似检查，因此模型如实标为起手偏差；行动峰值仍不超过普通1.8 E。该偏差是生命上限与目标胜率的权衡，未修改模型阈值掩盖。","",
              "## 咒缚侍徒：低基础伤害、交替短时减益","",
              f"最大生命 **{by_id['hexbound_acolyte']['health']}**。两步循环：先造成{hex_pattern[0]}基础伤，再施加1回合虚弱；下一步先施加1回合易伤，再造成{hex_pattern[1]}基础伤。真实攻击9 → 16 → 13 → 16 → 13，然后重复；易伤先上时影响当次攻击，虚弱则覆盖下一玩家回合。","",
              "虚弱使接下来一轮基础打击6→4，之后恢复6；易伤按首次跳过递减规则保留至下一次9基础攻击结束，该次取整为13。两种状态在各自间隔内消退，不长期累计层数。格挡和生命恢复数值不受虚弱影响。","",
              f"基础攻击9／11均低于12伤锚点，减益经实际倍率与取整结算。首行动直接{by_id['hexbound_acolyte']['model']['opening_direct']:.3f} E；参考压力另计下一均衡回合两张打击少造成4伤的防御潜力0.4 E。不可重复加入已经计入实际伤害的易伤收益。峰值与参考压力详见敌人模型。","",
              "## 狂怒蛮兵：持续强化","",
              f"最大生命 **{by_id['ragebound_brute']['health']}**。每次行动先增加2力量，再进行一次基础{int(by_id['ragebound_brute']['training']['base_attack'])}伤攻击；首攻为基础＋2，后续每次再加2，没有上限。","",
              "力量只属于本场状态，新战斗归零。持续成长允许突破1.8 E，作为行动预算例外单独记录；当前血量决定基础牌组能否在攻击继续变强前击杀它。对应逐轮伤害和3／6／12窗口见[敌人标准评估](../../敌人标准模型/当前敌人量化评估.md)。","",
              "## 校准方法","",
              f"粗搜每条件{params['coarse_samples']}种子，精调每条件{params['training_samples']}种子，调血量及允许的攻击数字；保持既有贪心出牌策略。验证从{params['validation_seed_start']}开始，每敌人{params['validation_samples']}个不重叠种子，读取正式资源，不再修改参数。","",
              "普通敌人的设计偏好设为尽量不超过100血后，169／235血方案已淘汰；历史训练只保留审查。最终通过防守轮少量盾击、减益频率与生命数字校准，三种正式资源均≤100血；使用冻结策略与完整战斗观察窗口。逐样本保留胜负、余血、回合、实际打出牌；每敌人另存完整示例轨迹。","",
              "## 试玩与后续","",
              "在Godot中打开[敌人试炼场景](./敌人试炼.tscn)，按F6运行，选择三种敌人之一即可用基础6张和50生命手动对战；胜负后可返回选择。三份敌人与遭遇资源已可复用。当前立绘沿用旧资源作占位，正式敌人美术尚待制作。","",
              "试玩应观察：哨卫是否有足够反击空档；减益提示和同轮易伤攻击是否容易理解；蛮兵是否能促使玩家及时进攻。开局带额外三张构筑卡的胜率可能更高，约80%目标只用于指定基础牌组场景。","",
              "## 机制检查","",
              "相关[敌人机制测试](../../tests/new_enemy_mechanics_test.gd)和[试炼入口测试](../../tests/new_enemy_trial_test.gd)。覆盖行动预览与结算、三防一重击、旧盾清空、减益时序、持续力量增长、资源保持只读、基础牌组与切换战斗重置。","",
              "新敌人3000场独立验证无窗口耗尽或生命账目异常；主综合中两种原有敌人的独立基线与当前随机分支路线分别记录，详见[综合量化评估](../综合量化评估.md)。评估器对回合停滞设置退出检查；实际难度仍需结合试玩。","",
              "## 文件与复算","",
              "- [校准参数](./校准参数.json)、[训练数据](./训练数据.json)、[独立验证数据](./验证数据.json)、[量化汇总](./新敌人评估数据.json)。",
              "- [校准脚本](./校准敌人.gd)只修改复制资源；[验证脚本](./验证新敌人.gd)只读定稿资源；[汇总工具](./生成新敌人评估.py)检查来源与生命账目。",
              "- [模型及运行说明](./README.md)包含命令与限制。",""]
    (HERE/"三种普通敌人设计.md").write_text("\n".join(lines),encoding="utf-8")
    print(f"三敌人已核对：{snapshot['sample_count']}个独立样本，来源、牌组、生命账目与100血上限通过；{len(results)-len(outside)}/3进入75%～85%比较带。")


if __name__=="__main__":
    main()
