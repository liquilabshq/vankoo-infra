# Investment en Azure — Sprint 4

## Alcance y estado

Guía del despliegue independiente de Investment en `vankoo-env`, con Oracle Free
en una VM Ubuntu en Central US. Mensajería y Eureka desactivados. No incorpora rutas
al Gateway, Event Hubs ni datos de otros servicios.

El despliegue académico ya se ejecutó; sus resultados y limitaciones se registran en
`investment-azure-validation.md` y las capturas en tsp-report. Los comandos siguientes
documentan el procedimiento, no una orden de volver a crear los recursos.
No ejecutar los scripts generales para este
despliegue: operan sobre todo Vankoo.

## Infraestructura

La capa `terraform/investment/` usa un estado remoto propio, `investment.tfstate`,
en la cuenta existente. Lee `core.tfstate` y `base.tfstate` para reutilizar el
Environment y el ACR; no administra ni importa los recursos de los otros servicios.

- VM `vankoo-investment-db-vm`, D2s_v4 (2 vCPU/8 GiB), Ubuntu 24.04, disco de sistema
  Standard SSD 64 GiB. B2s y B2als_v2 fallaron por capacidad en Central US; el valor
  por defecto coincide ahora con la VM desplegada. No reducirla sin revisar el plan.
- VNet y subred de la VM, interfaz, IP pública Standard estática con DNS y NSG.
- Docker ejecuta Oracle Free con un volumen nombrado sobre el disco del sistema.
- Oracle escucha en `127.0.0.1:1521` en el host. No se publica 1521 a Internet.
- stunnel termina TLS en 2484 y reenvía a Oracle por loopback. Investment usa TCPS,
  un certificado de servidor fijado en su truststore y comprobación de nombre.
- NSG permite 2484 solo desde los /32 de salida de Investment. Bloquea otros
  accesos a 1521, 2484 y SSH. Administración mediante Azure Run Command.
- Custom Script Extension instala Docker, Oracle y stunnel. Los secretos viajan en
  `protected_settings`, no en `custom_data`. El estado de Terraform contiene secretos:
  restringir su acceso y no exportarlo, adjuntarlo al informe ni subirlo a Git.
- Certificado válido por un año; renovar antes de su vencimiento y desplegar la
  nueva confianza del cliente. No es una solución de alta disponibilidad o producción.
- La IP pública y el disco siguen teniendo costo con la VM desasignada.
- Apagado automático a las 23:00 de Lima. Iniciar nuevamente la VM de forma explícita.
- `prevent_destroy` en la VM evita eliminar/recrear accidentalmente el disco. No
  protege de eliminaciones hechas desde el portal. No quitarlo sin respaldo y decisión.

## Prerrequisitos

Azure CLI autenticado en la suscripción que contiene `liquilabs-vankoo`, Terraform,
Docker Desktop iniciado y Git Bash. Ejecutar desde `vankoo-infra` en **Git Bash**,
no con `C:\Windows\System32\bash.exe` (WSL). La suscripción debe permitir el tamaño elegido en
Central US y tener registrados `Microsoft.Compute`, `Microsoft.Network` y
`Microsoft.App` y `Microsoft.DevTestLab` (horario de apagado); el script comprueba,
no registra proveedores de suscripción.

Si aparecen como `NotRegistered`, un usuario autorizado sobre la suscripción debe
registrarlos antes de continuar. Estos comandos pueden ejecutarse en PowerShell:

```powershell
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Network --wait
az provider register --namespace Microsoft.DevTestLab --wait
az provider show --namespace Microsoft.Compute --query registrationState -o tsv
az provider show --namespace Microsoft.Network --query registrationState -o tsv
az provider show --namespace Microsoft.DevTestLab --query registrationState -o tsv
```

Esperar `Registered` en todos. Si devuelve `AuthorizationFailed`, solicitar el
registro al administrador de la suscripción; no ampliar roles automáticamente.

Usar la misma suscripción y cuenta de estado existentes. No crear otro estado para
los recursos compartidos ni aplicar versiones antiguas de las capas comunes.

Se requiere una clave **pública** SSH. Si no tienes una, generar una nueva fuera
del repositorio; guardar la privada de forma segura y no enviarla al chat:

```bash
ssh-keygen -t ed25519 -f "$USERPROFILE/.ssh/vankoo-investment" -C investment-academic
export INVESTMENT_SSH_PUBLIC_KEY_FILE="$USERPROFILE/.ssh/vankoo-investment.pub"
```

Si la carpeta `.ssh` no existe, crearla primero. Si la clave ya existe, reutilizar
su `.pub`; no sobrescribirla. Aunque SSH está bloqueado por NSG, Azure exige una
clave para el usuario administrativo de esta VM.

## Aplicación en dos etapas

Primero **planificar**. Revisar nombres, región, tamaño, costos y que solo aparezcan
recursos de Investment. Las lecturas de estados compartidos no son cambios.

```bash
bash scripts/azure/investment.sh plan-bootstrap
```

Después de revisar el plan y autorizar el consumo:

```bash
bash scripts/azure/investment.sh bootstrap
```

Crea Oracle y una aplicación provisional **interna** con una imagen de ejemplo,
sin endpoints de Investment ni información de negocio. Su único propósito es
obtener las IP de salida reales sin abrir Oracle al mundo. No es aún la API desplegada.

```bash
bash scripts/azure/investment.sh collect-egress
bash scripts/azure/investment.sh build
bash scripts/azure/investment.sh plan
```

`collect-egress` escribe solo IP /32 en `egress.auto.tfvars`; `build` construye solo
Investment y guarda la referencia de imagen en `image.auto.tfvars`. Ambos archivos
son locales e ignorados por Git. Idealmente construir desde un commit limpio y
conservar su hash; los builds con cambios locales se etiquetan como dirty con fecha.

Tras revisar el segundo plan:

```bash
bash scripts/azure/investment.sh deploy
```

Esta etapa autoriza primero las IP recogidas y luego sustituye la imagen de
ejemplo por Investment, configurando Oracle, TLS, sondas y mensajería desactivada.
La API usa 1 vCPU, 2 GiB y una réplica durante la demo.

No volver a ejecutar bootstrap sobre un despliegue final: reemplazaría la API
por la imagen de ejemplo; el script lo impide.

### Probar la API

Por defecto el ingress es interno. Se comprobó la API sin abrirla a Internet:

```bash
MSYS_NO_PATHCONV=1 az containerapp exec \
  --resource-group liquilabs-vankoo --name vankoo-investment-service \
  --command "curl -fsS http://localhost:8082/actuator/health/readiness"
```

También se puede probar
desde la consola de otra Container App del mismo entorno:

```bash
curl -fsS http://vankoo-investment-service/actuator/health
```

Si esa imagen no incluye curl, usar otra herramienta HTTP disponible o elegir
la siguiente opción de acceso temporal. No modificar la imagen de un servicio ajeno.

Para una demo directa desde Postman/Scalar en tu PC, antes del plan final:

```bash
export TF_VAR_external_ingress=true
export TF_VAR_api_client_cidrs='["TU_IP_PUBLICA/32"]'
```

Sustituir por tu IP pública real. Solo se admite /32, nunca 0.0.0.0/0.
El acceso externo es una excepción temporal a documentar: estos endpoints incluyen
operaciones internas de riesgo y algunos confían en X-User-Id del Gateway. No es una
API autenticada para usuarios externos; usar exclusivamente datos sintéticos.
Para volver al ingress interno, establecer `TF_VAR_external_ingress=false` y aplicar
de nuevo el plan. Antes de conectar el Gateway, revisar autorización de rutas
internas y coherencia JWT: en esta fase la clave de Investment es independiente.

### Pruebas mínimas y evidencia

1. Verificar revisión lista y `GET /actuator/health` y `/actuator/health/readiness`.
   Readiness comprueba Oracle; liveness solo el proceso. No reemplazar readiness
   por liveness si falla la base.
2. Revisar logs: cinco migraciones Flyway y validación Hibernate satisfactorias.
3. Crear una subasta con datos sintéticos mediante `POST /api/v1/auctions` y guardar
   su id. Usar una fecha de vencimiento futura y un invoiceId distinto por prueba.
4. Consultar `GET /api/v1/auctions/{id}`. Puede quedar en estado pendiente de riesgo,
   porque no existe integración con Risk en esta fase; esto es esperado.
5. Reiniciar la aplicación y repetir GET. Después detener/reanudar la VM con el
   procedimiento de abajo y repetir GET. La misma subasta debe conservarse.
6. Desde Azure Run Command (VM), verificar el volumen sin imprimir secretos:

```bash
docker inspect --format '{{.State.Health.Status}}' investment-oracle
docker volume inspect --format '{{.Mountpoint}}' investment-oracle-data
```

7. Confirmar ausencia de consumidores Kafka y publicación: los eventos quedan
   PENDING en el outbox. No validar marketplace como completo sin su proyección.
   Antes de habilitar Event Hubs, acordar qué hacer con eventos de prueba acumulados.

La futura integración debe configurar `INVESTMENT_MESSAGING_ENABLED=true`,
`INVESTMENT_FUNCTION_DEFINITION=processInvoiceEligibleForFunding;projectAuctionMarketplace`,
brokers, autenticación, topics y DLQ. Activar el flag por sí solo no configura Event Hubs.

Para probar evaluación, cotización o inversión, seguir los contratos REST y estados
del servicio; no editar estados/tablas a mano para simular el flujo.

## Operación y recuperación

```bash
bash scripts/azure/investment.sh status
bash scripts/azure/investment.sh stop
bash scripts/azure/investment.sh start
```

`stop` detiene solo Investment, apaga Oracle limpiamente y desasigna la VM. `start`
inicia primero Oracle, comprueba su salud y después arranca Investment. Los scripts
comprueban también el código de salida del comando remoto. No borran contenedores,
volúmenes ni discos. No usar `docker compose down -v`, `docker volume rm` ni
`terraform destroy` para una pausa.

Si cambia el conjunto de IP de salida, comparar con `egress.auto.tfvars`, ejecutar
`collect-egress` y revisar/aplicar el plan antes de reintentar. No ampliar a todo Azure
ni abrir el puerto a Internet como solución. No se usan las IP de entrada del entorno
para construir estas reglas.

Cambiar el tamaño, la clave SSH o parámetros de disco puede provocar recreación:
`prevent_destroy` debe bloquearla. No regenerar contraseñas del estado sin rotarlas
también en Oracle; el script no cambia contraseñas en una BD ya inicializada.

La capa nueva no está incluida en `azure-destroy.sh`. Antes de que el equipo elimine
ACR o Environment compartidos, coordinar el retiro de Investment y respaldar Oracle.

## Evidencias del informe

Destino en tsp-report:
`assets/cap5-product-implementation/sprint-4/deployment-evidence/`.
Sección: `5.2.4.7. Software Deployment Evidence for Sprint Review`, debajo de Profile.

| Archivo sugerido | Qué debe demostrar |
|---|---|
| investment-terraform-plan.png | Plan revisado de la capa aislada |
| investment-terraform-apply.png | Resultado real del aprovisionamiento |
| investment-resource-group.png | VM y Container App junto a recursos existentes |
| investment-oracle-network.png | NSG: TLS restringido y bloqueo de 1521 |
| investment-oracle-health.png | Oracle saludable y volumen persistente |
| investment-acr-image.png | Imagen y etiqueta del commit desplegado |
| investment-container-app.png | Revisión activa, perfil y recursos |
| investment-health-check.png | Readiness y health respondiendo UP |
| investment-create-auction.png | POST real y su identificador |
| investment-persistence-restart.png | Misma subasta después de reiniciar |
| investment-stopped-resources.png | App detenida y VM desasignada |

No capturar secretos, archivos de estado, planes binarios, claves privadas, payloads
de la extensión o salidas `terraform output -json` completas. Assets PNG locales,
minúsculas y guiones, preferentemente hasta 1600 px, rutas relativas desde el README.
El texto final debe distinguir resultados comprobados, limitaciones y trabajo futuro.
