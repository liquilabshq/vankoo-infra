#!/usr/bin/env bash
# Funciones de los scripts de AKS. Reutiliza scripts/azure/lib.sh (suscripción,
# estado de Terraform, tf_apply...) sin modificarlo: el despliegue en Container
# Apps y el de AKS conviven y comparten solo el grupo, el ACR y la capa core.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../azure" && pwd)/lib.sh"

OVERLAY_DIR="$INFRA_DIR/k8s/overlays/azure"
NAMESPACE="vankoo"
INGRESS_NAMESPACE="ingress-nginx"
# Nombre DNS que Azure da a la IP del ingress-nginx: https://<etiqueta>.<región>.cloudapp.azure.com.
# Si cambia, hay que cambiarlo también en k8s/overlays/azure (Ingress).
AKS_DNS_LABEL="${AKS_DNS_LABEL:-vankoo-liquilabs}"
public_host() { printf '%s.%s.cloudapp.azure.com' "$AKS_DNS_LABEL" "$VANKOO_LOCATION"; }
# Versión fija del chart del Ingress, para que el despliegue sea reproducible.
INGRESS_CHART_VERSION="${INGRESS_CHART_VERSION:-4.13.3}"

aks_name() { tf_output aks cluster_name; }

# Deja kubectl apuntando al clúster (contexto con el nombre del clúster).
aks_credentials() {
  tf_init aks
  local name; name="$(aks_name)" || die "No hay clúster: ejecuta scripts/aks/aks-up.sh"
  az aks get-credentials -g "$VANKOO_RG" -n "$name" --overwrite-existing --only-show-errors >/dev/null
  kubectl config use-context "$name" >/dev/null
}

aks_power_state() {
  az aks show -g "$VANKOO_RG" -n "$(aks_name)" --query powerState.code -o tsv 2>/dev/null || echo "Missing"
}

# IP pública del Ingress (la asigna el balanceador de Azure al instalar ingress-nginx).
ingress_ip() {
  kubectl -n "$INGRESS_NAMESPACE" get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}

# Lee una variable de un .env sin `source` y sin imprimirla (mismo criterio que
# load_aws_from_env_file). Devuelve vacío si no está.
env_value() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r' \
    | sed -E 's/^["'\'']//; s/["'\'']$//' || true
}

# Valor actual de una clave del Secret vankoo-secrets, para reutilizar las
# contraseñas de las bases entre despliegues (las bases ya se crearon con ellas).
current_secret() {
  kubectl -n "$NAMESPACE" get secret vankoo-secrets -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Alfanumérico (sirve en URLs de conexión sin escapar). Sin `tr | head`: con
# pipefail, el SIGPIPE de tr al cerrar head abortaría el script.
random_secret() {
  python3 -c 'import secrets,string,sys; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))), end="")' "${1:-32}"
}
