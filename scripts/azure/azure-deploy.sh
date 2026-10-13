#!/usr/bin/env bash
# Enciende, actualiza o reanuda Vankoo en Azure: crea el estado si falta,
# aplica las capas core, base y data, construye y sube las imágenes y aplica la
# capa apps. Si algo estaba detenido con azure-stop.sh, lo vuelve a arrancar.
#
# Uso: scripts/azure/azure-deploy.sh [--yes] [--skip-build] [--env-file <ruta>]
#   --yes              no pide confirmación en cada terraform apply
#   --skip-build       reutiliza las imágenes de images.auto.tfvars
#   --env-file <ruta>  toma las credenciales de S3 (AWS_*) de ese .env
#
# Necesita las credenciales del bucket de S3 de Invoicing, o con --env-file o
# en el entorno:
#   export TF_VAR_aws_region=...            TF_VAR_aws_s3_bucket=...
#   export TF_VAR_aws_access_key_id=...     TF_VAR_aws_secret_access_key=...
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=()
SKIP_BUILD=false
ENV_FILE=""
while (( $# > 0 )); do
  case "$1" in
    --yes) YES=(--yes) ;;
    --skip-build) SKIP_BUILD=true ;;
    --env-file) ENV_FILE="${2:-}"; [[ -n "$ENV_FILE" ]] || die "--env-file necesita una ruta"; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
  shift
done

[[ -z "$ENV_FILE" ]] || load_aws_from_env_file "$ENV_FILE"

require_tools az terraform docker git

for var in TF_VAR_aws_region TF_VAR_aws_s3_bucket TF_VAR_aws_access_key_id TF_VAR_aws_secret_access_key; do
  [[ -n "${!var:-}" ]] || die "Falta $var (credenciales del bucket de S3 de Invoicing). Ver la cabecera de este script."
done

setup_terraform_env
check_providers Microsoft.App Microsoft.ContainerRegistry Microsoft.OperationalInsights \
  Microsoft.DBforPostgreSQL Microsoft.DocumentDB Microsoft.CognitiveServices Microsoft.Storage

"$SCRIPT_DIR/bootstrap-state.sh"

tf_apply core ${YES[@]+"${YES[@]}"}
tf_apply base ${YES[@]+"${YES[@]}"}
# Tras un azure-stop.sh: los PostgreSQL deben estar en marcha antes de que
# Terraform los revise.
log "Reanudando lo que estuviera detenido"
start_postgres_servers
tf_apply data ${YES[@]+"${YES[@]}"}

if [[ "$SKIP_BUILD" == true ]]; then
  [[ -f "$TF_DIR/apps/images.auto.tfvars" ]] || die "No hay images.auto.tfvars: ejecuta sin --skip-build."
  # Tras un azure-destroy.sh el registro es nuevo y está vacío: las imágenes viejas ya no existen.
  warn "Reutilizando images.auto.tfvars: solo vale si el registro no se ha destruido desde el último build."
else
  "$SCRIPT_DIR/build-push.sh"
fi

start_container_apps
tf_apply apps ${YES[@]+"${YES[@]}"}

log "Vankoo está en pie"
echo "Gateway: $(tf_output apps gateway_url)"
echo "Scalar:  $(tf_output apps gateway_scalar_url)"
