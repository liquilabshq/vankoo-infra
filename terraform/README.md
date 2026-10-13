# Vankoo en Azure con Terraform

Despliegue de Vankoo en Azure Container Apps. Todo vive en el grupo de recursos
`liquilabs-vankoo`, región Central US. Se enciende antes de una expo y se apaga
después.

## Requisitos

- Acceso al grupo `liquilabs-vankoo` (lo da el dueño de la suscripción).
- `az` con sesión iniciada (`az login`), `terraform` ≥ 1.9 y Docker con `buildx`.
- Los repos de los servicios clonados junto a `vankoo-infra`, como para el compose.
- En Windows, ejecutar los scripts desde Git Bash o WSL.

## Uso

```bash
scripts/azure/azure-deploy.sh --env-file .env   # crear, actualizar o reanudar
scripts/azure/azure-stop.sh                     # pausa corta: detiene y conserva los datos
scripts/azure/azure-destroy.sh                  # pausa larga: borra todo, coste 0
```

| | `azure-stop.sh` | `azure-destroy.sh` |
|---|---|---|
| Datos (usuarios, facturas…) | Se conservan | Se pierden |
| URL del gateway | La misma | La misma |
| Volver a encender | Un par de minutos | Unos 20 minutos |
| Coste mientras tanto | El registro (~$5/mes) y el disco de cada PostgreSQL | Nada |
| Ojo | Azure vuelve a encender los PostgreSQL solos a los 7 días | — |

`azure-deploy.sh` crea el estado si no existe, arranca lo que `azure-stop.sh`
hubiera detenido, aplica las capas, construye las imágenes para x86 desde la
rama que tenga cada repo y las sube al registro. Terraform enseña el plan de
cada capa y pide `yes`; con `--yes` no pregunta. Con `--skip-build` reutiliza
las últimas imágenes (no sirve tras un `azure-destroy.sh`: el registro es nuevo
y está vacío).

Para subir una versión nueva de un servicio, basta con volver a ejecutar
`azure-deploy.sh --env-file .env`: reconstruye las imágenes y Terraform solo
actualiza las apps cuya imagen cambió.

`--env-file` toma del `.env` solo las credenciales del bucket de S3 de
Invoicing (`AWS_REGION`, `AWS_S3_BUCKET`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`). El resto de secretos (contraseñas de las bases de
datos, clave JWT, clave del OCR) los genera Terraform y se los pasa a las apps:
nadie tiene que copiarlos.

### Los scripts

| Script | Cuándo se usa |
|---|---|
| `azure-deploy.sh` | A mano: crear, actualizar o reanudar |
| `azure-stop.sh` | A mano: detener sin borrar |
| `azure-destroy.sh` | A mano: borrar todo menos la capa `core`. Con `--all` también la borra (y la URL del gateway cambia) |
| `build-push.sh` | Lo llama `azure-deploy.sh`. A mano solo para construir y subir imágenes sin aplicar nada |
| `bootstrap-state.sh` | Lo llama `azure-deploy.sh`. Crea la cuenta del estado la primera vez; si ya existe, no hace nada |
| `lib.sh` | Nunca: son funciones que cargan los demás scripts |

## Capas

| Capa | Qué crea | Con `azure-destroy.sh` |
|---|---|---|
| `core` | El sufijo de los nombres únicos, el OCR (Document Intelligence F0), el workspace de logs y el Container Apps Environment | Se conserva: sin apps no cuesta nada, y conservar el environment mantiene la URL del gateway |
| `base` | Registro de imágenes | Se destruye |
| `data` | Una base de datos por servicio: PostgreSQL de IAM, MongoDB de Invoicing | Se destruye |
| `apps` | Una Container App por servicio | Se destruye |

Solo el gateway acepta tráfico de internet. Los servicios tienen ingress interno
y el gateway los alcanza por el DNS del environment (`http://vankoo-iam-service`):
en Azure no hay Eureka. El estado de Terraform vive en la cuenta de
almacenamiento `vankootf…` del mismo grupo, que ningún script borra.

## Añadir un servicio

1. Su base de datos en `data/main.tf` y sus datos de conexión en `data/outputs.tf`.
2. Su Container App en `apps/main.tf`, copiando la de IAM (Java) o la de
   Invoicing (.NET), con ingress interno.
3. Su ruta en el gateway: la variable `<SERVICIO>_SERVICE_URI` en la app del
   gateway (`http://<nombre-de-la-app>`).
4. Su repo en la lista `SERVICES` de `scripts/azure/build-push.sh`.

Si el servicio guarda datos solo dentro de su contenedor (Kafka, Axon u Oracle
sin disco persistente), añade a su Container App
`tags = { "vankoo-data" = "ephemeral" }`. Así `azure-stop.sh` avisa de que esos
datos se perderán antes de detener nada.

## Trampas conocidas

- **El environment va con `azapi`, no con `azurerm`.** Si no se pide el modo
  explícitamente, Azure crea un environment Express (sin DNS interno), y
  `azurerm` no tiene ese campo.
- **Central US a veces no tiene capacidad** para environments nuevos
  (`ManagedEnvironmentCapacityHeavyUsageError`). Reintentar suele bastar.
- **Invoicing usa `/health/live` como sonda de readiness** mientras no haya
  Kafka en Azure: su chequeo de Kafka espera 60 s sin broker. Volver a
  `/health/ready` al desplegar Kafka.
- Si cambias los providers de una capa, ejecuta `terraform init -upgrade` en ella.
