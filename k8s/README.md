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
└── overlays/
    └── local/            # clúster local (kind): Secret con valores de desarrollo
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

### Sin validar todavía

- **Investment + Oracle, Finance + Axon Server, Risk y Notification**: los manifiestos pasan el dry-run, pero no se levantaron (Oracle pide ~2 GB y no cabían junto al resto en 8 GB; la imagen de Notification no estaba construida en esta máquina).
- **MinIO:** la etiqueta `minio/minio:RELEASE.2025-09-07T16-13-09Z` (la misma del compose) **ya no está en Docker Hub**: el repositorio `minio/minio` no devuelve etiquetas. Para la prueba se reetiquetó la copia local. Hay que decidir el reemplazo (otra distribución de MinIO o un almacenamiento compatible con S3) **también para el compose**.

## Pendiente para el Trabajo Final

- Overlay `aks` (o el proveedor que se elija) con las imágenes del ACR por versión semántica, réplicas y secretos desde Key Vault.
- Entrega continua con GitOps (Argo CD o Flux) apuntando a este directorio, con promoción entre ambientes y rollback.
