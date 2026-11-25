#!/usr/bin/env bash
# Instala en el clúster de AKS las herramientas de plataforma, con las versiones
# de chart fijadas:
#   - Argo CD (k8s/argocd/values.yaml) y la aplicación «vankoo», que mantiene el
#     namespace igual que k8s/overlays/azure en GitHub (GitOps).
#   - cert-manager y el emisor de Let's Encrypt (k8s/cert-manager): certificado
#     TLS del Ingress para https://<nombre DNS de Azure>.
#   - Monitoreo (namespace monitoring, ver k8s/README.md → Monitoreo): Prometheus,
#     Alertmanager, Grafana, node-exporter y kube-state-metrics
#     (k8s/monitoring/values.yaml), más los SLO, las alertas y los dashboards de
#     Vankoo (k8s/monitoring/vankoo).
#   - Solo con --logs-traces: logs centralizados (Loki y Alloy) y trazas distribuidas
#     (Tempo y el OpenTelemetry Operator), k8s/monitoring/logs-traces. No está
#     activado en AKS: el clúster no tiene memoria libre para ~1 GB más.
# Se puede repetir: helm upgrade --install y kubectl apply no duplican nada.
#
# Uso: scripts/aks/aks-platform.sh [--revision <rama>] [--env-file <ruta>] [--logs-traces]
#   --revision     rama de vankoo-infra que sigue Argo CD (por defecto, la de
#                  k8s/argocd/vankoo-application.yaml)
#   --env-file     .env de donde leer GRAFANA_ADMIN_PASSWORD (por defecto vankoo-infra/.env)
#   --logs-traces  instala también la capa de logs y trazas. Después hay que
#                  descomentar patches/otel-instrumentation.yaml en
#                  k8s/overlays/azure/kustomization.yaml para que los servicios
#                  lleven el agente de trazas.
#
# Acceso:
#   Grafana   https://<nombre DNS de Azure>/grafana (usuario admin; contraseña:
#             GRAFANA_ADMIN_PASSWORD del .env o, si no está, la del Secret grafana-admin)
#             kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
#   Argo CD   sin exponer a internet:
#             kubectl -n argocd port-forward svc/argocd-server 8081:80        → http://localhost:8081 (usuario admin)
#             kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
#   Alertmanager y Prometheus, sin exponer (sus alertas y datos se ven en Grafana):
#             kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093
#             kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CERT_MANAGER_CHART_VERSION="v1.21.2"
ARGOCD_CHART_VERSION="10.18.4"
MONITORING_CHART_VERSION="93.8.0"
LOKI_CHART_VERSION="7.6.0"
ALLOY_CHART_VERSION="1.15.0"
TEMPO_CHART_VERSION="1.24.4"
OTEL_OPERATOR_CHART_VERSION="0.128.0"

REVISION=""
ENV_FILE="$INFRA_DIR/.env"
LOGS_TRACES=false
while (( $# > 0 )); do
  case "$1" in
    --revision) REVISION="${2:-}"; shift ;;
    --env-file) ENV_FILE="${2:-}"; shift ;;
    --logs-traces) LOGS_TRACES=true ;;
    *) die "Opción desconocida: $1" ;;
  esac
  shift
done
LOGS_TRACES_DIR="$INFRA_DIR/k8s/monitoring/logs-traces"

require_tools az terraform kubectl helm
setup_terraform_env
aks_credentials

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
if [[ "$LOGS_TRACES" == true ]]; then
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
fi

log "cert-manager ($CERT_MANAGER_CHART_VERSION) y Let's Encrypt"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_CHART_VERSION" --namespace cert-manager --create-namespace \
  -f "$INFRA_DIR/k8s/cert-manager/values.yaml" --wait --timeout 10m >/dev/null
kubectl apply -f "$INFRA_DIR/k8s/cert-manager/cluster-issuer.yaml" >/dev/null

# Contraseña del admin de Grafana, sin imprimirla: la del .env si existe; si no, la
# que ya tenía el clúster (Secret grafana-admin o el monitoring-grafana que generó el
# chart antes de usar grafana-admin); si no, una aleatoria.
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
grafana_password="$(env_value "$ENV_FILE" GRAFANA_ADMIN_PASSWORD)"
for previous in grafana-admin monitoring-grafana; do
  [[ -n "$grafana_password" ]] && break
  grafana_password="$(kubectl -n monitoring get secret "$previous" -o 'jsonpath={.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
done
[[ -n "$grafana_password" ]] || grafana_password="$(random_secret 24)"
grafana_env="$(mktemp)"; chmod 600 "$grafana_env"
trap 'rm -f "$grafana_env"' EXIT
printf 'admin-user=admin\nadmin-password=%s\n' "$grafana_password" >"$grafana_env"
kubectl -n monitoring create secret generic grafana-admin --from-env-file="$grafana_env" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f "$grafana_env"
unset grafana_password

monitoring_values=(-f "$INFRA_DIR/k8s/monitoring/values.yaml")
[[ "$LOGS_TRACES" == true ]] && monitoring_values+=(-f "$LOGS_TRACES_DIR/kube-prometheus-stack-values.yaml")

log "Monitoreo (kube-prometheus-stack $MONITORING_CHART_VERSION)"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$MONITORING_CHART_VERSION" --namespace monitoring --create-namespace \
  "${monitoring_values[@]}" --wait --timeout 15m >/dev/null
kubectl apply -k "$INFRA_DIR/k8s/monitoring/vankoo" >/dev/null

if [[ "$LOGS_TRACES" == true ]]; then
  log "Logs: Loki ($LOKI_CHART_VERSION) y Alloy ($ALLOY_CHART_VERSION)"
  helm upgrade --install loki grafana/loki \
    --version "$LOKI_CHART_VERSION" --namespace monitoring \
    -f "$LOGS_TRACES_DIR/loki-values.yaml" --wait --timeout 10m >/dev/null
  helm upgrade --install alloy grafana/alloy \
    --version "$ALLOY_CHART_VERSION" --namespace monitoring \
    -f "$LOGS_TRACES_DIR/alloy-values.yaml" --wait --timeout 10m >/dev/null

  log "Trazas: Tempo ($TEMPO_CHART_VERSION) y OpenTelemetry Operator ($OTEL_OPERATOR_CHART_VERSION)"
  helm upgrade --install tempo grafana/tempo \
    --version "$TEMPO_CHART_VERSION" --namespace monitoring \
    -f "$LOGS_TRACES_DIR/tempo-values.yaml" --wait --timeout 10m >/dev/null
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --version "$OTEL_OPERATOR_CHART_VERSION" --namespace monitoring \
    -f "$LOGS_TRACES_DIR/otel-operator-values.yaml" --wait --timeout 10m >/dev/null

  # Instrumentation, reglas y dashboards de la capa. Va antes de Argo CD: los pods
  # anotados solo reciben el agente si el Instrumentation ya existe cuando se crean.
  kubectl apply -k "$LOGS_TRACES_DIR" >/dev/null
fi

log "Argo CD (argo-cd $ARGOCD_CHART_VERSION)"
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" --namespace argocd --create-namespace \
  -f "$INFRA_DIR/k8s/argocd/values.yaml" --wait --timeout 10m >/dev/null

if [[ -n "$REVISION" ]]; then
  sed "s|targetRevision: .*|targetRevision: $REVISION|" "$INFRA_DIR/k8s/argocd/vankoo-application.yaml" \
    | kubectl apply -f - >/dev/null
else
  kubectl apply -f "$INFRA_DIR/k8s/argocd/vankoo-application.yaml" >/dev/null
fi

log "Plataforma lista"
echo "Grafana:  https://$(public_host)/grafana (usuario admin)"
echo "Argo CD:  kubectl -n argocd port-forward svc/argocd-server 8081:80"
