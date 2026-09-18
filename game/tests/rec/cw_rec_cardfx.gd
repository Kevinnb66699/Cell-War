## cw_rec_cardfx.gd —— CWCardFx 的录制代理（测试迁移规格 A-4 / C-1 步 13）
##
## **今天一个覆写都没有，这是对的，不是漏了。**
## `l0_contract_gate.gd:recorder_overrides()` 给的 24 条 `gd` 字段里没有一条的文件是 cw_card_fx.gd：
## 卡牌结算整族属于 T 族（「没有自己的 op 名，恒为它所属的那个契约步名 + /trace」，§0.3），
## 而 §0.3 的点名禁入清单（_radiotherapy / _tnf / _lactic_acid / _clonal_growth / _remodel /
## _mutation_label / _chaos / _chaos_return / _resolve）正是这个文件最容易被「顺手」覆写的那一批 —— 一条都不进。
##
## 类留着有两个理由：① 批 5 的卡牌步真要进契约面时，它有现成的落点；
## ② 规矩 1 的双射是对**四个代理的并集**做的，这里贡献一个空集合，断言照样成立。
## 往这里加覆写之前，先去 PRD 给那一步一个步号（§0.3 的唯一一条路）。
extends CWCardFx

var rec
