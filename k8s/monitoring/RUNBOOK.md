# Runbook de Vankoo en AKS

Qué hacer cuando salta cada alerta de `k8s/monitoring/vankoo/rules.yaml`. Todos los
comandos suponen `kubectl` apuntando al clúster (`scripts/aks/aks-up.sh` lo deja así).
Base inicial para la sección 4.3: hay que completarla con los incidentes reales.

## API con errores 5xx
`VankooApiErrorBudgetFastBurn`: más del 14,4 % de las peticiones al gateway terminan en 5xx.
1. Grafana → «Vankoo · Visión general» → «Peticiones al API por código de estado»: ¿un solo código o todos?
2. `kubectl -n vankoo logs deploy/api-gateway --tail=200`: el 503 indica que el servicio de destino no responde.
3. Revisar el servicio de la ruta afectada (sección «Servicio caído»).

## API lenta
`VankooApiLatencyHigh`: el p95 supera 1 s durante 10 minutos.
1. Dashboard: «CPU por servicio» y «Memoria por servicio». Un servicio al límite de su `limits` se ralentiza.
2. `kubectl -n vankoo get hpa`: si un HPA está en su máximo, subir `maxReplicas` o el tamaño del nodo.
3. Oracle e Investment son los más pesados: `kubectl -n vankoo top pod`.

## Pod que se reinicia
`VankooPodRestarting`
1. `kubectl -n vankoo describe pod <pod>` → «Last State»: `OOMKilled` significa que falta memoria y hay que subir `limits`; `Error` hay que leerlo en los logs.
2. `kubectl -n vankoo logs <pod> --previous`.
3. Si depende de una base o de Kafka, revisar primero «Base o broker caído».

## Servicio caído
`VankooDeploymentUnavailable`
1. `kubectl -n vankoo get pods -l app.kubernetes.io/name=<servicio>`
2. Un `ImagePullBackOff` indica que la etiqueta no existe en el ACR: `scripts/aks/aks-build.sh <servicio>`.
3. Volver a la versión anterior: Argo CD → aplicación `vankoo` → «History and rollback».

## Base o broker caído
`VankooDataStoreDown`
1. `kubectl -n vankoo describe pod <statefulset>-0`: si está en `Pending` por «max volume count», el nodo ya tiene 4 discos.
2. Oracle tarda unos minutos en arrancar: esperar a «DATABASE IS READY TO USE!» en sus logs.
3. Tras recuperarlo, reiniciar los servicios que dependen de él: `kubectl -n vankoo rollout restart deploy/<servicio>`.

## Nodo sin memoria
`VankooNodeMemoryPressure`
1. `kubectl top nodes` y `kubectl top pod -A --sort-by=memory`.
2. Bajar réplicas de los HPA o apagar temporalmente lo no esencial (Grafana, Argo CD) si es una demo.
