#!/usr/bin/env bash
# Se puede ejecutar desde cualquier carpeta: trabaja siempre sobre el
# docker-compose.yaml de la raíz de vankoo-infra.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
echo "🧹 Limpiando contenedores, redes y volúmenes..."
docker compose down -v
echo "✨ Sistema limpio."