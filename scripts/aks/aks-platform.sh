#!/usr/bin/env bash
# Instala en el clúster de AKS las herramientas de plataforma, con las versiones
# de chart fijadas:
#   - Argo CD (k8s/argocd/values.yaml) y la aplicación «vankoo», que mantiene el
#     namespace igual que k8s/overlays/azure en GitHub (GitOps).
#   - cert-manager y el emisor de Let's Encrypt (k8s/cert-manager): certificado
#     TLS del Ingress para https://<nombre DNS de Azure>.
#   - Monitoreo: Prometheus, Alertmanager, Grafana, node-exporter y
#     kube-state-metrics (k8s/monitoring/values.yaml), más las reglas de alerta,
#     los SLO y el dashboard de Vankoo (k8s/monitoring/vankoo).
# Se puede repetir: helm upgrade --install y kubectl apply no duplican nada.
#
# Uso: scripts/aks/aks-platform.sh [--revision <rama>]
#   --revision  rama de vankoo-infra que sigue Argo CD (por defecto, la de
#               k8s/argocd/vankoo-application.yaml)
#
# Acceso (sin exponerlos a internet):
#   kubectl -n argocd port-forward svc/argocd-server 8081:80        → http://localhost:8081 (usuario admin)
#   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
#   kubectl -n monitoring port-forward svc/monitoring-grafana 3002:80 → http://localhost:3002 (usuario admin)
#   kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CERT_MANAGER_CHART_VERSION="v1.21.2"
ARGOCD_CHART_VERSION="10.18.4"
MONITORING_CHART_VERSION="93.8.0"

REVISION=""
while (( $# > 0 )); do
  case "$1" in
    --revision) REVISION="${2:-}"; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
  shift
done

require_tools az terraform kubectl helm
setup_terraform_env
aks_credentials

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null

log "cert-manager ($CERT_MANAGER_CHART_VERSION) y Let's Encrypt"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_CHART_VERSION" --namespace cert-manager --create-namespace \
  -f "$INFRA_DIR/k8s/cert-manager/values.yaml" --wait --timeout 10m >/dev/null
kubectl apply -f "$INFRA_DIR/k8s/cert-manager/cluster-issuer.yaml" >/dev/null

log "Monitoreo (kube-prometheus-stack $MONITORING_CHART_VERSION)"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$MONITORING_CHART_VERSION" --namespace monitoring --create-namespace \
  -f "$INFRA_DIR/k8s/monitoring/values.yaml" --wait --timeout 15m >/dev/null
kubectl apply -k "$INFRA_DIR/k8s/monitoring/vankoo" >/dev/null

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
echo "Argo CD:  kubectl -n argocd port-forward svc/argocd-server 8081:80"
echo "Grafana:  kubectl -n monitoring port-forward svc/monitoring-grafana 3002:80"
