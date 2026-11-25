#!/usr/bin/env bash
# Construye las imágenes en el propio ACR (ACR Tasks, `az acr build`): compilan en
# linux/amd64 en Azure, sin emulación en un Mac ARM ni gastar disco local. Cada
# imagen recibe dos etiquetas: el commit (`<sha corto>`, inmutable) y `aks`, la
# que usa el overlay de Kubernetes. Se construye el commit actual (HEAD) de la
# rama que tenga cada repo junto a vankoo-infra, igual que build-push.sh: lo que
# no esté en un commit no entra (se empaqueta con `git archive`).
#
# Las construcciones corren en paralelo (AKS_BUILD_JOBS, 4 por defecto) dentro de
# este proceso: el estado de Terraform se lee una sola vez.
#
# Uso: scripts/aks/aks-build.sh [servicio ...]
#   sin argumentos construye todos; p. ej.: scripts/aks/aks-build.sh finance-service mype-web
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# imagen:repo[:Dockerfile relativo al repo, si no está en la raíz; como en el compose]
ALL=(
  api-gateway:vankoo-api-gateway
  discovery-server:vankoo-discovery-server
  iam-service:vankoo-iam-service
  profile-service:vankoo-profile-service
  invoicing-service:vankoo-invoicing-service:LiquiLabs.Vankoo.Invoicing/Dockerfile
  investment-service:vankoo-investment-service
  finance-service:vankoo-finance-service
  risk-service:vankoo-risk-service
  notification-service:vankoo-notification-service
  mype-web:vankoo-mype-web
)

require_tools az git terraform
setup_terraform_env
tf_init base
ACR="$(tf_output base acr_name)"

selected=("$@")
JOBS="${AKS_BUILD_JOBS:-4}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Empaqueta el commit actual del repo y lo construye en el ACR. Escribe ok o fail
# en $work/<imagen>.status para el resumen.
build_one() {
  local image="$1" repo="$2" dockerfile="$3" dir sha ctx
  dir="$PROJECTS_DIR/$repo"
  sha="$(git -C "$dir" rev-parse --short HEAD)"
  ctx="$work/$image"; mkdir -p "$ctx"
  git -C "$dir" archive --format=tar HEAD | tar -x -C "$ctx"
  if az acr build --registry "$ACR" --platform linux/amd64 \
        --image "$image:$sha" --image "$image:aks" \
        --file "$ctx/$dockerfile" --only-show-errors "$ctx" >"$work/$image.log" 2>&1; then
    echo "ok $sha" >"$work/$image.status"
  else
    echo "fail $sha" >"$work/$image.status"
  fi
}

images=()
for entry in "${ALL[@]}"; do
  IFS=: read -r image repo dockerfile <<<"$entry"
  dockerfile="${dockerfile:-Dockerfile}"
  if (( ${#selected[@]} > 0 )) && [[ ! " ${selected[*]} " == *" $image "* ]]; then
    continue
  fi
  dir="$PROJECTS_DIR/$repo"
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || die "No encuentro el repo $repo junto a vankoo-infra"
  [[ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ]] \
    || warn "$repo tiene cambios sin commit: no entran en la imagen"
  echo "  $image  ($repo, $(git -C "$dir" branch --show-current) @ $(git -C "$dir" rev-parse --short HEAD))"
  images+=("$image")
  build_one "$image" "$repo" "$dockerfile" &
  while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 2; done
done
log "Construyendo ${#images[@]} imágenes en $ACR (de $JOBS en $JOBS)"
wait

failed=()
for image in "${images[@]}"; do
  read -r result sha <"$work/$image.status"
  if [[ "$result" == ok ]]; then
    echo "  ✓ $ACR.azurecr.io/$image:$sha"
  else
    echo "  ✗ $image"; failed+=("$image")
    tail -30 "$work/$image.log" >&2
  fi
done
(( ${#failed[@]} == 0 )) || die "Fallaron: ${failed[*]}"
log "Imágenes listas"
