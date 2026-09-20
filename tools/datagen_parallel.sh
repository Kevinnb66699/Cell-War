#!/bin/bash
## 并行分片数据采集：K 个 Godot headless 进程同时跑不同种子，吃满 CPU，最后自动合并。
## 用法: bash tools/datagen_parallel.sh <配置串> <每片局数> <片数> <种子基> <输出前缀>
##   配置串形如 "abs/abs/4" = immune_ai/cancer_ai/players
## 例: bash tools/datagen_parallel.sh abs/abs/4 4 8 50000 evh5_ss4
set -e
CFG="${1:?配置串 immune/cancer/players}"; GAMES="${2:-4}"; SHARDS="${3:-8}"; SEED="${4:-50000}"; OUT="${5:-evh5_x}"
G="C:/Users/skyal/Desktop/Godot/Godot_v4.5.2-stable_win64_console.exe"
PROJ="C:/Users/skyal/Desktop/cellwar/Cell-War"
IA="${CFG%%/*}"; REST="${CFG#*/}"; CA="${REST%%/*}"; P="${REST##*/}"
D="C:/Users/skyal/AppData/Roaming/Godot/app_userdata/Cell War"
echo "并行: ${SHARDS} 片 x ${GAMES} 局  ${IA}(免) vs ${CA}(癌) ${P}人  种子基 ${SEED}"
pids=()
for s in $(seq 0 $((SHARDS-1))); do
  f="${OUT}_s${s}.jsonl"
  rm -f "$D/$f"
  "$G" --headless --path "$PROJ/game" --script res://tests/mech_eval_health.gd -- \
      games=$GAMES players=$P immune_ai=$IA cancer_ai=$CA seed=$((SEED + s*1000)) out="$f" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
## 合并
cat "$D"/${OUT}_s*.jsonl > "$D/${OUT}.jsonl" 2>/dev/null
lines=$(wc -l < "$D/${OUT}.jsonl")
echo "合并完成: ${OUT}.jsonl  ${lines} 行"
