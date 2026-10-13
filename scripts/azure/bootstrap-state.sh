#!/usr/bin/env bash
# Crea, una sola vez, la cuenta de almacenamiento donde Terraform guarda su
# estado. Terraform no puede crearla él mismo: necesita el estado para empezar.
# Es idempotente: si ya existe, no hace nada. azure-destroy.sh nunca la borra.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools az
setup_terraform_env

if az storage account show -g "$VANKOO_RG" -n "$TFSTATE_ACCOUNT" >/dev/null 2>&1; then
  log "La cuenta del estado ya existe: $TFSTATE_ACCOUNT"
else
  log "Creando la cuenta del estado: $TFSTATE_ACCOUNT"
  az storage account create \
    -g "$VANKOO_RG" -n "$TFSTATE_ACCOUNT" -l "$VANKOO_LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false \
    -o none
fi

# Con --auth-mode key, az obtiene la clave de la cuenta con el permiso que ya
# tienes sobre el grupo; no hace falta un rol de datos sobre el blob.
az storage container create \
  --account-name "$TFSTATE_ACCOUNT" -n tfstate \
  --auth-mode key --only-show-errors -o none

log "Estado listo en $TFSTATE_ACCOUNT/tfstate"
