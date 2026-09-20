import json, math, glob, os, random

D = r"C:/Users/skyal/AppData/Roaming/Godot/app_userdata/Cell War"
ALL_LEVERS = ["ct","st","supply","ce","ie","ia","ca","hm","pt","lc","mie","level","mem"]

def load(prefix):
    games = {}
    for path in glob.glob(os.path.join(D, prefix + "*.jsonl")):
        if os.path.basename(path).startswith("evh_test"): continue
        tag = os.path.basename(path)
        for line in open(path, encoding="utf-8"):
            line=line.strip()
            if not line: continue
            o=json.loads(line); key=(tag,o["cfg"],o["gid"])
            games.setdefault(key,{"winner":None,"positions":[]})
            if o.get("outcome"): games[key]["winner"]=o["winner"]
            else: games[key]["positions"].append(o)
    return {k:v for k,v in games.items() if v["winner"] is not None and v["positions"]}

def sigmoid(z):
    if z>=0: return 1.0/(1.0+math.exp(-z))
    e=math.exp(z); return e/(1.0+e)
def log1p(v): return math.log(1.0+max(v,0.0))

# ---- 旧拟合公式(log版, 按当时全数据拟合原样, 含mie) —— 过期检测用 ----
OLD_B = 4.0552
OLD_W = {"level":2.0602,"ia":1.8128,"ct":-1.5817,"st":-1.3008,"ca":-0.9080,
         "hm":0.8470,"mie":-0.2755,"mem":0.2541,"ce":-0.2370,"lc":-0.2258,
         "pt":-0.1512,"supply":0.0639,"ie":0.0430}
def old_eval(v):
    e = OLD_B
    for k,w in OLD_W.items(): e += w*log1p(v[k])
    return e

def auc(y,p):
    pos=[p[i] for i in range(len(y)) if y[i]>=0.5]; neg=[p[i] for i in range(len(y)) if y[i]<0.5]
    if not pos or not neg: return 0.5
    s=0.0
    for a in pos:
        for b in neg: s+=1.0 if a>b else (0.5 if a==b else 0.0)
    return s/(len(pos)*len(neg))

def fit(X,y,l2=2.0,iters=380,lr=1.0):
    n=len(X); d=len(X[0]); mean=[0.0]*d; sd=[1.0]*d
    for j in range(d):
        col=[X[i][j] for i in range(n)]; m=sum(col)/n; var=sum((v-m)**2 for v in col)/n
        mean[j]=m; sd[j]=math.sqrt(var) if var>1e-9 else 1.0
    Xs=[[(X[i][j]-mean[j])/sd[j] for j in range(d)] for i in range(n)]
    w=[0.0]*d; b=0.0
    for _ in range(iters):
        gw=[0.0]*d; gb=0.0
        for i in range(n):
            err=sigmoid(b+sum(w[j]*Xs[i][j] for j in range(d)))-y[i]; gb+=err
            for j in range(d): gw[j]+=err*Xs[i][j]
        for j in range(d): w[j]-=lr*(gw[j]/n+l2*w[j]/n)
        b-=lr*gb/n
    return w,b,mean,sd

games = load("evh2_")
nw = sum(1 for v in games.values() if v["winner"]==0)
print("新平衡 总局数:",len(games)," 局面:",sum(len(v['positions']) for v in games.values()),
      " 免疫胜:",nw," 癌胜:",len(games)-nw," 癌胜率=%.2f"%(1-nw/len(games)), "（旧平衡癌胜率 0.23）")
# 按配置看癌胜率(新平衡哪里变强了)
per={}
for k,v in games.items():
    per.setdefault(k[1],[0,0]); per[k[1]][1]+=1
    if v["winner"]==1: per[k[1]][0]+=1
for cfg in sorted(per):
    print("  %-14s 癌胜 %d/%d = %.2f"%(cfg,per[cfg][0],per[cfg][1],per[cfg][0]/per[cfg][1]))

# ---- 过期检测: 旧公式在新平衡数据上的 AUC ----
ys=[];ps=[];ys3=[];ps3=[]
for k,v in games.items():
    y=1 if v["winner"]==0 else 0
    for vec in v["positions"]:
        ys.append(y); ps.append(sigmoid(old_eval(vec)))
        if vec["round"]<=3: ys3.append(y); ps3.append(sigmoid(old_eval(vec)))
print("\n=== 过期检测: 旧拟合公式在【新平衡】数据上 ===")
print("全盘 AUC=%.3f (旧平衡自测 0.830)   早回合r<=3 AUC=%.3f (旧 0.612)"%(auc(ys,ps),auc(ys3,ps3)))

# ---- 新平衡重拟合(log特征, 同清洗: 无wp/cm/mie) ----
LEVERS=[k for k in ALL_LEVERS if k!="mie"]
def feats(v): return [log1p(v[k]) for k in LEVERS]
keys=list(games.keys()); random.Random(7).shuffle(keys)
K=5; folds=[keys[i::K] for i in range(K)]
fold_w=[]; ys=[]; ps=[]; ys3=[]; ps3=[]
for f in range(K):
    test=set(folds[f]); train=[k for k in keys if k not in test]
    Xtr=[];ytr=[]
    for k in train:
        y=1 if games[k]["winner"]==0 else 0
        for vec in games[k]["positions"]: Xtr.append(feats(vec)); ytr.append(y)
    w,b,mean,sd=fit(Xtr,ytr); fold_w.append(w)
    for k in test:
        y=1 if games[k]["winner"]==0 else 0
        for vec in games[k]["positions"]:
            xs=[(feats(vec)[j]-mean[j])/sd[j] for j in range(len(LEVERS))]
            p=sigmoid(b+sum(w[j]*xs[j] for j in range(len(LEVERS))))
            ys.append(y); ps.append(p)
            if vec["round"]<=3: ys3.append(y); ps3.append(p)
print("\n=== 新平衡重拟合(log特征,5折CV) ===")
print("全盘 AUC=%.3f   早回合 AUC=%.3f"%(auc(ys,ps),auc(ys3,ps3)))
print("\n系数稳定性(标准化,5折) —— 重点看剥削项 lc/pt:")
print("%-8s %8s %6s"%("杠杆","均值w","同号/5"))
for j in range(len(LEVERS)):
    col=[fold_w[f][j] for f in range(K)]
    m=sum(col)/K; same=sum(1 for v in col if (v>0)==(m>0))
    tag=" ←剥削项" if LEVERS[j] in ("lc","pt") else ""
    print("%-8s %+8.3f %4d/5%s"%(LEVERS[j],m,same,tag))
# 全数据拟合 → 新公式(反标准化)
X=[];y=[]
for k,v in games.items():
    yy=1 if v["winner"]==0 else 0
    for vec in v["positions"]: X.append(feats(vec)); y.append(yy)
w,b,mean,sd=fit(X,y)
w_o=[w[j]/sd[j] for j in range(len(w))]; b_o=b-sum(w[j]*mean[j]/sd[j] for j in range(len(w)))
print("\n=== 新平衡估值公式 E2(s) = log-odds(免疫胜) ===")
print("E2(s) = %.4f"%b_o, end="")
for j in range(len(LEVERS)): print(" %+.4f*log(1+%s)"%(w_o[j],LEVERS[j]), end="")
print()
print("\n按|权重|排序:")
for j in sorted(range(len(LEVERS)), key=lambda j:-abs(w_o[j])):
    print("  %-8s %+.4f"%(LEVERS[j],w_o[j]))
