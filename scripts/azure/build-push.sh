#!/usr/bin/env bash
# Construye las imágenes de los servicios desde sus repos (junto a vankoo-infra)
# y las sube al registro de Azure. Escribe las referencias en
# terraform/apps/images.auto.tfvars, que la capa apps lee sola.
#
# Usa la rama que tenga cada repo en ese momento: revisa con `git status`
# antes de construir.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools az terraform docker git
setup_terraform_env

# servicio | repo | Dockerfile (relativo al repo, que es el contexto)
SERVICES=(
  "api-gateway|vankoo-api-gateway|Dockerfile"
  "iam-service|vankoo-iam-service|Dockerfile"
  "invoicing-service|vankoo-invoicing-service|LiquiLabs.Vankoo.Invoicing/Dockerfile"
)

tf_init base
ACR_NAME="$(tf_output base acr_name)"
ACR_SERVER="$(tf_output base acr_login_server)"

log "Iniciando sesión en $ACR_SERVER"
az acr login --name "$ACR_NAME" >/dev/null

IMAGES_FILE="$TF_DIR/apps/images.auto.tfvars"
{
  echo "# Generado por scripts/azure/build-push.sh. No editar ni subir a git."
  echo "images = {"
} > "$IMAGES_FILE.tmp"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r service repo dockerfile <<< "$entry"
  repo_dir="$PROJECTS_DIR/$repo"
  [[ -d "$repo_dir" ]] || die "No encuentro $repo_dir"

  # La etiqueta es el commit; si hay cambios sin commitear, se marca -dirty.
  tag="$(git -C "$repo_dir" rev-parse --short HEAD)"
  [[ -z "$(git -C "$repo_dir" status --porcelain --untracked-files=no)" ]] || tag="$tag-dirty"
  branch="$(git -C "$repo_dir" branch --show-current)"
  image="$ACR_SERVER/$service:$tag"

  log "$service ← $repo ($branch @ $tag)"
  # Azure ejecuta x86: en un Mac con Apple Silicon la imagen nativa (arm64)
  # no arrancaría.
  docker buildx build --platform linux/amd64 \
    -f "$repo_dir/$dockerfile" -t "$image" --push "$repo_dir"

  echo "  \"$service\" = \"$image\"" >> "$IMAGES_FILE.tmp"
done

echo "}" >> "$IMAGES_FILE.tmp"
mv "$IMAGES_FILE.tmp" "$IMAGES_FILE"
log "Imágenes listas. Referencias en terraform/apps/images.auto.tfvars"
