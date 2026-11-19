#!/usr/bin/env bash
# Interleaved benchmark runner: round 0 is a discarded warmup, then REPS timed
# rounds. Within a round the two drivers alternate who goes first, so slow
# drift (thermal, page cache, autovacuum) hits both equally.
#
#   bench/run.sh            # 7 reps
#   REPS=3 bench/run.sh
set -euo pipefail
cd "$(dirname "$0")"
REPS="${REPS:-7}"
out=raw.jsonl
: > "$out"
for round in $(seq 0 "$REPS"); do
  if (( round % 2 == 0 )); then order="mjollnir pg"; else order="pg mjollnir"; fi
  for drv in $order; do
    ./bench_$drv | sed "s/^{/{\"round\":$round,\"driver\":\"$drv\",/" >> "$out"
  done
  echo "round $round done" >&2
done
python3 aggregate.py
