#!/usr/bin/env bash
# Despliega Vankoo en el clúster de AKS con el overlay k8s/overlays/azure.
#
# Antes de aplicar crea, solo en el clúster, lo que no va a Git:
#   - Secret vankoo-secrets: contraseñas de las bases y JWT (se reutilizan las del
#     despliegue anterior, porque las bases ya se crearon con ellas) y claves
#     externas leídas del .env de vankoo-infra (OCR, Stripe, S3, OpenAI), sin
#     imprimirlas ni dejarlas en disco.
#   - ConfigMap vankoo-deploy: URL pública (IP del Ingress), bucket de certificados y
#     correo: Azure Communication Services si existe la capa email, si no Mailpit;
#     push: Firebase si el .env trae su cuenta de servicio, si no solo log;
#     KYC del inversionista: la función DNI si existe la capa functions, si no manual.
#   - ConfigMap kyc-demo-ca: CA de demostración del KYC (PARCHE TEMPORAL).
#
# Uso: scripts/aks/aks-deploy.sh [--env-file <ruta>] [--restart]
#   --env-file  .env de donde leer las claves externas (por defecto vankoo-infra/.env)
#   --restart   reinicia los Deployments para que bajen otra vez la etiqueta «aks»
#               (tras un aks-build.sh sin cambios en los manifiestos)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_FILE="$INFRA_DIR/.env"
RESTART=false
while (( $# > 0 )); do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    --restart) RESTART=true ;;
    *) die "Opción desconocida: $1" ;;
  esac
  shift
done
[[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE"

require_tools az terraform kubectl python3
setup_terraform_env
aks_credentials

ip="$(ingress_ip)"
[[ -n "$ip" ]] || die "El Ingress no tiene IP: ejecuta scripts/aks/aks-up.sh"
public_url="https://$(public_host)"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- Secret vankoo-secrets ------------------------------------------------------
log "Secretos (sin imprimir valores)"
keep() { local v; v="$(current_secret "$1")"; [[ -n "$v" ]] && printf '%s' "$v" || random_secret "${2:-32}"; }
from_env() {
  local v; v="$(env_value "$ENV_FILE" "$1")"
  [[ -n "$v" ]] || warn "$1 no tiene valor en $(basename "$ENV_FILE"): esa función quedará apagada"
  printf '%s' "$v"
}

# Correo: si existe la capa terraform/email (scripts/aks/aks-email.sh), Azure
# Communication Services; si no, Mailpit dentro del clúster.
email_provider=smtp
mail_from="Vankoo <no-reply@vankoo.dev>"
acs_connection_string=""
if tf_init email >/dev/null 2>&1 && acs_connection_string="$(tf_output email connection_string 2>/dev/null)" \
    && [[ -n "$acs_connection_string" ]]; then
  email_provider=acs
  mail_from="Vankoo <$(tf_output email sender_address)>"
else
  acs_connection_string=""
fi

# Push: Firebase Cloud Messaging si el .env trae la cuenta de servicio
# (FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL y FIREBASE_PRIVATE_KEY); si no,
# Notification solo escribe los push en el log.
push_provider=logging
if [[ -n "$(env_value "$ENV_FILE" FIREBASE_PROJECT_ID)" && -n "$(env_value "$ENV_FILE" FIREBASE_CLIENT_EMAIL)" \
      && -n "$(env_value "$ENV_FILE" FIREBASE_PRIVATE_KEY)" ]]; then
  push_provider="$(env_value "$ENV_FILE" NOTIFICATION_PUSH_PROVIDER)"
  [[ -n "$push_provider" ]] || push_provider=firebase
fi
# El secreto de los topics de FCM: el del .env si existe (el mismo que en local),
# si no el que ya tenía el clúster.
push_topic_secret="$(env_value "$ENV_FILE" NOTIFICATION_PUSH_TOPIC_SECRET)"
[[ -n "$push_topic_secret" ]] || push_topic_secret="$(keep PUSH_TOPIC_SECRET)"

# KYC del inversionista: verificación automática del DNI con la función serverless de la
# capa terraform/functions, si existe y está encendida; si no, revisión manual.
dni_enabled=false; dni_url=""; dni_key=""
if tf_init functions >/dev/null 2>&1 && dni_url="$(tf_output functions verify_dni_url 2>/dev/null)" \
    && [[ -n "$dni_url" ]]; then
  dni_app="$(tf_output functions function_app_name 2>/dev/null)"
  dni_key="$(az functionapp keys list -g "$VANKOO_RG" -n "$dni_app" --query functionKeys.default -o tsv 2>/dev/null || true)"
  [[ -n "$dni_key" ]] && dni_enabled=true || warn "No pude leer la clave de la función DNI: el KYC del inversionista queda manual"
fi

secrets="$(mktemp)"; chmod 600 "$secrets"
trap 'rm -f "$secrets"' EXIT
iam_db_password="$(keep IAM_DB_PASSWORD)"
profile_db_password="$(keep PROFILE_DB_PASSWORD)"
finance_db_password="$(keep FINANCE_DB_PASSWORD)"
risk_db_password="$(keep RISK_DB_PASSWORD)"
invoicing_db_password="$(keep INVOICING_DB_PASSWORD)"
investment_db_password="$(keep INVESTMENT_DB_PASSWORD)"
{
  printf 'JWT_SECRET=%s\n' "$(keep JWT_SECRET 64)"
  printf 'IAM_DB_USERNAME=vankoo\nIAM_DB_PASSWORD=%s\n' "$iam_db_password"
  printf 'PROFILE_DB_USER=vankoo\nPROFILE_DB_PASSWORD=%s\n' "$profile_db_password"
  printf 'FINANCE_DB_USERNAME=vankoo\nFINANCE_DB_PASSWORD=%s\n' "$finance_db_password"
  printf 'RISK_DB_USERNAME=vankoo\nRISK_DB_PASSWORD=%s\n' "$risk_db_password"
  printf 'RISK_DATABASE_URL=postgresql+asyncpg://vankoo:%s@risk-db-postgres:5432/vankoo_risk_db\n' "$risk_db_password"
  printf 'INVOICING_DB_USER=vankoo\nINVOICING_DB_PASSWORD=%s\n' "$invoicing_db_password"
  printf 'INVOICING_DB_CONNECTION_STRING=mongodb://vankoo:%s@invoicing-db-mongo:27017/?authSource=admin\n' "$invoicing_db_password"
  printf 'INVESTMENT_DB_USER=VANKOO_INVESTMENT\nINVESTMENT_DB_PASSWORD=%s\n' "$investment_db_password"
  printf 'INVESTMENT_DB_MASTER_PASSWORD=%s\n' "$(keep INVESTMENT_DB_MASTER_PASSWORD)"
  # MinIO no se despliega en Azure (archivos en S3), pero los manifiestos base aún
  # referencian estas claves.
  printf 'MINIO_ROOT_USER=unused\nMINIO_ROOT_PASSWORD=%s\n' "$(keep MINIO_ROOT_PASSWORD)"
  printf 'PUSH_TOPIC_SECRET=%s\n' "$push_topic_secret"
  [[ "$dni_enabled" == true ]] && printf 'DNI_VERIFICATION_KEY=%s\n' "$dni_key"
  # Licencia de Axon Server: conexión a Axoniq Platform (<environment-id>:<access-token>).
  # Sin ella, Axon corre sin licencia y se apaga a las 12 h.
  axon_auth="$(env_value "$ENV_FILE" AXONIQ_PLATFORM_AUTHENTICATION)"
  [[ -n "$axon_auth" ]] && printf 'AXONIQ_PLATFORM_AUTHENTICATION=%s\n' "$axon_auth"
  if [[ "$push_provider" == firebase ]]; then
    for key in FIREBASE_PROJECT_ID FIREBASE_CLIENT_EMAIL FIREBASE_PRIVATE_KEY; do
      printf '%s=%s\n' "$key" "$(env_value "$ENV_FILE" "$key")"
    done
  fi
  [[ -n "$acs_connection_string" ]] && printf 'ACS_CONNECTION_STRING=%s\n' "$acs_connection_string"
  # El webhook de Stripe de AKS tiene su propio secreto (AKS_STRIPE_WEBHOOK_SECRET, del
  # endpoint registrado en Stripe); STRIPE_WEBHOOK_SECRET es el de `stripe listen` en local.
  aks_whsec="$(env_value "$ENV_FILE" AKS_STRIPE_WEBHOOK_SECRET)"
  if [[ -n "$aks_whsec" ]]; then
    printf 'STRIPE_WEBHOOK_SECRET=%s\n' "$aks_whsec"
  else
    printf 'STRIPE_WEBHOOK_SECRET=%s\n' "$(from_env STRIPE_WEBHOOK_SECRET)"
  fi
  for key in AZURE_OCR_ENDPOINT AZURE_OCR_API_KEY STRIPE_SECRET_KEY OPENAI_API_KEY \
             AWS_REGION AWS_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
             PROFILE_AWS_REGION PROFILE_AWS_S3_BUCKET PROFILE_AWS_ACCESS_KEY_ID PROFILE_AWS_SECRET_ACCESS_KEY; do
    printf '%s=%s\n' "$key" "$(from_env "$key")"
  done
} >"$secrets"
kubectl -n "$NAMESPACE" create secret generic vankoo-secrets --from-env-file="$secrets" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f "$secrets"

# --- ConfigMaps del despliegue ------------------------------------------------------
bucket="$(env_value "$ENV_FILE" PROFILE_AWS_S3_BUCKET)"
region="$(env_value "$ENV_FILE" PROFILE_AWS_REGION)"
kubectl -n "$NAMESPACE" create configmap vankoo-deploy \
  --from-literal=WEB_APP_URL="$public_url" \
  --from-literal=PASSWORD_RESET_WEB_URL="$public_url/iam/reset" \
  --from-literal=GREEN_DOCUMENTS_BASE_URL="https://$bucket.s3.$region.amazonaws.com" \
  --from-literal=PUSH_PROVIDER="$push_provider" \
  --from-literal=DNI_VERIFICATION_ENABLED="$dni_enabled" \
  --from-literal=DNI_VERIFICATION_URL="$dni_url" \
  --from-literal=EMAIL_PROVIDER="$email_provider" \
  --from-literal=MAIL_FROM="$mail_from" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# PARCHE TEMPORAL (demos): la CA con la que se firman las fichas RUC de prueba.
ca="$PROJECTS_DIR/vankoo-risk-service/demo-kyc/ca.pem"
if [[ -f "$ca" ]]; then
  kubectl -n "$NAMESPACE" create configmap kyc-demo-ca --from-file=ca.pem="$ca" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
else
  warn "No encuentro $ca: el KYC solo aceptará fichas RUC reales"
  kubectl -n "$NAMESPACE" create configmap kyc-demo-ca --from-literal=ca.pem="" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

# --- Manifiestos ---------------------------------------------------------------
log "Aplicando k8s/overlays/azure"
kubectl apply -k "$OVERLAY_DIR" >/dev/null

if [[ "$RESTART" == true ]]; then
  kubectl -n "$NAMESPACE" rollout restart deployment >/dev/null
fi

log "Esperando a que los servicios estén listos (Oracle y Axon tardan unos minutos la primera vez)"
failed=()
for d in $(kubectl -n "$NAMESPACE" get deploy -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl -n "$NAMESPACE" rollout status "deploy/$d" --timeout=15m >/dev/null 2>&1; then
    echo "  ✓ $d"
  else
    echo "  ✗ $d"; failed+=("$d")
  fi
done

log "Vankoo en AKS"
echo "Web MYPE: $public_url"
echo "API:      $public_url/iam/api/v1/... (y el resto de /<servicio>/api)"
(( ${#failed[@]} == 0 )) || warn "Sin terminar: ${failed[*]} (kubectl -n $NAMESPACE get pods)"
