# Pruebas de rendimiento con k6 (4.4.3)

Simulan a inversionistas que abren el mercado en la app: lista de subastas, filtro verde,
detalle de una subasta y saldo de la billetera, contra el despliegue de AKS. Corren con la
imagen oficial `grafana/k6:2.3.0` en Docker, así que no hace falta instalar k6.

| Prueba | Usuarios | Duración | Para qué |
|---|---|---|---|
| `smoke` | 1 | 30 s | Comprobar que el script y la cuenta funcionan |
| `load` | hasta 20 | 7 min | Uso esperado: debe cumplir el SLO (p95 < 1 s y < 1 % de errores) |
| `stress` | hasta 80, por escalones | 13 min | Buscar el punto de quiebre y ver el autoescalado (HPA) |

Los umbrales de `smoke` y `load` son los mismos SLO del monitoreo (`k8s/monitoring`).

## Cómo ejecutarlas

```bash
export K6_INVESTOR_EMAIL='<correo de la cuenta inversionista de prueba>'
export K6_INVESTOR_PASSWORD='<su contraseña>'
tests/performance/run.sh smoke
tests/performance/run.sh load
tests/performance/run.sh stress
```

- **Otro entorno:** `BASE_URL=http://localhost:8080 tests/performance/run.sh smoke`.
- **Las credenciales** no van al repositorio: pídelas a Salim.
- **El resumen** de cada ejecución queda en `tests/performance/results/` (fuera de git).

## Qué mirar mientras corre `stress` (para el informe)

```bash
kubectl -n vankoo get hpa -w          # réplicas y % de CPU de cada servicio
kubectl -n vankoo top pods            # consumo por pod
kubectl -n monitoring port-forward svc/monitoring-grafana 3002:80   # dashboard «Vankoo · Visión general»
```

El HPA escala gateway, IAM, Investment, Invoicing y Profile de 1 a 3 réplicas cuando superan el 70 % de CPU. El clúster tiene 3 nodos, y eso limita cuánto puede crecer.

**Primera ejecución (`smoke`, 25 nov 2026, AKS):** 0 % de errores, p95 de 218 ms (mercado: 191 ms) y 73 peticiones.
