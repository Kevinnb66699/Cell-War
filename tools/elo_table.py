import json, glob, os, math, sys
D=r"C:/Users/skyal/AppData/Roaming/Godot/app_userdata/Cell War"
pairs=[]; W={}
for path in glob.glob(os.path.join(D,"elo_*.jsonl")):
    bn=os.path.basename(path)[4:-6]  # e.g. heu_abs
    ia,ca=bn.split("_")[0],bn.split("_")[1]
    iw=cw=0
    for line in open(path,encoding="utf-8"):
        line=line.strip()
        if not line: continue
        o=json.loads(line)
        if o.get("outcome"):
            if o["winner"]==0: iw+=1
            elif o["winner"]==1: cw+=1
    total=iw+cw
    if total: W[(ia,ca)]=(iw,cw,total)   # ia(免)胜 iw 局, ca(癌)胜 cw 局
# 总计对局关系: A vs B 有2方向(A免B癌 + B免A癌)
print("%6s|"%(""), end="")
types=["heu","mech","mev","mel","abs"]
for t in types: print("%8s"%t, end="")
print()
ratings={t:1000.0 for t in types}
def expected(r2,r1): return 1.0/(1.0+10**((r2-r1)/400.0))
for _ in range(400):
    for (ia,ca),(iw,cw,tot) in W.items():
        # ia(免) identity=ia, ca(癌) identity=ca
        ea=expected(ratings[ca],ratings[ia])  # P(ca|免疫ia)
        for p in range(tot):
            pass
    break
# 简化: 直接累计(免胜=ia+1癌, 癌胜=ia-1癌)
for (ia,ca),(iw,cw,tot) in W.items():
    score=iw-cw
    ratings[ia]+=score; ratings[ca]-=score
mn=min(ratings.values())-1; mx=max(ratings.values())+1
for a in types:
    print("%-4s|"%a, end="")
    for b in types:
        if a==b: print("%8s"%"-", end="")
        else:
            res=W.get((a,b)) or W.get((b,a))
            if res:
                iw,cw,tot=res
                # a 在此配对的身份可能为免疫(a,b)或癌(b,a)
                if (a,b) in W: w,d,l=iw,cw,tot   # a免
                else: w,d,l=cw,iw,tot            # a癌 → a胜=癌胜数
                print("%7d-%d"%(w,l), end="")
            else: print("%8s%""-"", end="")
    print()
print("\n简化ELO(免胜+1/癌胜-1 累计):", {t:int(r) for t,r in sorted(ratings.items(), key=lambda x:-x[1])})
