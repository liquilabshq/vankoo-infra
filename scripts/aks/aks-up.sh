#!/usr/bin/env bash
# Crea (o reanuda) el clúster de AKS e instala el controlador del Ingress.
# No despliega Vankoo: para eso, scripts/aks/aks-build.sh y scripts/aks/aks-deploy.sh.
#
# Uso: scripts/aks/aks-up.sh [--yes]
#   --yes  no pide confirmación en el terraform apply
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=()
for arg in "$@"; do
  case "$arg" in
    --yes) YES=(--yes) ;;
    *) die "Opción desconocida: $arg" ;;
  esac
done

require_tools az terraform kubectl helm
setup_terraform_env
check_providers Microsoft.ContainerService

# Si el clúster ya existe y está pausado, hay que arrancarlo ANTES del apply:
# con el clúster detenido Azure rechaza cualquier cambio (OperationNotAllowed).
tf_init aks
if aks_name >/dev/null 2>&1 && [[ "$(aks_power_state)" == "Stopped" ]]; then
  log "El clúster estaba detenido: arrancándolo (unos minutos)"
  az aks start -g "$VANKOO_RG" -n "$(aks_name)" --only-show-errors
fi

# La capa aks lee core (sufijo) y base (ACR); si no existen, primero el
# despliegue de Container Apps (azure-deploy.sh crea las dos).
tf_apply aks ${YES[@]+"${YES[@]}"}

aks_credentials

log "Instalando ingress-nginx $INGRESS_CHART_VERSION"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
# La sonda del balanceador de Azure debe pedir /healthz al controlador; sin esta
# anotación prueba "/" y marca el servicio como caído.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "$INGRESS_CHART_VERSION" \
  --namespace "$INGRESS_NAMESPACE" --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.resources.requests.cpu=50m \
  --set controller.resources.requests.memory=96Mi \
  --set-string 'controller.service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path=/healthz' \
  --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name=$AKS_DNS_LABEL" \
  --wait --timeout 10m >/dev/null

for _ in $(seq 1 30); do
  ip="$(ingress_ip)"; [[ -n "$ip" ]] && break; sleep 10
done
[[ -n "${ip:-}" ]] || die "El Ingress no recibió IP pública"

log "Clúster listo"
echo "Ingress: $ip → https://$(public_host) (HTTPS cuando corra aks-platform.sh)"
echo "Siguiente: scripts/aks/aks-build.sh y scripts/aks/aks-deploy.sh"
