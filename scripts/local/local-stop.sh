#!/usr/bin/env bash
# Se puede ejecutar desde cualquier carpeta: trabaja siempre sobre el
# docker-compose.yaml de la raíz de vankoo-infra.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
echo "🛑 Deteniendo servicios..."
docker compose stop
echo "✅ Servicios detenidos."