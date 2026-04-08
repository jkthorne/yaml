#!/bin/bash
set -e

echo "=== Compiling and running benchmarks (--release) ==="
echo ""

for bench in parse scan emit roundtrip; do
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Running: ${bench}_bench.cr"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  crystal run --release "bench/${bench}_bench.cr"
  echo ""
done

echo "=== All benchmarks complete ==="
