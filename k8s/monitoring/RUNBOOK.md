# Runbook de Vankoo en AKS

Qué hacer cuando algo falla en Vankoo: cómo se responde a un incidente y qué hacer con cada
alerta de `k8s/monitoring/vankoo/rules.yaml` (Prometheus) y `loki-rules.yaml` (Loki). Todos los
comandos suponen `kubectl` apuntando al clúster (`scripts/aks/aks-up.sh` lo deja así).

- **Grafana:** `https://vankoo-liquilabs.centralus.cloudapp.azure.com/grafana` (usuario `admin`).
  Dashboards: «Vankoo · Visión general», «Vankoo · SLO y presupuesto de error», «Vankoo · Logs» y
  «Vankoo · Trazas». Las alertas activas están en *Alerting → Alert rules* (fuente Alertmanager)
  y en el panel «Alertas activas de Vankoo» del dashboard de SLO.
- **Consultas libres:** *Explore* → Prometheus (PromQL), Loki (LogQL) o Tempo (TraceQL).

## Proceso de respuesta a incidentes

### Severidades

| Severidad | Qué significa | Ejemplos | Tiempo de respuesta | Quién |
| --- | --- | --- | --- | --- |
| `critical` | Un flujo de negocio o el API no funciona para los usuarios, o se está gastando el presupuesto de errores a un ritmo que lo agota en ~2 días. | `VankooApiErrorBudgetFastBurn`, `VankooJourneyErrorBudgetFastBurn`, `VankooDeploymentUnavailable`, `VankooDataStoreDown` | Empezar en ≤ 15 min durante una demo o la marcha blanca; mitigar en ≤ 1 h. | Responsable de turno |
| `warning` | Algo se degrada pero el servicio funciona: latencia alta, quema lenta del presupuesto, reinicios, falta de logs o trazas. | `VankooJourneyLatencyHigh`, `VankooApiErrorBudgetSlowBurn`, `VankooPodRestarting`, `VankooErrorLogsSpike` | El mismo día laborable; si se repite, se vuelve tarea del sprint. | Responsable de turno |

Alertmanager agrupa por alerta, severidad y flujo, y silencia los avisos menores de un flujo que
ya tiene una alerta crítica (y los reinicios y errores de logs de un servicio que ya está caído):
la causa es la misma y basta con atender la crítica (`k8s/monitoring/values.yaml`).

### Roles

| Rol | Qué hace | Por defecto |
| --- | --- | --- |
| Responsable de turno | Reconoce la alerta, investiga y aplica la mitigación. Decide el *rollback*. | Responsable de configuración y CI/CD |
| Comunicador | Avisa al equipo en el canal del proyecto al empezar, cada 30 min y al cerrar; para la demo, informa al docente si un flujo queda fuera. | Coordinador del equipo |
| Responsable del postmortem | Redacta el postmortem en ≤ 2 días hábiles y registra las acciones como historias o tareas del backlog. | Auditora de proceso |

En un equipo de cinco, una misma persona puede tener dos roles, pero el responsable de turno no
debería ser además el comunicador durante un incidente crítico.

### Flujo

1. **Detectar.** Salta una alerta en Grafana o Alertmanager, o alguien ve un error en la demo.
   Anotar la hora de inicio.
2. **Clasificar.** Abrir «Vankoo · SLO y presupuesto de error»: ¿qué flujo tiene el *burn rate* alto
   o el p95 fuera de objetivo? ¿Es todo el API o un solo flujo? Eso fija la severidad.
3. **Diagnosticar** con las tres señales, en este orden:
   - **Métricas:** ¿desde cuándo y cuánto? («Peticiones por flujo y código HTTP», CPU y memoria en «Visión general»).
   - **Trazas:** «Vankoo · Trazas» → «Trazas con error o lentas» → abrir una: el span en rojo o el más largo dice qué servicio o dependencia (base, Kafka, S3, OCR) falla.
   - **Logs:** desde el span, botón *Logs for this span*, o «Vankoo · Logs» filtrando por servicio y nivel `error`. En los servicios Java cada línea lleva su `trace_id`.
4. **Mitigar** primero, arreglar después. Por orden de preferencia:
   - **Volver a la versión anterior:** Argo CD → aplicación `vankoo` → *History and rollback*, o revertir el commit del overlay en `develop` (Argo CD lo aplica solo). Es la opción por defecto si el incidente empezó tras un despliegue.
   - **Reiniciar o escalar:** `kubectl -n vankoo rollout restart deploy/<servicio>` o `kubectl -n vankoo scale deploy/<servicio> --replicas=2`.
   - **Liberar recursos:** ver [Nodo sin memoria](#nodo-sin-memoria).
5. **Verificar.** La alerta pasa a *resolved* (la ventana corta del *burn rate* hace que se apague
   en ~5 min) y el flujo vuelve a su SLO en el dashboard.
6. **Comunicar el cierre** y **escribir el postmortem** (plantilla al final) si el incidente fue
   `critical` o gastó más del 20 % del presupuesto de un flujo.

### Cómo añadir un canal de notificación

Hoy las alertas solo se ven en Grafana y Alertmanager (receptor `null`). Para mandarlas a un canal,
añadir en `k8s/monitoring/values.yaml` → `alertmanager.config` un receptor (`email_configs`,
`webhook_configs` o `discord_configs`) y una ruta hacia él con `matchers: ['severity = critical']`,
con el secreto en el `.env` y no en Git, y volver a ejecutar `scripts/aks/aks-platform.sh`.

## Fichas por alerta

### API con errores 5xx
`VankooApiErrorBudgetFastBurn` (crítica) y `VankooApiErrorBudgetSlowBurn` (aviso): la proporción
de 5xx del gateway supera 14,4 veces el presupuesto (1 %) en 1 h y 5 min, o 6 veces en 6 h y 30 min.
1. «Vankoo · SLO» → «Peticiones por flujo y código HTTP»: ¿se concentra en una ruta (`routeId`)? Entonces es un servicio: ver [Flujo con errores 5xx](#flujo-con-errores-5xx).
2. Si fallan todas las rutas, el problema es el gateway o la plataforma: `kubectl -n vankoo logs deploy/api-gateway --tail=200`. Un 503 indica que el servicio de destino no responde.
3. Revisar el servicio de la ruta afectada ([Servicio caído](#servicio-caído)).

### API lenta
`VankooApiLatencyHigh`: el p95 del gateway supera 1 s durante 10 minutos.
1. «Vankoo · Trazas» → «Latencia p95 por servicio» y «Endpoints más lentos»: ¿qué servicio y qué ruta?
2. Abrir una traza lenta: si el span largo es de base de datos (`SELECT …`), Kafka o una llamada externa (S3, OCR, SUNAT), el cuello de botella está ahí y no en el servicio.
3. «Visión general» → «CPU por servicio» y «Memoria por servicio»: un servicio al límite de su `limits` se ralentiza. `kubectl -n vankoo get hpa`: si un HPA está en su máximo, subir `maxReplicas` o el tamaño del nodo.
4. Oracle e Investment son los más pesados: `kubectl -n vankoo top pod`.

### Flujo con errores 5xx
`VankooJourneyErrorBudgetFastBurn` (crítica) y `VankooJourneyErrorBudgetSlowBurn` (aviso), con la
etiqueta `journey`:

| `journey` | Ruta del gateway | Servicio | Dependencias que suelen fallar |
| --- | --- | --- | --- |
| `login` | `iam-auth-public` | `iam-service` | `iam-db-postgres`, Kafka (evento de registro) |
| `factura` | `invoicing-invoices-protected` | `invoicing-service` | `invoicing-db-mongo`, S3, Azure Document Intelligence (OCR) |
| `inversion` | `investment-auctions-protected` | `investment-service` | `investment-db-oracle`, Kafka |
| `recarga` | `finance-investor-protected` | `finance-service` | `finance-db-postgres`, Axon Server, Stripe |

1. «Vankoo · Trazas» → servicio del flujo → «Trazas con error o lentas»: abrir una traza fallida y ver qué span tiene el error y su mensaje (pestaña *Span attributes / Events*).
2. Logs del servicio en ese momento: «Vankoo · Logs» con el servicio y nivel `error`, o desde el span.
3. Si la causa es una dependencia: [Base o broker caído](#base-o-broker-caído). Si es la nube (S3, OCR, Stripe), confirmar en su página de estado y comunicar que el flujo está degradado.
4. Si empezó con un despliegue reciente: *rollback* en Argo CD.

### Flujo lento
`VankooJourneyLatencyHigh`: el p95 del endpoint del flujo supera su objetivo (login 0,5 s, factura
3 s, inversión 1,5 s, recarga 2 s) durante 10 minutos. El p95 sale de las trazas (span-metrics de
Tempo): si no hay trazas, ver [Sin logs o sin trazas](#sin-logs-o-sin-trazas).
1. «Vankoo · Trazas» → «Endpoints más lentos»: ¿todo el servicio o una ruta?
2. Abrir una traza lenta del flujo y buscar el span más largo (base, Kafka, OCR, Stripe).
3. Seguir los pasos de [API lenta](#api-lenta) para CPU, memoria y HPA.

### Pod que se reinicia
`VankooPodRestarting`
1. `kubectl -n vankoo describe pod <pod>` → «Last State»: `OOMKilled` significa que falta memoria y hay que subir `limits` (los servicios Java cargan además el agente de OpenTelemetry, ~100 Mi); `Error` hay que leerlo en los logs.
2. `kubectl -n vankoo logs <pod> --previous`, o «Vankoo · Logs» con el servicio: Loki conserva los logs del contenedor anterior.
3. Si depende de una base o de Kafka, revisar primero [Base o broker caído](#base-o-broker-caído).

### Servicio caído
`VankooDeploymentUnavailable`
1. `kubectl -n vankoo get pods -l app.kubernetes.io/name=<servicio>`
2. Un `ImagePullBackOff` indica que la etiqueta no existe en el ACR: `scripts/aks/aks-build.sh <servicio>`.
3. Si el pod queda en `Init` por `opentelemetry-auto-instrumentation`, la imagen del agente no se pudo descargar: quitar la anotación del servicio en `overlays/azure/patches/otel-instrumentation.yaml` lo arranca sin trazas.
4. Volver a la versión anterior: Argo CD → aplicación `vankoo` → *History and rollback*.

### Base o broker caído
`VankooDataStoreDown`
1. `kubectl -n vankoo describe pod <statefulset>-0`: si está en `Pending` por «max volume count», el nodo ya tiene 4 discos.
2. Oracle tarda unos minutos en arrancar: esperar a «DATABASE IS READY TO USE!» en sus logs.
3. Tras recuperarlo, reiniciar los servicios que dependen de él: `kubectl -n vankoo rollout restart deploy/<servicio>`.

### Nodo sin memoria
`VankooNodeMemoryPressure`
1. `kubectl top nodes` y `kubectl top pod -A --sort-by=memory`.
2. Bajar réplicas de los HPA o apagar temporalmente lo no esencial si es una demo: Argo CD (`kubectl -n argocd scale deploy --all --replicas=0`) o el tracing (`kubectl -n monitoring scale statefulset/tempo --replicas=0`; los servicios siguen funcionando, solo sin trazas).

### Ráfaga de errores en los logs
`VankooErrorLogsSpike` (Loki): un servicio escribe más de 20 líneas de error en 5 minutos, sostenido.
1. «Vankoo · Logs» → servicio de la etiqueta `app`, nivel `error`: ¿es el mismo mensaje en bucle?
2. Errores típicos que no afectan al usuario pero sí al negocio: un consumidor de Kafka que no puede procesar un evento (lo manda a su DLQ), el worker de OCR de Invoicing o el *outbox* de Investment y Risk.
3. Si la línea trae `trace_id`, abrir la traza para ver la petición que lo causó.

### Sin logs o sin trazas
`VankooLogPipelineDown` y `VankooTracesMissing`: la propia observabilidad falla.
1. `kubectl -n monitoring get pods`: `alloy`, `loki-0` y `tempo-0` deben estar `Running`.
2. Alloy: `kubectl -n monitoring logs deploy/alloy` (errores al enviar a Loki). Loki y Tempo guardan en el disco del pod: si se reiniciaron, el historial de las últimas horas se perdió.
3. Sin trazas: comprobar que los pods tienen el agente (`kubectl -n vankoo get pod <pod> -o jsonpath='{.spec.initContainers[*].name}'` debe mostrar `opentelemetry-auto-instrumentation-*`) y que el operador está vivo (`kubectl -n monitoring get deploy opentelemetry-operator`). Si el operador estaba caído cuando el pod arrancó, reiniciar el servicio.

## Plantilla de postmortem

Sin culpables: se describe qué pasó y qué cambiar en el sistema o el proceso, no quién se equivocó.
Se guarda junto a la evidencia del sprint en el informe del equipo.

```markdown
# Postmortem: <título corto> (<fecha>)

- **Severidad:** critical | warning        **Duración:** <inicio> → <fin> (<min>)
- **Flujos afectados:** login | factura | inversion | recarga | api
- **Impacto en el SLO:** <% del presupuesto de error gastado, de «Vankoo · SLO»>; usuarios o demo afectados.

## Línea de tiempo (hora local)
- hh:mm  Salta <alerta> / alguien reporta <síntoma>
- hh:mm  <acción del responsable de turno>
- hh:mm  Mitigado con <rollback / reinicio / escalado>
- hh:mm  Alerta resuelta

## Causa raíz
<qué falló y por qué; enlazar la traza y la consulta de logs que lo muestran>

## Qué funcionó y qué no
- Detección: ¿la alerta saltó antes de que lo notara un usuario?
- Diagnóstico: ¿el dashboard, la traza y los logs bastaron?

## Acciones
| Acción | Tipo (prevenir / detectar / mitigar) | Responsable | Historia o tarea |
| --- | --- | --- | --- |
```

## Simulacro (game day)

Para probar alertas, dashboards y este runbook antes de que pase de verdad, y dejar evidencia.
Dura unos 20 minutos, con el clúster encendido.

1. **Tráfico de fondo** con las pruebas de k6 del repositorio (`tests/performance/`), contra la URL pública:
   `tests/performance/run.sh load` (ver `tests/performance/README.md`).
2. **Provocar el incidente:** dejar sin réplicas el servicio de facturas.
   ```bash
   kubectl -n vankoo scale deploy/invoicing-service --replicas=0
   ```
   Argo CD lo devolverá a su estado de Git (*selfHeal*); para que no lo haga durante el simulacro,
   desactivar antes el auto-sync de la aplicación `vankoo` en Argo CD.
3. **Observar:** subir una factura desde la web MYPE (o el `load`): el gateway responde 5xx en
   `invoicing-invoices-protected` → a los ~2 min `VankooJourneyErrorBudgetFastBurn{journey="factura"}`
   pasa a *firing* y a los 5 min `VankooDeploymentUnavailable{deployment="invoicing-service"}`.
   En «Vankoo · Trazas», la traza del gateway muestra el error de conexión al servicio.
4. **Aplicar el runbook** ([Flujo con errores 5xx](#flujo-con-errores-5xx) → [Servicio caído](#servicio-caído)) y restaurar:
   ```bash
   kubectl -n vankoo scale deploy/invoicing-service --replicas=1
   ```
   Reactivar el auto-sync de Argo CD.
5. **Verificar** que las alertas pasan a *resolved* y escribir un postmortem de práctica con la plantilla.
