#!/usr/bin/env bash
# Se puede ejecutar desde cualquier carpeta: trabaja siempre sobre el
# docker-compose.yaml de la raíz de vankoo-infra.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
echo "🚀 Levantando infraestructura de Vankoo..."
docker compose up -d
echo "✅ Servicios iniciados. Revisa Kafka UI en http://localhost:9000"