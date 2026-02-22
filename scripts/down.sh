#!/bin/bash
echo "🧹 Limpiando contenedores, redes y volúmenes..."
docker compose down -v
echo "✨ Sistema limpio."