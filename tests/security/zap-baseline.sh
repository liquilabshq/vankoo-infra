#!/usr/bin/env bash
# DAST con OWASP ZAP (sección 4.4.4): escaneo base (pasivo) de la web MYPE y de la API.
# El escaneo base solo navega y observa las respuestas (cabeceras, cookies, contenido);
# no ataca. Deja los informes en tests/security/results/.
#
# Uso: tests/security/zap-baseline.sh [url]
#   url  por defecto el despliegue de AKS
set -euo pipefail
target="${1:-https://vankoo-liquilabs.centralus.cloudapp.azure.com}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$dir/results"
chmod 777 "$dir/results"   # el contenedor de ZAP escribe con su propio usuario
stamp="$(date +%Y%m%d-%H%M)"
# -j: también el spider AJAX (la web es una SPA de React); -m 3: 3 min de spider.
# -c: reglas a ignorar o ajustar (rules.tsv, con la justificación de cada una).
# El código de salida de ZAP es 1 con fallos y 2 con avisos: no corta el script.
set +e
docker run --rm -v "$dir:/zap/wrk:rw" zaproxy/zap-stable:2.17.0 \
  zap-baseline.py -t "$target" -j -m 3 -c rules.tsv \
  -r "results/zap-baseline-$stamp.html" -J "results/zap-baseline-$stamp.json" -I
status=$?
set -e
echo "Informe: tests/security/results/zap-baseline-$stamp.html (código $status)"
