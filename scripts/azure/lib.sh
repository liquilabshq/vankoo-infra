#!/usr/bin/env bash
# Funciones comunes de los scripts de Azure. No se ejecuta solo: lo cargan los
# demás con `source`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$INFRA_DIR/terraform"
# Los repos de los servicios viven junto a vankoo-infra (como en el compose).
PROJECTS_DIR="$(cd "$INFRA_DIR/.." && pwd)"

VANKOO_RG="${VANKOO_RG:-liquilabs-vankoo}"
VANKOO_LOCATION="${VANKOO_LOCATION:-centralus}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[aviso] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

require_tools() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "Falta '$tool' en el PATH."
  done
}

# Busca la suscripción que contiene el grupo de Vankoo, para no tener que
# escribir su id en ningún archivo. Todas se llaman «Azure for Students», así
# que el nombre no sirve.
select_subscription() {
  az account show >/dev/null 2>&1 || die "No hay sesión de Azure. Ejecuta: az login"

  if [[ -n "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    return
  fi

  local sub
  for sub in $(az account list --all --query "[?state=='Enabled'].id" -o tsv); do
    if [[ "$(az group exists --subscription "$sub" -n "$VANKOO_RG" 2>/dev/null)" == "true" ]]; then
      export ARM_SUBSCRIPTION_ID="$sub"
      az account set --subscription "$sub"
      return
    fi
  done
  die "Ninguna de tus suscripciones tiene el grupo '$VANKOO_RG'. ¿Te dieron acceso?"
}

# Nombre de la cuenta del estado: fijo para todo el equipo (se deriva de la
# suscripción y el grupo) y único en Azure.
tfstate_account_name() {
  local hash
  hash="$(printf '%s/%s' "$ARM_SUBSCRIPTION_ID" "$VANKOO_RG" | shasum | cut -c1-12)"
  printf 'vankootf%s' "$hash"
}

setup_terraform_env() {
  select_subscription
  TFSTATE_ACCOUNT="$(tfstate_account_name)"
  export TF_VAR_tfstate_storage_account="$TFSTATE_ACCOUNT"
  export TF_VAR_resource_group_name="$VANKOO_RG"
  export TF_VAR_location="$VANKOO_LOCATION"
  export TF_IN_AUTOMATION=1
}

# Los resource providers se registran a nivel de suscripción, y el equipo no
# puede hacerlo. Si falta alguno, se avisa con el comando para el dueño.
check_providers() {
  local missing=()
  local ns
  for ns in "$@"; do
    local state
    state="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || true)"
    [[ "$state" == "Registered" ]] || missing+=("$ns")
  done
  if (( ${#missing[@]} > 0 )); then
    printf '\nFaltan proveedores en la suscripción. El dueño debe ejecutar en Cloud Shell:\n' >&2
    for ns in "${missing[@]}"; do
      printf '  az provider register --namespace %s\n' "$ns" >&2
    done
    die "Proveedores sin registrar: ${missing[*]}"
  fi
}

# --- Detener y reanudar --------------------------------------------------------
# La versión de az que usa el equipo no trae `containerapp stop/start`: se usa
# la API de Azure directamente.
CONTAINERAPPS_API="2024-03-01"

vankoo_container_apps() {
  az containerapp list --only-show-errors -g "$VANKOO_RG" --query "[?starts_with(name,'vankoo-')].name" -o tsv 2>/dev/null
}

vankoo_postgres_servers() {
  az postgres flexible-server list -g "$VANKOO_RG" --query "[?starts_with(name,'vankoo-')].name" -o tsv 2>/dev/null
}

# Apps cuyos datos viven solo en el contenedor (Kafka, Axon, Oracle sin disco
# persistente): las marca Terraform con la etiqueta vankoo-data = ephemeral.
vankoo_ephemeral_apps() {
  az containerapp list --only-show-errors -g "$VANKOO_RG" --query "[?tags.\"vankoo-data\"=='ephemeral'].name" -o tsv 2>/dev/null
}

container_app_action() {
  local app="$1" action="$2" id
  id="$(az containerapp show --only-show-errors -g "$VANKOO_RG" -n "$app" --query id -o tsv)"
  az rest --method post --url "https://management.azure.com${id}/${action}?api-version=${CONTAINERAPPS_API}" -o none
}

stop_container_apps() {
  local app status
  for app in $(vankoo_container_apps); do
    status="$(az containerapp show --only-show-errors -g "$VANKOO_RG" -n "$app" --query properties.runningStatus -o tsv)"
    if [[ "$status" == "Stopped" ]]; then
      echo "  $app ya estaba detenida"
    else
      echo "  deteniendo $app"
      container_app_action "$app" stop
    fi
  done
}

start_container_apps() {
  local app status
  for app in $(vankoo_container_apps); do
    status="$(az containerapp show --only-show-errors -g "$VANKOO_RG" -n "$app" --query properties.runningStatus -o tsv)"
    if [[ "$status" == "Stopped" ]]; then
      echo "  arrancando $app"
      container_app_action "$app" start
    fi
  done
}

stop_postgres_servers() {
  local server state
  for server in $(vankoo_postgres_servers); do
    state="$(az postgres flexible-server show -g "$VANKOO_RG" -n "$server" --query state -o tsv)"
    if [[ "$state" == "Stopped" ]]; then
      echo "  $server ya estaba detenido"
    else
      echo "  deteniendo $server"
      az postgres flexible-server stop -g "$VANKOO_RG" -n "$server" -o none
    fi
  done
}

start_postgres_servers() {
  local server state
  for server in $(vankoo_postgres_servers); do
    state="$(az postgres flexible-server show -g "$VANKOO_RG" -n "$server" --query state -o tsv)"
    if [[ "$state" == "Stopped" ]]; then
      echo "  arrancando $server"
      az postgres flexible-server start -g "$VANKOO_RG" -n "$server" -o none
    fi
  done
}

# Lee solo las credenciales de S3 de un .env (formato del .env.example) y las
# exporta como TF_VAR_aws_*. No usa `source`: el .env tiene valores con
# espacios y < > que romperían el shell. No imprime ningún valor.
load_aws_from_env_file() {
  local file="$1"
  [[ -f "$file" ]] || die "No existe $file"
  local key tfvar value
  for pair in AWS_REGION:aws_region AWS_S3_BUCKET:aws_s3_bucket \
              AWS_ACCESS_KEY_ID:aws_access_key_id AWS_SECRET_ACCESS_KEY:aws_secret_access_key; do
    key="${pair%%:*}"; tfvar="TF_VAR_${pair#*:}"
    value="$(grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | sed -E 's/^["'\'']//; s/["'\'']$//')"
    if [[ -z "$value" || "$value" == YOUR_* ]]; then
      die "$key no tiene valor en $file"
    fi
    export "$tfvar=$value"
  done
}

tf_init() {
  local layer="$1"
  terraform -chdir="$TF_DIR/$layer" init -input=false -reconfigure \
    -backend-config="resource_group_name=$VANKOO_RG" \
    -backend-config="storage_account_name=$TFSTATE_ACCOUNT" \
    -backend-config="container_name=tfstate" \
    -backend-config="key=$layer.tfstate" >/dev/null
}

# Uso: tf_apply <capa> [--yes] [args extra de terraform]
tf_apply() {
  local layer="$1"; shift
  local approve=()
  if [[ "${1:-}" == "--yes" ]]; then approve=(-auto-approve); shift; fi
  log "terraform apply: $layer"
  tf_init "$layer"
  terraform -chdir="$TF_DIR/$layer" apply -input=false ${approve[@]+"${approve[@]}"} "$@"
}

tf_destroy() {
  local layer="$1"; shift
  local approve=()
  if [[ "${1:-}" == "--yes" ]]; then approve=(-auto-approve); shift; fi
  log "terraform destroy: $layer"
  tf_init "$layer"
  terraform -chdir="$TF_DIR/$layer" destroy -input=false ${approve[@]+"${approve[@]}"} "$@"
}

tf_output() {
  local layer="$1" name="$2"
  terraform -chdir="$TF_DIR/$layer" output -raw "$name"
}
