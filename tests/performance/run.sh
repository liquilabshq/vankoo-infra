#!/usr/bin/env bash
# Ejecuta una prueba de k6 con Docker (sin instalar k6) y guarda el resumen en
# tests/performance/results/<prueba>-<fecha>.json.
#
# Uso: tests/performance/run.sh smoke|load|stress
#   Necesita K6_INVESTOR_EMAIL y K6_INVESTOR_PASSWORD; BASE_URL es opcional (por defecto AKS).
set -euo pipefail
test="${1:-smoke}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$dir/$test.js" ]] || { echo "No existe la prueba $test (smoke, load o stress)"; exit 1; }
: "${K6_INVESTOR_EMAIL:?Define K6_INVESTOR_EMAIL}" "${K6_INVESTOR_PASSWORD:?Define K6_INVESTOR_PASSWORD}"
mkdir -p "$dir/results"
stamp="$(date +%Y%m%d-%H%M)"
docker run --rm -i \
  -e K6_INVESTOR_EMAIL -e K6_INVESTOR_PASSWORD -e BASE_URL \
  -v "$dir:/scripts" -w /scripts \
  grafana/k6:2.3.0 run --summary-export "results/$test-$stamp.json" "$test.js"
echo "Resumen: tests/performance/results/$test-$stamp.json"
