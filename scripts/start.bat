@echo off
echo 🚀 Levantando infraestructura de Vankoo...
docker compose up -d
echo ✅ Servicios iniciados. Revisa Kafka UI en http://localhost:9000
pause