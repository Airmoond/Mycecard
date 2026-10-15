"""从综合数据绘制两种牌组的生命对照图，不重算或修改资源。"""
import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
import sys
sys.path.insert(0, str(HERE.parent))
from tools.history_guard import require_sandbox
require_sandbox(HERE.parent)
os.environ.setdefault("MPLCONFIGDIR", str(HERE/".matplotlib-cache"))
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
from matplotlib.patches import Rectangle

data=json.loads((HERE/"综合评估数据.json").read_text(encoding="utf-8"))
params=data["parameters"]
font=FontProperties(fname="C:/Windows/Fonts/msyh.ttc")
lookup={tuple(row["key"]):row for row in data["groups"]}
fig,axes=plt.subplots(1,2,figsize=(13,5.6),layout="constrained")
for ax,label in zip(axes,("基础6张","参考9张")):
    rows=[[lookup[("sensitivity",label,hp,ehp)] for ehp in params["boss_health_grid"]] for hp in params["player_health_grid"]]
    values=[[item["remaining_fraction"]*100 for item in row] for row in rows]
    panel=ax.imshow(values,vmin=0,vmax=100,cmap="YlGn",aspect="auto")
    ax.set_title(label,fontproperties=font,fontsize=16,pad=12)
    ax.set_xticks(range(len(params["boss_health_grid"])),params["boss_health_grid"])
    ax.set_yticks(range(len(params["player_health_grid"])),params["player_health_grid"])
    ax.set_xlabel("Boss最大生命",fontproperties=font,fontsize=12)
    ax.set_ylabel("玩家起始及最大生命",fontproperties=font,fontsize=12)
    for i,row in enumerate(rows):
        for j,item in enumerate(row):
            ax.text(j,i,f"{item['win_rate']*100:.1f}%\n{item['remaining_health']:.1f}血",ha="center",va="center",fontproperties=font,fontsize=12,color="white" if item["remaining_fraction"]>.65 else "#183323")
    ax.add_patch(Rectangle((1.5,.5),1,1,fill=False,edgecolor="#da7c20",linewidth=3))
    ax.tick_params(labelsize=12)
bar=fig.colorbar(panel,ax=axes,shrink=.82,pad=.02)
bar.set_label("平均余血占起始上限（%）",fontproperties=font,fontsize=12)
fig.suptitle("玩家与Boss血量的共同影响\n每格：样本胜率／平均结算余血；橙框为当前50对99血",fontproperties=font,fontsize=18)
fig.savefig(HERE/"血量对照.png",dpi=160)
plt.close(fig)
print("已绘制血量对照.png")
