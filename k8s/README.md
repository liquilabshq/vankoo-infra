# Kubernetes

Manifiestos de Vankoo para Kubernetes, organizados con Kustomize:

```
k8s/
├── base/                 # todo lo común a cualquier clúster
│   ├── namespace.yaml    # namespace vankoo
│   ├── apps/             # 9 microservicios: Deployment + Service (+ HPA)
│   ├── data/             # 10 almacenes y brokers: StatefulSet + Service + PVC
│   ├── network/          # Ingress del gateway y NetworkPolicies
│   └── kustomization.yaml  # ConfigMap vankoo-config (valores no secretos)
├── overlays/
│   ├── local/            # clúster local (kind): Secret con valores de desarrollo
│   └── azure/            # Azure Kubernetes Service (capa terraform/aks)
├── argocd/               # Argo CD: valores del chart y la aplicación «vankoo» (GitOps)
└── monitoring/           # kube-prometheus-stack, SLO, alertas, dashboard y runbook
```

## Decisiones

- **Los Services se llaman igual que los hostnames del `docker-compose.yaml`** (`iam-db-postgres`, `kafka-broker`, `discovery-server`…). Así cada microservicio usa su perfil `docker` sin cambios dentro del clúster.
- **Microservicios (Deployment):** `RollingUpdate` con `maxUnavailable: 0` (no se pierde capacidad durante un despliegue), `requests`/`limits` de CPU y memoria, sondas `startup`, `readiness` y `liveness` en los endpoints de salud de cada stack (Actuator, `/health/ready` de .NET y Python, TCP en Profile), contenedor sin escalada de privilegios y sin capacidades.
- **HPA** de 1 a 3 réplicas al 70 % de CPU en gateway, IAM, Investment, Profile e Invoicing. Finance, Risk y Notification se quedan en 1: Finance por Axon (un solo procesador de eventos por grupo), Risk porque el consumidor de Kafka y el repartidor del outbox viven en el mismo proceso, y Notification porque su idempotencia es en memoria.
- **Datos (StatefulSet + PVC):** un almacén por servicio, como en el compose. Los Services de datos publican direcciones aún no listas: Kafka en modo KRaft habla con su propio controlador por `kafka-broker:9093` antes de estar listo.
- **Red:** solo el `api-gateway` recibe tráfico desde fuera del namespace (el Ingress); el resto solo acepta tráfico de pods del propio namespace.
- **Secretos:** los manifiestos solo los referencian (`vankoo-secrets`). El overlay `local` los genera con los mismos valores de desarrollo que el compose; un overlay de nube los tomaría de Key Vault (por ejemplo con el CSI driver o External Secrets), nunca de Git.

## Probar en local con kind

```bash
kind create cluster --name vankoo --config <archivo con extraPortMappings 80→8880 y la etiqueta ingress-ready=true>
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/kind/deploy.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
#   (en kind, metrics-server necesita el argumento --kubelet-insecure-tls)

# Las imágenes son las que construye docker compose (vankoo-<servicio>:latest)
kind load docker-image vankoo-iam-service:latest --name vankoo   # una por servicio

kubectl apply -k k8s/overlays/local
curl -H "Host: api.vankoo.localhost" http://localhost:8880/iam/api/v1/authentication/sign-in …
```

### Validado (16 nov 2026, kind con Kubernetes 1.37.0 y 8 GB para Docker)

- `kubectl apply --dry-run=server` de todo el overlay sin errores.
- Desplegados y sanos: discovery, gateway, IAM, Profile e Invoicing, con PostgreSQL (IAM y Profile), MongoDB, MinIO, Kafka y Mailpit.
- Por el Ingress: registro e inicio de sesión (201 y token), ruta protegida sin token → 401, `GET /profile/api/v1/companies/me` con la empresa que Profile creó a partir del evento de IAM por Kafka, y `GET /invoicing/api/v1/invoices` → 200.
- Los HPA leen métricas (gateway 15 %, IAM 4 % de CPU en reposo).

### Sin validar en kind (sí en AKS, ver abajo)

- **Investment + Oracle, Finance + Axon Server, Risk y Notification**: los manifiestos pasan el dry-run, pero no se levantaron (Oracle pide ~2 GB y no cabían junto al resto en 8 GB; la imagen de Notification no estaba construida en esta máquina).
- **MinIO:** la etiqueta `minio/minio:RELEASE.2025-09-07T16-13-09Z` (la misma del compose) **ya no está en Docker Hub**: el repositorio `minio/minio` no devuelve etiquetas. Para la prueba se reetiquetó la copia local. Hay que decidir el reemplazo (otra distribución de MinIO o un almacenamiento compatible con S3) **también para el compose**.

## Desplegar en Azure (AKS)

Convive con el despliegue en Container Apps (`terraform/{core,base,data,messaging,apps}` y
`scripts/azure/`), que no cambia: AKS solo lee el sufijo de `core` y el ACR de `base`. Los datos
viven dentro del clúster (StatefulSets con discos de Azure), no en las bases administradas.

```bash
scripts/aks/aks-up.sh --yes       # capa terraform/aks (3 nodos) + ingress-nginx; imprime la IP pública
scripts/aks/aks-build.sh          # imágenes linux/amd64 en el ACR (ACR Tasks), etiquetas <sha> y «aks»
scripts/aks/aks-deploy.sh         # Secret y ConfigMaps desde el .env (sin imprimir) + overlay azure
scripts/aks/aks-platform.sh       # Argo CD + monitoreo (versiones fijadas)
scripts/aks/aks-stop.sh           # pausa: apaga los nodos, conserva los discos
scripts/aks/aks-destroy.sh --yes  # borra el clúster y sus datos (no toca Container Apps ni el ACR)
```

`aks-build.sh` empaqueta el **último commit** de la rama que tenga cada repo junto a
`vankoo-infra` (`git archive HEAD`); después de construir, `aks-deploy.sh --restart` hace que los
pods bajen la etiqueta `aks` nueva.

### El overlay `azure`

- **Imágenes del ACR** con la etiqueta `aks`, y la **web MYPE** dentro del clúster
  (`web.yaml`, imagen de `vankoo-mype-web`).
- **Un solo origen.** El Ingress no tiene host, así que vale la IP pública o cualquier dominio
  que apunte a ella. `/<servicio>/api`, `/scalar` y `/v3/api-docs` van al API Gateway y el resto a
  la web. El webhook de Stripe va directo a Finance con su propio Ingress, que quita el prefijo
  `/finance`.
- **Archivos en el S3 real**, como en Container Apps: no se despliega MinIO.
- **Fuera de Git**, los crea `aks-deploy.sh`:
  - Secret `vankoo-secrets`: las contraseñas de las bases se generan la primera vez y se
    reutilizan; las claves externas salen del `.env`;
  - ConfigMap `vankoo-deploy`: URL pública y bucket de certificados;
  - ConfigMap `kyc-demo-ca`, el **parche temporal** de las demos del KYC.
- **Ajustes a los límites de Azure:**
  - un D2s_v3 admite **4 discos**, así que Mailpit usa un volumen temporal;
  - `fsGroup` para Oracle (54321) y Kafka (1000);
  - Oracle monta una subcarpeta del disco, porque la raíz trae `lost+found`;
  - un `initContainer` copia al disco la base que trae la imagen *faststart*: Kubernetes, a
    diferencia de Docker, no copia el contenido de la imagen a un volumen nuevo;
  - el disco de Risk es de 10 Gi, porque el padrón de SUNAT tiene unos 18,5 millones de filas
    y tarda unos 20 minutos en cargarse.

### GitOps con Argo CD (`argocd/`)

La aplicación `vankoo` mantiene el namespace igual que `k8s/overlays/azure` en GitHub, con
sync automático, `prune` y `selfHeal`: **un commit en el overlay o en la base se despliega solo**.
Para volver atrás: «History and rollback» en Argo CD, o revertir el commit. Argo CD no toca
lo que no está en Git (el Secret y los ConfigMaps del despliegue).

### Monitoreo (`monitoring/`)

- **Herramientas:** Prometheus, Alertmanager, Grafana, node-exporter y kube-state-metrics, en
  versión ligera (sin discos, retención de 2 días).
- **SLI:** salen del API Gateway, que todas las peticiones cruzan (`/actuator/prometheus`).
- **SLO:** 99 % de peticiones sin 5xx, y p95 por debajo de 1 s.
- **Alertas:** consumo rápido del presupuesto de errores, latencia, pods que se reinician,
  servicios sin réplicas, bases o brokers caídos y nodos sin memoria. Cada alerta enlaza a su
  entrada de `monitoring/RUNBOOK.md`.
- **Dashboard:** «Vankoo · Visión general».

Acceso sin exponerlos a internet:

```bash
kubectl -n argocd port-forward svc/argocd-server 8081:80              # usuario admin
kubectl -n monitoring port-forward svc/monitoring-grafana 3002:80     # usuario admin
```

Las contraseñas están en los Secrets `argocd-initial-admin-secret` y `monitoring-grafana`.

### Stripe en AKS

El webhook de prueba llega con `stripe listen --forward-to http://<IP>/finance/api/v1/payment-providers/stripe/webhooks`.
Su `whsec` tiene que ir en `vankoo-secrets` (`STRIPE_WEBHOOK_SECRET`), seguido de
`kubectl -n vankoo rollout restart deploy/finance-service`. `aks-deploy.sh` lo vuelve a poner
con el valor del `.env`.

### Validado en AKS (24 nov 2026)

Kubernetes 1.36, 3 nodos (2× D2s_v3 y 1× D2s_v4). Los 21 pods de Vankoo están sanos. Flujo
completo por la IP pública con cuentas nuevas:
1. registro y KYC de la MYPE (verificada por Risk);
2. factura → OCR → aprobada → riesgo A → cotización aceptada → publicada;
3. recarga del inversionista con Stripe (modo prueba) por el webhook;
4. inversión → subasta fondeada → adelanto a la MYPE → factura «Fondeada».

Argo CD aplicó solo un commit del overlay, y Prometheus mide la disponibilidad y el p95 del
API.
