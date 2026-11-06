#!/usr/bin/env bash
# Operates only on Investment. Never applies core/base/data/apps or stops other services.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Windows az.cmd emits CRLF; prevent MSYS rewriting remote Linux script paths.
az() { MSYS_NO_PATHCONV=1 command az "$@" | tr -d '\r'; }
ACTION="${1:-help}"
APP=vankoo-investment-service
VM=vankoo-investment-db-vm

if [[ "$ACTION" == help ]]; then
  echo 'investment.sh {plan-bootstrap|bootstrap|build|collect-egress|plan|deploy|start|stop|status}'
  exit 0
fi
require_tools az terraform
setup_terraform_env

case "$ACTION" in
  plan-bootstrap|bootstrap|plan|deploy)
    [[ -n "${INVESTMENT_SSH_PUBLIC_KEY_FILE:-}" && "$INVESTMENT_SSH_PUBLIC_KEY_FILE" == *.pub ]] \
      || die 'Define INVESTMENT_SSH_PUBLIC_KEY_FILE apuntando a tu clave pública .pub.'
    [[ -f "$INVESTMENT_SSH_PUBLIC_KEY_FILE" ]] || die 'No existe la clave pública indicada.'
    export TF_VAR_investment_ssh_public_key
    TF_VAR_investment_ssh_public_key="$(<"$INVESTMENT_SSH_PUBLIC_KEY_FILE")"
    check_providers Microsoft.Compute Microsoft.Network Microsoft.App Microsoft.DevTestLab
    tf_init investment
    if [[ "$ACTION" == *bootstrap* ]]; then
      if [[ "$(tf_output investment bootstrap_mode 2>/dev/null || true)" == false ]]; then
        die 'Investment ya está desplegado. Usa plan/deploy; bootstrap sustituiría su imagen.'
      fi
      bootstrap=true
    else
      bootstrap=false
      [[ -f "$TF_DIR/investment/egress.auto.tfvars" ]] || die 'Ejecuta collect-egress después de bootstrap.'
      [[ -f "$TF_DIR/investment/image.auto.tfvars" ]] || die 'Ejecuta build primero.'
    fi
    if [[ "$ACTION" == plan* ]]; then
      terraform -chdir="$TF_DIR/investment" plan -input=false -var="bootstrap=$bootstrap"
    else
      # Deliberately interactive: review the plan before accepting creation/billing.
      terraform -chdir="$TF_DIR/investment" apply -var="bootstrap=$bootstrap"
    fi
    ;;
  build)
    require_tools docker git
    tf_init base
    acr="$(tf_output base acr_name)"
    server="$(tf_output base acr_login_server)"
    repo="$PROJECTS_DIR/vankoo-investment-service"
    tag="$(git -C "$repo" rev-parse --short HEAD)"
    if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then
      tag="$tag-dirty-$(date -u +%Y%m%d%H%M%S)"
      warn 'Imagen de cambios locales: conservar diff y no presentarla como commit limpio.'
    fi
    image="$server/investment-service:$tag"
    az acr login --name "$acr" >/dev/null
    docker buildx build --platform linux/amd64 -t "$image" --push "$repo"
    printf 'image = "%s"\n' "$image" > "$TF_DIR/investment/image.auto.tfvars"
    echo "Imagen publicada: $image"
    ;;
  collect-egress)
    ips="$(az containerapp show -g "$VANKOO_RG" -n "$APP" --query properties.outboundIpAddresses -o tsv)"
    [[ -n "$ips" ]] || die 'No hay IP de salida. Primero crea la app provisional con bootstrap.'
    for ip in $ips; do
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'IP de salida inesperada.'
    done
    {
      printf 'database_client_cidrs = [\n'
      for ip in $ips; do printf '  "%s/32",\n' "$ip"; done
      printf ']\n'
    } > "$TF_DIR/investment/egress.auto.tfvars"
    echo 'Lista de IP /32 guardada localmente. Revisar su regla en el siguiente plan.'
    ;;
  stop)
    app_status="$(az containerapp show -g "$VANKOO_RG" -n "$APP" --query properties.runningStatus -o tsv)"
    [[ "$app_status" == Stopped ]] || container_app_action "$APP" stop
    power="$(az vm get-instance-view -g "$VANKOO_RG" -n "$VM" \
      --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv)"
    if [[ "$power" == PowerState/deallocated ]]; then
      echo 'Investment ya detenido y VM desasignada.'
      exit 0
    fi
    # Stop Oracle cleanly before deallocating. This never removes the volume.
    if [[ "$power" == PowerState/running ]]; then
      result="$(az vm run-command invoke -g "$VANKOO_RG" -n "$VM" --command-id RunShellScript \
        --scripts 'set -eu; docker stop --time 120 investment-oracle >/dev/null; echo INVESTMENT_ORACLE_STOPPED' \
        --query 'value[].message' -o tsv)"
      [[ "$result" == *INVESTMENT_ORACLE_STOPPED* ]] || die 'Oracle no confirmó el apagado; no se desasigna la VM.'
    elif [[ "$power" != PowerState/stopped ]]; then
      die "VM en transición ($power); espera a que termine antes de detenerla."
    fi
    az vm deallocate -g "$VANKOO_RG" -n "$VM" -o none
    echo 'Solo Investment detenido y VM desasignada. Disco e IP siguen facturándose.'
    ;;
  start)
    az vm start -g "$VANKOO_RG" -n "$VM" -o none
    # A container stopped explicitly by stop does not restart automatically.
    result="$(az vm run-command invoke -g "$VANKOO_RG" -n "$VM" --command-id RunShellScript \
      --scripts 'set -eu; docker start investment-oracle >/dev/null; for i in $(seq 1 100); do if [ "$(docker inspect --format "{{.State.Health.Status}}" investment-oracle)" = healthy ]; then echo INVESTMENT_ORACLE_HEALTHY; exit 0; fi; sleep 10; done; exit 1' \
      --query 'value[].message' -o tsv)"
    [[ "$result" == *INVESTMENT_ORACLE_HEALTHY* ]] || die 'Oracle no está saludable; Investment permanece detenido.'
    container_app_action "$APP" start
    ;;
  status)
    az containerapp show -g "$VANKOO_RG" -n "$APP" \
      --query '{app:name,status:properties.runningStatus,revision:properties.latestReadyRevisionName,outbound:properties.outboundIpAddresses}' -o json
    az vm get-instance-view -g "$VANKOO_RG" -n "$VM" --query 'instanceView.statuses[].displayStatus' -o tsv
    ;;
  *) die "Acción desconocida: $ACTION" ;;
esac
