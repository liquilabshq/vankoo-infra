#!/usr/bin/env bash
# Detiene Vankoo en Azure sin borrar nada: las Container Apps y los PostgreSQL.
# Se conservan los datos y la URL del gateway. Para reanudar, azure-deploy.sh.
#
# Pensado para pausas de pocos días. Mientras está detenido siguen cobrando el
# registro de imágenes y el disco de cada PostgreSQL, y Azure vuelve a encender
# los PostgreSQL solos a los 7 días. Para pausas largas, azure-destroy.sh.
#
# Uso: scripts/azure/azure-stop.sh [--yes]
#   --yes  no pide confirmación aunque haya apps que pierdan sus datos
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    *) die "Opción desconocida: $arg" ;;
  esac
done

require_tools az
setup_terraform_env

# Una app sin disco persistente pierde sus datos al detenerse, y el resto del
# sistema quedaría incoherente (p. ej. facturas «en subasta» sin subasta).
ephemeral="$(vankoo_ephemeral_apps)"
if [[ -n "$ephemeral" ]]; then
  warn "Estas apps guardan sus datos solo en el contenedor y los perderán al detenerse:"
  printf '  %s\n' $ephemeral >&2
  warn "El resto conservará los suyos, así que el sistema puede quedar incoherente."
  if [[ "$YES" != true ]]; then
    read -r -p "¿Detener igualmente? Escribe 'si' para continuar: " answer
    [[ "$answer" == "si" ]] || die "Cancelado. Para empezar de cero, usa azure-destroy.sh."
  fi
fi

log "Deteniendo las Container Apps"
stop_container_apps

log "Deteniendo los PostgreSQL"
stop_postgres_servers

log "Vankoo detenido"
echo "Para reanudar: scripts/azure/azure-deploy.sh --env-file .env"
warn "Azure vuelve a encender los PostgreSQL solos a los 7 días y empiezan a cobrar."
