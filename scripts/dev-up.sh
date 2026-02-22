#!/bin/bash
echo "🚀 Levantando infraestructura de LiquiLabs..."
docker compose up -d
echo "✅ Servicios iniciados. Revisa Kafka UI en http://localhost:9000"