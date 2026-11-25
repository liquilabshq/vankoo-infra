#!/usr/bin/env bash
# Crea (o actualiza) la capa terraform/email: Azure Communication Services con un
# dominio administrado por Azure, para que Notification e IAM envíen correos reales.
# Después, scripts/aks/aks-deploy.sh la detecta y configura los servicios.
#
# Uso: scripts/aks/aks-email.sh [--yes] [--destroy]
#   --yes      no pide confirmación en Terraform
#   --destroy  borra la capa (los servicios vuelven a Mailpit con el siguiente aks-deploy.sh)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=(); DESTROY=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=(--yes) ;;
    --destroy) DESTROY=true ;;
    *) die "Opción desconocida: $arg" ;;
  esac
done

require_tools az terraform
setup_terraform_env
check_providers Microsoft.Communication

if [[ "$DESTROY" == true ]]; then
  tf_destroy email ${YES[@]+"${YES[@]}"}
  exit 0
fi
tf_apply email ${YES[@]+"${YES[@]}"}
log "Correo listo"
echo "Remitente: $(tf_output email sender_address)"
echo "Siguiente: scripts/aks/aks-deploy.sh (pone el proveedor acs en Notification e IAM)"
