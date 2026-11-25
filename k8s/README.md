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
scripts/aks/aks-up.sh --yes       # capa terraform/aks (3 nodos) + ingress-nginx con nombre DNS de Azure
scripts/aks/aks-email.sh --yes    # capa terraform/email: Azure Communication Services (opcional; sin ella, Mailpit)
scripts/aks/aks-build.sh          # imágenes linux/amd64 en el ACR (ACR Tasks), etiquetas <sha> y «aks»
scripts/aks/aks-deploy.sh         # Secret y ConfigMaps desde el .env (sin imprimir) + overlay azure
scripts/aks/aks-platform.sh       # cert-manager (HTTPS), Argo CD y monitoreo (versiones fijadas)
scripts/aks/aks-stop.sh           # pausa: apaga los nodos, conserva los discos
scripts/aks/aks-destroy.sh --yes  # borra el clúster y sus datos (no toca Container Apps ni el ACR)
```

`aks-build.sh` empaqueta el **último commit** de la rama que tenga cada repo junto a
`vankoo-infra` (`git archive HEAD`); después de construir, `aks-deploy.sh --restart` hace que los
pods bajen la etiqueta `aks` nueva.

### El overlay `azure`

- **Imágenes del ACR** con la etiqueta `aks`, y la **web MYPE** dentro del clúster
  (`web.yaml`, imagen de `vankoo-mype-web`).
- **Un solo origen, en HTTPS:** **https://vankoo-liquilabs.centralus.cloudapp.azure.com**. Es el
  nombre DNS que Azure da a la IP del ingress-nginx (`AKS_DNS_LABEL` en `scripts/aks/lib.sh`).
  cert-manager pide y renueva el certificado de Let's Encrypt (reto HTTP-01) y HTTP redirige a
  HTTPS. `/<servicio>/api`, `/scalar` y `/v3/api-docs` van al API Gateway y el resto a
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
Argo CD no toca lo que no está en Git (el Secret y los ConfigMaps del despliegue).

**Volver atrás = revertir el commit** (`git revert` y push). Con el sync automático, Argo CD
no deja usar «History and rollback» desde su interfaz, y un `kubectl rollout undo` lo
desharía `selfHeal`. Git es la única fuente de verdad también para la reversión.

**Simulacro (24 nov 2026, hora de Lima):** se publicó una versión rota de la web (una
imagen que no existe) y se revirtió.

| Hora | Commit | Argo CD | Web pública |
|---|---|---|---|
| 20:31:05 | `00c83dc`: imagen `mype-web:rollback-drill` | Synced / Progressing: el pod nuevo queda en `ErrImagePull` → `ImagePullBackOff` | 200: sigue el pod anterior |
| 20:31:42 | `405c2a2`: `git revert` | OutOfSync → Synced / Healthy en 12 s; el pod roto se elimina | 200 |

La web no dejó de responder: el rolling update (`maxSurge: 1`, `maxUnavailable: 0`) no
retira el pod viejo hasta que el nuevo esté listo. El historial de Argo CD guarda las dos
revisiones (6 y 7). Para repetirlo: cambiar un `newTag` de `overlays/azure/kustomization.yaml`,
hacer push, mirar el estado y revertir.

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

### Correo (Azure Communication Services)

La capa `terraform/email` crea Communication Services con un **dominio administrado por Azure**
(`DoNotReply@….azurecomm.net`, verificado al crearse). Si existe, `aks-deploy.sh` pone
`EMAIL_PROVIDER=acs` en el ConfigMap `vankoo-deploy`, el remitente en `MAIL_FROM` y la cadena de
conexión en `vankoo-secrets` (`ACS_CONNECTION_STRING`). Notification (avisos) e IAM
(recuperación de contraseña) envían entonces por la **API REST de ACS**, firmada con la clave de
acceso (HMAC). No se usa el SMTP de ACS porque exige registrar una app de Entra, y el tenant de la
universidad no lo permite. Sin la capa, todo va a Mailpit como en local. El dominio administrado
tiene límites de envío bajos: sirve para la demo, no para producción.

### Push (Firebase Cloud Messaging)

Si el `.env` de vankoo-infra trae la cuenta de servicio de Firebase (`FIREBASE_PROJECT_ID`,
`FIREBASE_CLIENT_EMAIL` y `FIREBASE_PRIVATE_KEY`, con los saltos de línea de la clave escritos como
`\n`), `aks-deploy.sh` pone `PUSH_PROVIDER=firebase` en `vankoo-deploy` y las tres claves en
`vankoo-secrets`. Notification envía entonces los avisos por FCM a la app Android, que registra su
dispositivo al iniciar sesión. Si no las trae, los push solo se escriben en el log. El secreto de
los topics sale de `NOTIFICATION_PUSH_TOPIC_SECRET` si existe. iOS necesita además APNs (cuenta de
Apple Developer).

### KYC del inversionista (función DNI)

Si existe la capa `terraform/functions` (la función serverless de verificación de DNI, en Azure
Functions), `aks-deploy.sh` lee su URL de Terraform y su clave con `az functionapp keys list` (sin
imprimirla), y Profile verifica el DNI de cada inversionista al completar su perfil: `VERIFIED`
si el DNI existe y los nombres coinciden, rechazo con el motivo si no (`NOT_FOUND`,
`NAME_MISMATCH`), y revisión manual si la función no responde. La función tiene que estar
encendida (`az functionapp start`).

**Fuente de datos.** Desde el 25 nov 2026 la función consulta **API Perú** (`dni_provider =
apiperu`, token en el `.env` como `APIPERU_TOKEN`; ver `docs/funciones-serverless.md`):

```bash
# desde vankoo-infra; el token se lee del .env sin imprimirlo
bash -c 'source scripts/aks/lib.sh; export TF_VAR_apiperu_token="$(env_value .env APIPERU_TOKEN)";
         setup_terraform_env; tf_apply functions -var dni_provider=apiperu'
```

- **Con datos reales:** solo se verifica un DNI real con el nombre de su titular. Para la demo,
  usar el DNI de alguien del equipo que lo acepte; no probar números «inventados», que pueden ser
  de personas reales.
- **Plan gratuito:** 100 consultas al mes.
- **Cuidado:** un `azure-deploy.sh` (o un `tf_apply functions`) sin esas variables devuelve la
  función a `fake`, con los DNIs de demostración (`12345678` = «Juan Carlos» / «Pérez Gómez»).

### Licencia de Axon Server

La imagen de Axon Server sin licencia se apaga a las 12 horas. En AKS se conecta a Axoniq
Platform, que le da y le renueva la licencia: el valor `<environment-id>:<access-token>` (en
platform.axoniq.io, guía de Axon Server con «Platform connection» y el token del espacio de
trabajo) va en el `.env` como `AXONIQ_PLATFORM_AUTHENTICATION`, y `aks-deploy.sh` lo pone en
`vankoo-secrets`. Aun sin licencia, los datos de Axon (control, eventos y registro) están en su
disco y sobreviven al reinicio.

### Stripe en AKS

Stripe avisa de los pagos directamente a AKS: el endpoint de webhook está registrado en la cuenta
de prueba de Stripe de Vankoo, apuntando a
`https://<host>/finance/api/v1/payment-providers/stripe/webhooks` (un Ingress aparte que quita el
prefijo `/finance`) con los eventos `checkout.session.completed`, `…async_payment_succeeded`,
`…async_payment_failed` y `…expired`. Su secreto de firma va en el `.env` como
`AKS_STRIPE_WEBHOOK_SECRET`, y `aks-deploy.sh` lo pone en `vankoo-secrets` como
`STRIPE_WEBHOOK_SECRET` (el `STRIPE_WEBHOOK_SECRET` del `.env` es el de `stripe listen`, solo para
el compose local). No hace falta ninguna máquina reenviando eventos.

### Validado en AKS (24 nov 2026)

Kubernetes 1.36, 3 nodos (2× D2s_v3 y 1× D2s_v4). Los 21 pods de Vankoo están sanos. Flujo
completo por la IP pública con cuentas nuevas:
1. registro y KYC de la MYPE (verificada por Risk);
2. factura → OCR → aprobada → riesgo A → cotización aceptada → publicada;
3. recarga del inversionista con Stripe (modo prueba) por el webhook;
4. inversión → subasta fondeada → adelanto a la MYPE → factura «Fondeada».

Argo CD aplicó solo un commit del overlay, y Prometheus mide la disponibilidad y el p95 del
API.

## Control de acceso (RBAC)

**Workloads: una ServiceAccount por pod, sin token** (`base/rbac/service-accounts.yaml`).
Ningún servicio de Vankoo llama a la API de Kubernetes, así que cada Deployment y StatefulSet
corre con su propia cuenta y `automountServiceAccountToken: false`: un contenedor comprometido
no encuentra en `/var/run/secrets/kubernetes.io/serviceaccount` credenciales para hablar con el
clúster. Ninguna de esas cuentas tiene Role. La `default` del namespace también queda sin token,
para que un pod nuevo que no declare su cuenta no lo reciba.

**Personas: dos Roles en el namespace `vankoo`** (`base/rbac/roles.yaml`).

| Role | Grupo | Puede | No puede |
|---|---|---|---|
| `vankoo-viewer` | `vankoo:viewers` | ver pods, logs, Deployments, Services, HPA, Ingress y eventos | leer Secrets; cambiar nada |
| `vankoo-operator` | `vankoo:operators` | lo del viewer, más `rollout restart`, `scale`, borrar un pod y `port-forward` | leer Secrets, `exec`, crear o borrar Deployments (eso lo hace Argo CD desde Git) |

Hoy nadie pertenece a esos grupos: el clúster todavía usa cuentas locales (ver «Riesgos
aceptados»). Los Roles quedan listos para enlazarlos a grupos de Entra ID. Se comprueban
suplantando el grupo:

```bash
kubectl -n vankoo exec deploy/iam-service -- ls /var/run/secrets/kubernetes.io/serviceaccount  # No such file or directory
kubectl auth can-i list secrets -n vankoo --as=system:serviceaccount:vankoo:iam-service          # no
kubectl auth can-i get pods --subresource=log -n vankoo --as=demo --as-group=vankoo:viewers      # yes
kubectl auth can-i get secrets -n vankoo --as=demo --as-group=vankoo:viewers                      # no
kubectl auth can-i patch deployments -n vankoo --as=demo --as-group=vankoo:operators              # yes
kubectl auth can-i update deployments --subresource=scale -n vankoo --as=demo --as-group=vankoo:operators  # yes
kubectl auth can-i create pods --subresource=exec -n vankoo --as=demo --as-group=vankoo:operators          # no
```

Los subrecursos (`log`, `scale`, `exec`, `portforward`) se piden con `--subresource`: escrito como
`pods/log`, `kubectl auth can-i` lo lee como un pod llamado «log» y responde por el permiso equivocado.

## Riesgos aceptados

### Las personas entran al clúster con cuentas locales, sin Microsoft Entra ID

**Qué se acepta.** El clúster no tiene integrado Entra ID (`azure_active_directory_role_based_access_control`)
y conserva las cuentas locales. Quien tiene un rol de Azure sobre el grupo de recursos obtiene con
`az aks get-credentials` un certificado de administrador: los Roles por namespace de
`base/rbac/roles.yaml` no se le aplican.

**Por qué.** Activar Entra ID en AKS no se puede deshacer, obliga a todo el equipo a usar
`kubelogin` y cambia cómo entran los scripts `aks-*.sh`. Con el crédito de Azure for Students
casi agotado, no se arriesga un cambio de acceso irreversible antes de la entrega final.

**Qué lo mitiga.**
- Solo los integrantes del equipo tienen rol sobre el grupo de recursos.
- Los cambios al namespace `vankoo` se hacen por Git: Argo CD revierte (`selfHeal`) lo que se cambie a mano.
- Los pods no tienen token de la API, así que una aplicación comprometida no hereda esos permisos.

**Plan para producción.** Entra ID con Azure RBAC y `local_account_disabled = true`; los roles
*AKS RBAC Reader* y *Writer* asignados por namespace a grupos de Entra (o los RoleBindings de
`roles.yaml` apuntando a esos grupos), y *Cluster Admin* solo para quien opera la plataforma.

### El API server de AKS no limita las IP de origen (Trivy AVD-AZU-0041, CRITICAL)

**Qué se acepta.** El clúster `vankoo-aks-…` acepta conexiones a su API server desde cualquier
IP: no define `api_server_access_profile.authorized_ip_ranges`. La línea `#trivy:ignore:AVD-AZU-0041`
de `terraform/aks/main.tf` lo excluye **solo para ese recurso**.

**Por qué.** El equipo administra el clúster con `kubectl` (capturas, HPA, Grafana y Argo CD por
port-forward) desde redes domésticas con IP dinámicas. Una lista fija los dejaría fuera, y un
clúster privado exige una VM de salto y una red virtual que hoy no tenemos.

**Qué lo mitiga.**
- Para obtener el kubeconfig (`az aks get-credentials`) hace falta un rol de Azure sobre el grupo de recursos (ver el riesgo anterior: ese kubeconfig es de administrador).
- El tráfico va cifrado con TLS.
- No hay servicios internos expuestos: Argo CD, Grafana y las bases solo se alcanzan por port-forward, y las NetworkPolicies limitan el tráfico entre pods.

**Plan para producción.** `authorized_ip_ranges` con las IP de una VPN corporativa, o un clúster privado con un bastión, más Microsoft Entra ID con Kubernetes RBAC y sin cuentas locales (`local_account_disabled = true`).

