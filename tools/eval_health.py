import json, math, glob, os, random

D = r"C:/Users/skyal/AppData/Roaming/Godot/app_userdata/Cell War"
LEVERS = ["wp","ct","st","supply","ce","ie","ia","ca","hm","cm","pt","lc","mie","level","mem"]

def load():
    games = {}   # (cfg,gid) -> {"winner":int,"positions":[vec,...]}
    for path in glob.glob(os.path.join(D, "evh_*.jsonl")):
        for line in open(path, encoding="utf-8"):
            line=line.strip()
            if not line: continue
            o=json.loads(line)
            key=(o["cfg"],o["gid"])
            if o.get("outcome"):
                games.setdefault(key,{"winner":o["winner"],"positions":[]})
                games[key]["winner"]=o["winner"]
            else:
                games.setdefault(key,{"winner":None,"positions":[]})
                games[key]["positions"].append(o)
    return games

games = load()
# 只保留有结局的局
games = {k:v for k,v in games.items() if v["winner"] is not None and v["positions"]}
print("总局数:", len(games), " 总局面数:", sum(len(v["positions"]) for v in games.values()))
nw = sum(1 for v in games.values() if v["winner"]==0)
print("免疫胜局:", nw, " 癌胜局:", len(games)-nw, " 免疫胜率=%.2f"%(nw/len(games)))

# ---- 纯 python 逻辑回归 ----
def sigmoid(z):
    if z>=0: return 1.0/(1.0+math.exp(-z))
    e=math.exp(z); return e/(1.0+e)

def fit_logreg(X, y, l2=1.0, iters=450, lr=1.0):
    n=len(X); d=len(X[0])
    # 标准化
    mean=[0.0]*d; sd=[1.0]*d
    for j in range(d):
        col=[X[i][j] for i in range(n)]
        m=sum(col)/n; var=sum((v-m)**2 for v in col)/n
        mean[j]=m; sd[j]=math.sqrt(var) if var>1e-9 else 1.0
    Xs=[[ (X[i][j]-mean[j])/sd[j] for j in range(d)] for i in range(n)]
    w=[0.0]*d; b=0.0
    for it in range(iters):
        gw=[0.0]*d; gb=0.0
        for i in range(n):
            z=b+sum(w[j]*Xs[i][j] for j in range(d))
            p=sigmoid(z); err=p-y[i]
            gb+=err
            for j in range(d): gw[j]+=err*Xs[i][j]
        for j in range(d): w[j]-=lr*(gw[j]/n + l2*w[j]/n)
        b-=lr*gb/n
    return w,b,mean,sd

def predict(w,b,mean,sd,X):
    out=[]
    for x in X:
        xs=[(x[j]-mean[j])/sd[j] for j in range(len(x))]
        out.append(sigmoid(b+sum(w[j]*xs[j] for j in range(len(x)))))
    return out

def logloss(y,p):
    eps=1e-9; s=0.0
    for i in range(len(y)):
        pi=min(max(p[i],eps),1-eps)
        s+= -(y[i]*math.log(pi)+(1-y[i])*math.log(1-pi))
    return s/len(y)

def acc(y,p,thr=0.5):
    return sum(1 for i in range(len(y)) if (p[i]>=thr)==(y[i]>=0.5))/len(y)

def auc(y,p):
    # Mann-Whitney：胜局面平均高于负局面的概率（排序质量，不受基准率影响）
    pos=[p[i] for i in range(len(y)) if y[i]>=0.5]
    neg=[p[i] for i in range(len(y)) if y[i]<0.5]
    if not pos or not neg: return 0.5
    wins=0.0
    for a in pos:
        for b in neg:
            if a>b: wins+=1.0
            elif a==b: wins+=0.5
    return wins/(len(pos)*len(neg))

def log1p(v): return math.log(1.0+max(v,0))

def feats(vec, kind):
    L={k:vec[k] for k in LEVERS}
    base=[L[k] for k in LEVERS]
    if kind=="current_eval":      # 现行固定线性估值(全局部分): ie-ce-supply-wp+mem
        return [L["ie"]-L["ce"]-L["supply"]-L["wp"]+L["mem"]]
    if kind=="linear":
        return base
    if kind=="logmult":           # 乘区: log(1+lever)
        return [log1p(v) for v in base]
    if kind=="phase":             # 线性 + 相位onehot交互(关键杠杆×相位)
        ph=vec["phase"]
        one=[1.0 if ph==0 else 0.0, 1.0 if ph==1 else 0.0, 1.0 if ph==2 else 0.0]
        key=[L["supply"],L["wp"],L["ie"],L["level"],L["lc"]]
        inter=[]
        for kv in key:
            for o in one: inter.append(kv*o)
        return base+inter
    if kind=="interact":          # 乘区交叉项: 权重随其它杠杆现有值变
        return base+[
            L["level"]*L["mem"],      # 升级门槛进度
            L["wp"]*L["supply"],      # 地盘×经济
            L["ie"]*L["pt"],          # 免疫能量×压迫(生存挤压)
            L["mie"]*L["pt"],         # 最弱免疫×压迫(生存门)
            L["lc"]*L["cm"],          # 斩杀×封髓
            L["ca"]*L["ce"],          # 癌兵力×能量
            log1p(L["mie"]),          # 生存门非线性
        ]
    return base

def evaluate(kind, maxround=None):
    keys=list(games.keys())
    random.Random(42).shuffle(keys)
    K=5; folds=[keys[i::K] for i in range(K)]
    ys=[]; ps=[]
    for f in range(K):
        test=set(folds[f]); train=[k for k in keys if k not in test]
        Xtr=[];ytr=[];Xte=[];yte=[]
        for k in train:
            y=1 if games[k]["winner"]==0 else 0
            for v in games[k]["positions"]:
                Xtr.append(feats(v,kind)); ytr.append(y)
        for k in test:
            y=1 if games[k]["winner"]==0 else 0
            for v in games[k]["positions"]:
                if maxround and v["round"]>maxround: continue
                Xte.append(feats(v,kind)); yte.append(y)
        w,b,mean,sd=fit_logreg(Xtr,ytr)
        ps+=predict(w,b,mean,sd,Xte); ys+=yte
    return logloss(ys,ps), acc(ys,ps), auc(ys,ps)

# 基准：全猜多数类
base_p=sum(1 for v in games.values() if v["winner"]==0)/len(games)
print("\n=== 各标量化结构 5折交叉验证(按局) ===")
print("基准(全猜免疫): acc=%.3f auc=0.500"%(base_p))
print("%-14s %-22s %-22s"%("模型","全盘(logloss/acc/auc)","仅早回合r<=3(auc)"))
for kind in ["current_eval","linear","logmult","phase","interact"]:
    ll,a,au=evaluate(kind)
    _,_,au3=evaluate(kind, maxround=3) if kind in ("current_eval","linear","logmult") else (0,0,0.0)
    print("%-14s %.4f / %.3f / %.3f        auc(r<=3)=%.3f"%(kind,ll,a,au,au3))

# 逐杠杆系数(全数据拟合 linear / logmult)，看数据说哪些杠杆重要
print("\n=== 逐杠杆标准化系数(全数据拟合) ===")
for kind in ["linear","logmult"]:
    X=[];y=[]
    for k,v in games.items():
        yy=1 if v["winner"]==0 else 0
        for vec in v["positions"]:
            X.append(feats(vec,kind)); y.append(yy)
    w,b,mean,sd=fit_logreg(X,y,l2=2.0)
    order=sorted(range(len(w)), key=lambda j:-abs(w[j]))
    names=LEVERS if kind=="linear" else ["log_%s"%k for k in LEVERS]
    print("-- %s 权重(top) --"%kind)
    for j in order[:8]:
        print("   %-10s %+.3f"%(names[j], w[j]))
