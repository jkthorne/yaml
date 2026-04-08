#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR="${TMPDIR:-/tmp}"
STDLIB_BIN="$TMPDIR/yaml_bench_stdlib_$$"
PURE_BIN="$TMPDIR/yaml_bench_pure_$$"
STDLIB_OUT="$TMPDIR/yaml_bench_stdlib_$$.tsv"
PURE_OUT="$TMPDIR/yaml_bench_pure_$$.tsv"
trap 'rm -f "$STDLIB_BIN" "$PURE_BIN" "$STDLIB_OUT" "$PURE_OUT"' EXIT

echo "=== Comparison: Pure Crystal YAML vs stdlib (libyaml) ==="
echo ""

echo "Compiling stdlib benchmark..."
crystal build --release --no-debug -o "$STDLIB_BIN" "$SCRIPT_DIR/compare_stdlib.cr"

echo "Compiling pure Crystal benchmark..."
crystal build --release --no-debug -o "$PURE_BIN" "$SCRIPT_DIR/compare_pure.cr"

echo "Running benchmarks..."
echo ""

"$STDLIB_BIN" > "$STDLIB_OUT"
"$PURE_BIN"   > "$PURE_OUT"

format_ips() {
  local ips="$1"
  awk "BEGIN { v=$ips; if (v>=1000000) printf \"%.2fM\", v/1000000; else if (v>=1000) printf \"%.2fk\", v/1000; else printf \"%.1f\", v }"
}

format_mem() {
  local bytes="$1"
  awk "BEGIN { v=$bytes; if (v>=1048576) printf \"%.1f MiB\", v/1048576; else if (v>=1024) printf \"%.1f KiB\", v/1024; else printf \"%d B\", v }"
}

printf "%-18s %8s  %10s %10s  %10s %10s  %s\n" \
  "Fixture" "Size" "stdlib ips" "pure ips" "stdlib mem" "pure mem" "Ratio (ips)"
printf "%-18s %8s  %10s %10s  %10s %10s  %s\n" \
  "──────────────────" "────────" "──────────" "──────────" "──────────" "──────────" "───────────"

while IFS=$'\t' read -r name stdlib_ips stdlib_mem size; do
  IFS=$'\t' read -r _ pure_ips pure_mem _ <&3 || true

  stdlib_ips_fmt=$(format_ips "$stdlib_ips")
  pure_ips_fmt=$(format_ips "$pure_ips")
  stdlib_mem_fmt=$(format_mem "$stdlib_mem")
  pure_mem_fmt=$(format_mem "$pure_mem")
  ratio=$(awk "BEGIN { printf \"%.2fx\", $pure_ips/$stdlib_ips }")

  printf "%-18s %7s B  %10s %10s  %10s %10s  %s\n" \
    "$name" "$size" "$stdlib_ips_fmt" "$pure_ips_fmt" \
    "$stdlib_mem_fmt" "$pure_mem_fmt" "$ratio"
done < "$STDLIB_OUT" 3< "$PURE_OUT"

echo ""
echo "Ratio > 1.00x means pure Crystal is faster."
