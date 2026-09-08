# -*- coding: utf-8 -*-
"""用自对弈数据回归 CWEval 的权重，并与现有手调权重比 AUC。

为什么用 AUC：当前平衡严重失衡（4 人局癌胜 81%、6 人局 1%），正负样本比例极端，
准确率会被类别先验带跑；AUC 只看排序能力 —— 而估值要的正是「把好局面排在前面」。
"""
import io, sys
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score

NAMES = ["cancer_tiles", "solid_tiles", "solid_progress", "has_base",
         "cancer_energy", "cancer_hand", "cancer_equip",
         "immune_energy", "immune_hand", "immune_equip", "immune_far",
         "memory", "level"]
## 现行手调权重（cw_eval.gd 的 WEIGHTS）
CUR = np.array([100, 200, 5, 400, 1, 12, 40, -1, -12, -40, 8, -25, -150], float)


def load(path):
    raw = np.genfromtxt(path, delimiter=",", skip_header=1)
    X = raw[:, :len(NAMES)]
    rnd = raw[:, len(NAMES)]
    y = raw[:, len(NAMES) + 1].astype(int)
    return X, rnd, y


def report(tag, path):
    X, rnd, y = load(path)
    print("\n==== %s ====" % tag)
    print("样本 %d 行｜正类（癌胜）%.1f%%" % (len(y), 100.0 * y.mean()))

    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.3, random_state=0, stratify=y)
    ## 现有权重的排序能力
    auc_cur = roc_auc_score(yte, Xte @ CUR)
    ## 学一组：特征量纲差很大（格数 ~100 vs has_base 0/1），先标准化再还原回原尺度
    mu, sd = Xtr.mean(0), Xtr.std(0) + 1e-9
    clf = LogisticRegression(max_iter=2000, C=1.0)
    clf.fit((Xtr - mu) / sd, ytr)
    w = clf.coef_[0] / sd                      ## 还原到原始特征尺度
    auc_new = roc_auc_score(yte, Xte @ w)
    print("AUC：现有手调 %.4f → 学出来的 %.4f（%+.4f）" % (auc_cur, auc_new, auc_new - auc_cur))

    ## 把学出来的权重缩放到「一格癌组织 = 100」的老量纲，方便和现值直接对照
    scale = 100.0 / w[0] if abs(w[0]) > 1e-12 else 1.0
    ws = w * scale
    print("%-16s %8s %10s" % ("特征", "现值", "学出(归一)"))
    for i, n in enumerate(NAMES):
        print("%-16s %8.0f %10.1f" % (n, CUR[i], ws[i]))
    return auc_cur, auc_new


if __name__ == "__main__":
    for tag, path in [("4 人局 ICIC", sys.argv[1]), ("6 人局 ICIICI", sys.argv[2])]:
        report(tag, path)
