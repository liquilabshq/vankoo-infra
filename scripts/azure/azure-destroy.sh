#!/usr/bin/env bash
# Apaga Vankoo en Azure destruyendo las capas apps, data y base, en ese orden:
# las apps, las bases de datos y el registro de imágenes. Coste 0 después; los
# datos se pierden y se empieza de cero en el siguiente azure-deploy.sh.
#
# Se conservan la capa core (environment, workspace de logs y OCR, gratis
# mientras no hay apps) y la cuenta del estado. Así la URL del gateway no
# cambia entre encendidos.
#
# Uso: scripts/azure/azure-destroy.sh [--yes] [--all]
#   --yes  no pide confirmación en cada terraform destroy
#   --all  destruye también la capa core: la URL del gateway cambiará
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=()
ALL=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=(--yes) ;;
    --all) ALL=true ;;
    *) die "Opción desconocida: $arg" ;;
  esac
done

require_tools az terraform
setup_terraform_env

# Destruir no usa estos valores, pero Terraform exige que las variables sin
# valor por defecto tengan alguno.
tf_destroy apps ${YES[@]+"${YES[@]}"} \
  -var 'images={}' \
  -var aws_region=unused -var aws_s3_bucket=unused \
  -var aws_access_key_id=unused -var aws_secret_access_key=unused
tf_destroy data ${YES[@]+"${YES[@]}"}
tf_destroy base ${YES[@]+"${YES[@]}"}

if [[ "$ALL" == true ]]; then
  tf_destroy core ${YES[@]+"${YES[@]}"}
fi

log "Vankoo destruido"
