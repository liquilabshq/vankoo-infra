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
scripts/azure/azure-stop.sh                     # pausa corta: detiene y conserva los datos (borra el Event Hubs)
scripts/azure/azure-destroy.sh                  # pausa larga: borra todo, coste 0
```

| | `azure-stop.sh` | `azure-destroy.sh` |
|---|---|---|
| Datos (usuarios, facturas…) | Se conservan | Se pierden |
| Event Hubs | Se destruye: se pierden los eventos sin leer | Se destruye |
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

Para subir una versión nueva del gateway, basta con volver a ejecutar
`azure-deploy.sh --env-file .env`: reconstruye las imágenes y Terraform solo
actualiza las apps cuya imagen cambió.

IAM, Invoicing y Profile no se actualizan así: cada merge a `develop` de su repo dispara
su pipeline, que construye la imagen, la publica en el registro y la despliega
(workflow reutilizable `.github/workflows/deliver-container-app.yml` de este
repo). Por eso sus Container Apps llevan `ignore_changes` sobre la imagen:
Terraform la pone al crearlas y después no la toca. El pipeline entra en Azure
con OIDC, como la identidad administrada `vankoo-github-ci`, que solo puede
subir imágenes al registro y actualizar esas apps.

`--env-file` toma del `.env` solo las credenciales de los dos buckets de S3, que
son distintos y pueden ser de cuentas de AWS distintas:
- **Invoicing:** `AWS_REGION`, `AWS_S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.
- **Profile:** `PROFILE_AWS_REGION`, `PROFILE_AWS_S3_BUCKET`, `PROFILE_AWS_ACCESS_KEY_ID`,
  `PROFILE_AWS_SECRET_ACCESS_KEY`.

Cada `apply` de `apps` vuelve a escribir esos valores en las Container Apps: si
el `.env` de quien despliega tiene otro bucket, Terraform lo cambiará (revisa el
plan de Invoicing). El resto de secretos (contraseñas de las bases de
datos, clave JWT, clave del OCR) los genera Terraform y se los pasa a las apps:
nadie tiene que copiarlos.

### Los scripts

| Script | Cuándo se usa |
|---|---|
| `azure-deploy.sh` | A mano: crear, actualizar o reanudar |
| `azure-stop.sh` | A mano: detener sin borrar datos. Solo destruye la capa `messaging` |
| `azure-destroy.sh` | A mano: borrar todo menos la capa `core`. Con `--all` también la borra (y la URL del gateway cambia) |
| `build-push.sh` | Lo llama `azure-deploy.sh`. A mano solo para construir y subir imágenes sin aplicar nada |
| `bootstrap-state.sh` | Lo llama `azure-deploy.sh`. Crea la cuenta del estado la primera vez; si ya existe, no hace nada |
| `lib.sh` | Nunca: son funciones que cargan los demás scripts |

## Capas

| Capa | Qué crea | Con `azure-destroy.sh` |
|---|---|---|
| `core` | El sufijo de los nombres únicos, el OCR (Document Intelligence F0), el workspace de logs y el Container Apps Environment | Se conserva: sin apps no cuesta nada, y conservar el environment mantiene la URL del gateway |
| `functions` | La función serverless de verificación de DNI (Azure Functions con plan Flex Consumption, Application Insights) | Se conserva (se destruye con `--all`): parada no cuesta, y así mantiene su URL, su clave y el código publicado |
| `base` | Registro de imágenes | Se destruye |
| `data` | Una base de datos por servicio: PostgreSQL de IAM y de Profile, MongoDB de Invoicing | Se destruye |
| `messaging` | El broker de eventos: un namespace de Azure Event Hubs, un event hub por topic y una regla de acceso por servicio | Se destruye (también con `azure-stop.sh`) |
| `apps` | Una Container App por servicio | Se destruye |

El código de la función no lo despliega Terraform sino el workflow `deploy.yml` de
`vankoo-dni-verification-function`; ver `docs/funciones-serverless.md`.

Solo el gateway acepta tráfico de internet. Los servicios tienen ingress interno
y el gateway los alcanza por el DNS del environment (`http://vankoo-iam-service`):
en Azure no hay Eureka. El estado de Terraform vive en la cuenta de
almacenamiento `vankootf…` del mismo grupo, que ningún script borra.

## Mensajería: Azure Event Hubs

En local los servicios se envían eventos por el Kafka del compose. En Azure ese
papel lo hace la capa `messaging`, un namespace de **Azure Event Hubs** que habla
el protocolo de Kafka: los servicios usan el mismo cliente y solo cambian la
dirección y la autenticación.

| Kafka (compose) | Event Hubs (Azure) |
|---|---|
| Broker `kafka-broker:9094` | Namespace `vankoo-events-<sufijo>.servicebus.windows.net:9093` |
| Topic | Event hub, con el mismo nombre |
| Sin autenticación (PLAINTEXT) | TLS + SASL PLAIN: usuario `$ConnectionString`, contraseña la cadena de conexión |
| Los topics se crean al publicar | Los crea Terraform: los clientes no pueden (`auto-create-topics: false`) |

- **Nivel Standard, 1 unidad de rendimiento.** Es el más barato con endpoint de
  Kafka (el Basic no lo tiene) y admite hasta 10 event hubs; Vankoo usa 8, en
  `locals.topics` de `messaging/main.tf`. Un topic nuevo se añade ahí.
- **Una regla de acceso por servicio** (`locals.clients`), con permiso para enviar
  y escuchar, no para administrar. Su cadena de conexión llega a cada Container
  App como el secreto `kafka-connection-string`.
- **Coste.** Cobra por hora aunque no haya tráfico (unidad de rendimiento más
  endpoint de Kafka, unos 0.12 USD/h en Central US) y no se puede pausar. Por eso
  `azure-stop.sh` destruye la capa y `azure-deploy.sh` la vuelve a crear con el
  mismo nombre, antes de la capa `apps`.
- **Al recrearlo cambian las claves** (no la dirección): `azure-deploy.sh` las
  vuelve a escribir en las Container Apps al aplicar `apps`.
- **Retención de un día y una partición por topic.** Basta para una demo y
  conserva el orden de los eventos de cada topic.
- Configuración de cliente que pide Event Hubs: `request.timeout.ms` de al menos
  60000, `metadata.max.age.ms` y `connections.max.idle.ms` por debajo de 240000
  (Azure cierra las conexiones inactivas a los 4 minutos) y solo compresión
  `gzip` o ninguna. Ver
  [Kafka client configurations for Event Hubs](https://learn.microsoft.com/en-us/azure/event-hubs/apache-kafka-configurations).

Servicios conectados: Profile. IAM, Invoicing, Finance, Investment y
Notification se conectan en las siguientes fases.

## Añadir un servicio

1. Su base de datos en `data/main.tf` y sus datos de conexión en `data/outputs.tf`.
2. Su Container App en `apps/main.tf`, copiando la de IAM (Java) o la de
   Invoicing (.NET), con ingress interno.
3. Su ruta en el gateway: la variable `<SERVICIO>_SERVICE_URI` en la app del
   gateway (`http://<nombre-de-la-app>`).
4. Su repo en la lista `SERVICES` de `scripts/azure/build-push.sh`.
5. Si se despliega desde su propio pipeline: `ignore_changes` sobre la imagen
   en su Container App, una credencial federada en `vankoo-github-ci` por cada
   sujeto (`repo:liquilabshq@<id-org>/<repo>@<id-repo>:ref:refs/heads/develop`
   y `repo:liquilabshq@<id-org>/<repo>@<id-repo>:environment:development`), el
   rol Contributor sobre su Container App y un job que llame a
   `deliver-container-app.yml`. GitHub firma el token con los ids numéricos de
   la organización y del repo (`gh api orgs/liquilabshq --jq .id` y
   `gh api repos/liquilabshq/<repo> --jq .id`); sin ellos, Azure lo rechaza con
   `AADSTS700213`.
6. Si publica o consume eventos: sus topics en `locals.topics` y su nombre en
   `locals.clients` de `messaging/main.tf`, y en su Container App el secreto
   `kafka-connection-string` y las variables de Kafka (copiar las de Profile).

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
- **Un topic que no está en `messaging/main.tf` no existe en Azure.** Event Hubs
  no crea topics desde los clientes: un consumidor de un topic que falta no
  recibe nada y un productor falla. Añádelo a `locals.topics` y vuelve a desplegar.
- **Tras un `azure-stop.sh`, no apliques `apps` a mano sin antes `messaging`:**
  sin el namespace, las apps recibirían una dirección y una clave vacías.
  `azure-deploy.sh` ya lo hace en orden.
- **Profile usa `GET /api/v1` como sonda**: aún no tiene endpoint de salud.
- **Invoicing usa `/health/live` como sonda de readiness** mientras no haya
  Kafka en Azure: su chequeo de Kafka espera 60 s sin broker. Volver a
  `/health/ready` al desplegar Kafka.
- Si cambias los providers de una capa, ejecuta `terraform init -upgrade` en ella.
