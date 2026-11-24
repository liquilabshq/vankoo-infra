#!/usr/bin/env bash
# Pausa el clúster de AKS: apaga los nodos (dejan de cobrar) y conserva los discos
# de las bases y la configuración. Para reanudar: scripts/aks/aks-up.sh (arranca
# el clúster) y, si hace falta, scripts/aks/aks-deploy.sh.
#
# Mientras está detenido siguen cobrando poco: los discos de los nodos y de las
# bases, y la IP pública del balanceador.
#
# Uso: scripts/aks/aks-stop.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools az terraform
setup_terraform_env
tf_init aks
name="$(aks_name)" || die "No hay clúster"

state="$(aks_power_state)"
if [[ "$state" == "Stopped" ]]; then
  echo "El clúster ya estaba detenido."
  exit 0
fi
log "Deteniendo $name (unos minutos)"
az aks stop -g "$VANKOO_RG" -n "$name" --only-show-errors
log "Clúster detenido"
