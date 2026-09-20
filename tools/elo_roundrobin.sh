#!/bin/bash
## ELO 循环赛驱动器：变体对变体互打（互为免疫/癌），并行分片，出 ELO + 两两胜率表。
## 用法: bash tools/elo_roundrobin.sh <每对的每侧局数> <人均胜/侧> <种子基>
##   <每对的每侧局数>=每场(免疫侧A癌侧B)局数 ; 每场x2方向(互换免疫/癌)
set -e
GAMES="${1:-4}"
PERMATCH="${2:-4}"   # 交叉方向(AB + BA) = 每侧 games 局 → 一场共 2*GAMES 局分2批次
SEED="${3:-60000}"
cd "C:/Users/skyal/Desktop/cellwar/Cell-War"
G="C:/Users/skyal/Desktop/Godot/Godot_v4.5.2-stable_win64_console.exe"
TYPES="heu mech mev mel abs"
D="C:/Users/skyal/AppData/Roaming/Godot/app_userdata/Cell War"
declare -A WINS; declare -A GAMESN; declare -A PIR;
n=0
for ia in $TYPES; do for ca in $TYPES; do
  [ "$ia" = "$ca" ] && : || {   # 互为对方(同变体互打并入ELO靠GAMESN统计)
  echo ">> 场次 n=$n  $ia(免) vs $ca(癌)  x ${GAMES}"
  fh="${ia}_${ca}"; f2="${ca}_${ia}"
  bash "$PWD/tools/datagen_parallel.sh" "$ia/$ca/4" "$GAMES" "$PERMATCH" $((SEED + n*1000)) "elo_$fh" >/dev/null
  ;
}
  n=$((n+1))
done; done
echo "循环赛完成"