#!/usr/bin/env bash
# Shows what the cache-sim cross-check can catch: injects a replacement bug into a
# copy of rtl/dcache.sv and runs scripts/crosscheck.py on the C benchmark.
#   scripts/crosscheck_mutants.sh <cachesim> > results/7-crosscheck/mutants.csv
# Needs `make bench`. Prints crosscheck.py's CSV with a leading mutant column.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cachesim=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

declare -A sed_expr=(
  # A miss fills the last invalid way instead of the first.
  [last_invalid_way]='s|for (int w = WAYS - 1; w >= 0; w--) if (!valid\[set\]\[w\]) victim_c|for (int w = 0; w < WAYS; w++) if (!valid[set][w]) victim_c|'
  # A refilled line is not made most recently used.
  [fill_not_mru]="s|if (WAY_BITS'(w) == hit_way) age|if (replay) ; else if (WAY_BITS'(w) == hit_way) age|"
)

header=1
for mutant in last_invalid_way fill_not_mru; do
  rm -rf "$work"/*
  cp -r "$root/rtl" "$root/tb" "$root/scripts" "$work/"
  mkdir -p "$work/build"
  ln -s "$root/build/bench" "$work/build/bench"
  sed -i "${sed_expr[$mutant]}" "$work/rtl/dcache.sv"
  if cmp -s "$root/rtl/dcache.sv" "$work/rtl/dcache.sv"; then
    echo "$mutant: the edit no longer applies" >&2
    exit 1
  fi
  # crosscheck.py exits 1 on a difference, which is the point here.
  out=$(cd "$work" && python3 scripts/crosscheck.py --cachesim "$cachesim" \
    --cache 1,2,3 --cache 3,4,4 build/bench/bench.hex 2>/dev/null || true)
  if [ $header = 1 ]; then echo "mutant,$(echo "$out" | head -1)"; header=0; fi
  echo "$out" | tail -n +2 | sed "s/^/$mutant,/"
done
