#!/usr/bin/env bash
# Borra el clúster de AKS entero (capa terraform/aks): nodos, discos de las bases
# y balanceador. Los datos de Vankoo en el clúster se pierden. No toca nada del
# despliegue en Container Apps ni el ACR: las imágenes siguen ahí para la próxima vez.
#
# Uso: scripts/aks/aks-destroy.sh [--yes]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=()
for arg in "$@"; do
  case "$arg" in
    --yes) YES=(--yes) ;;
    *) die "Opción desconocida: $arg" ;;
  esac
done

require_tools az terraform
setup_terraform_env
tf_destroy aks ${YES[@]+"${YES[@]}"}
log "Clúster borrado"
