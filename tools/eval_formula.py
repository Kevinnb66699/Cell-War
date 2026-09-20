import json, math, glob, os, random

D = r"C:/Users/skyal/AppData/Roaming/Godot/app_userdata/Cell War"
LEVERS = ["ct","st","supply","ce","ie","ia","ca","hm","pt","lc","mie","level","mem"]  # 删 wp(=ct+2st) 和 cm(=常数-hm): 数学共线剔除

def load():
    games = {}
    for path in glob.glob(os.path.join(D, "evh_*.jsonl")):
        if os.path.basename(path)=="evh_test.jsonl": continue   # 排除管道冒烟测试
        tag=os.path.basename(path)                              # 键加文件名: 同cfg不同seed不撞车
        for line in open(path, encoding="utf-8"):
            line=line.strip()
            if not line: continue
            o=json.loads(line); key=(tag,o["cfg"],o["gid"])
            if o.get("outcome"):
                games.setdefault(key,{"winner":None,"positions":[]}); games[key]["winner"]=o["winner"]
            else:
                games.setdefault(key,{"winner":None,"positions":[]}); games[key]["positions"].append(o)
    return {k:v for k,v in games.items() if v["winner"] is not None and v["positions"]}

games=load()
nw=sum(1 for v in games.values() if v["winner"]==0)
print("总局数:",len(games)," 局面数:",sum(len(v["positions"]) for v in games.values()),
      " 免疫胜:",nw," 癌胜:",len(games)-nw," 免疫胜率=%.2f"%(nw/len(games)))

def sigmoid(z):
    if z>=0: return 1.0/(1.0+math.exp(-z))
    e=math.exp(z); return e/(1.0+e)
def log1p(v): return math.log(1.0+max(v,0))
def feats(vec): return [log1p(vec[k]) for k in LEVERS]

def fit(X,y,l2=2.0,iters=380,lr=1.0):
    n=len(X); d=len(X[0])
    mean=[0.0]*d; sd=[1.0]*d
    for j in range(d):
        col=[X[i][j] for i in range(n)]; m=sum(col)/n
        var=sum((v-m)**2 for v in col)/n; mean[j]=m; sd[j]=math.sqrt(var) if var>1e-9 else 1.0
    Xs=[[(X[i][j]-mean[j])/sd[j] for j in range(d)] for i in range(n)]
    w=[0.0]*d; b=0.0
    for _ in range(iters):
        gw=[0.0]*d; gb=0.0
        for i in range(n):
            z=b+sum(w[j]*Xs[i][j] for j in range(d)); err=sigmoid(z)-y[i]; gb+=err
            for j in range(d): gw[j]+=err*Xs[i][j]
        inv=lr/n
        for j in range(d): w[j]-=inv*(gw[j]+l2*w[j])
        b-=lr*gb/n
    return w,b,mean,sd

def auc(y,p):
    pos=[p[i] for i in range(len(y)) if y[i]>=0.5]; neg=[p[i] for i in range(len(y)) if y[i]<0.5]
    if not pos or not neg: return 0.5
    wsum=0.0
    for a in pos:
        for b in neg:
            wsum+=1.0 if a>b else (0.5 if a==b else 0.0)
    return wsum/(len(pos)*len(neg))

def evalvalue(w,b,mean,sd,x):
    return b+sum(w[j]*(x[j]-mean[j])/sd[j] for j in range(len(x)))

# ---- 5折CV: AUC + 每折系数稳定性 ----
keys=list(games.keys()); random.Random(7).shuffle(keys)
K=5; folds=[keys[i::K] for i in range(K)]
fold_w=[]; ys=[]; ps=[]; ys3=[]; ps3=[]
for f in range(K):
    test=set(folds[f]); train=[k for k in keys if k not in test]
    Xtr=[];ytr=[]
    for k in train:
        y=1 if games[k]["winner"]==0 else 0
        for v in games[k]["positions"]: Xtr.append(feats(v)); ytr.append(y)
    w,b,mean,sd=fit(Xtr,ytr); fold_w.append(w)
    for k in test:
        y=1 if games[k]["winner"]==0 else 0
        for v in games[k]["positions"]:
            p=sigmoid(evalvalue(w,b,mean,sd,feats(v)))
            ys.append(y); ps.append(p)
            if v["round"]<=3: ys3.append(y); ps3.append(p)
print("\n=== logmult 5折CV ===")
print("全盘 AUC=%.3f   早回合r<=3 AUC=%.3f"%(auc(ys,ps), auc(ys3,ps3)))

# 系数稳定性(标准化系数, 跨折可比): 报告均值 + 同号折数
print("\n=== 系数稳定性(标准化, 5折) ===")
print("%-8s %8s %6s"%("杠杆","均值w","同号/5"))
for j in range(len(LEVERS)):
    col=[fold_w[f][j] for f in range(K)]
    m=sum(col)/K
    same=sum(1 for v in col if (v>0)==(m>0))
    print("%-8s %+8.3f %4d/5"%(LEVERS[j],m,same))

# ---- 全数据拟合 → 最终公式(反标准化, 可直接用) ----
X=[];y=[]
for k,v in games.items():
    yy=1 if v["winner"]==0 else 0
    for vec in v["positions"]: X.append(feats(vec)); y.append(yy)
w,b,mean,sd=fit(X,y)
# 反标准化: E = b' + sum w'_j*log(1+lever_j)
w_orig=[w[j]/sd[j] for j in range(len(w))]
b_orig=b - sum(w[j]*mean[j]/sd[j] for j in range(len(w)))
print("\n=== 估值公式(全数据拟合, log-odds 免疫胜) ===")
print("E(s) = %.4f"%b_orig, end="")
for j in range(len(LEVERS)):
    print(" %+.4f*log(1+%s)"%(w_orig[j],LEVERS[j]), end="")
print()
print("\n按 |权重| 排序:")
for j in sorted(range(len(LEVERS)), key=lambda j:-abs(w_orig[j])):
    print("  %-8s %+.4f"%(LEVERS[j],w_orig[j]))
