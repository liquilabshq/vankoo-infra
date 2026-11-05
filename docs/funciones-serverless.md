# 3.5 Funciones serverless

## Resumen

Se diseñó e implementó una función serverless en **Azure Functions** (Python 3.12) que verifica el DNI del
inversor. Está integrada con `vankoo-profile-service`, se despliega automáticamente con GitHub Actions y Terraform
y tiene pruebas automatizadas. Código: repositorio `vankoo-dni-verification-function`.

| Requisito | Cómo se cumple |
|---|---|
| Función serverless | Azure Functions con plan **Flex Consumption** (Linux; escala a cero y se paga por ejecución), modelo de programación v2 de Python |
| Caso de uso | Validar que el DNI del inversor existe y que los nombres declarados le pertenecen, en lugar de la revisión 100 % manual del KYC del inversor. El RUC de la MYPE ya se verifica en risk-service |
| Disparador | **HTTP trigger** `POST /api/verify-dni` (nivel de autorización `function`, clave en `x-functions-key`) |
| Integración | profile-service la llama al completar el perfil del inversor y aplica el veredicto con `verifyKyc` / `rejectKyc` |
| Despliegue automatizado | Terraform (capa `functions`) crea la infraestructura; el workflow `deploy.yml` publica el código al fusionar en `develop`, autenticándose con OIDC |
| Pruebas | pytest (57 pruebas unitarias, sin red, más una de humo contra la web real), ruff, `mypy --strict`; Jest en profile-service (16 pruebas nuevas); prueba local con la extensión Azure Functions de VS Code |

## Por qué serverless aquí

La verificación es una tarea corta, esporádica (una vez por inversor), sin estado y con tráfico impredecible: el
perfil de caso para pagar por ejecución. Aislarla en su propio servicio evita meter un scraper frágil dentro de
profile o risk, y permite cambiar la fuente de datos (eldni.com hoy, una API oficial mañana) sin tocarlos.

## Arquitectura

```
profile-service ──HTTP POST (x-functions-key)──▶ Azure Function ──scraping──▶ eldni.com
      ▲                                                │
      └────────── VERIFIED | NAME_MISMATCH | NOT_FOUND ┘
```

Detalle y decisiones: `vankoo-dni-verification-function/docs/ARCHITECTURE.md`.

- profile-service (`DniVerificationModule`) activa la integración con `DNI_VERIFICATION_ENABLED=true`. Apagada por
  defecto: el KYC manual sigue funcionando igual.
- La llamada no bloquea la respuesta al inversor. Sin veredicto confiable (función caída, timeout, clave inválida)
  el KYC queda `PENDING` para revisión manual.
- La función no guarda datos y no registra el DNI completo (Ley 29733 de protección de datos personales).

## Despliegue automatizado

1. **Infraestructura** — `terraform/functions`: cuenta de almacenamiento (con el contenedor del paquete de código), plan Flex Consumption (`FC1`), Function App (Python 3.12),
   Application Insights conectado al workspace `vankoo-logs`. `scripts/azure/azure-deploy.sh` aplica la capa al final, como paso
   opcional: comprueba antes que `Microsoft.Web` y `Microsoft.Insights` estén registrados y, si algo falla (proveedores
   sin registrar, cuota del plan), solo avisa para no bloquear el despliegue del resto de Vankoo. `azure-destroy.sh` la
   conserva salvo con `--all`, porque parada no cuesta.
2. **Código** — `.github/workflows/deploy.yml` del repo de la función: al fusionar en `develop` ejecuta ruff, mypy y
   pytest; si pasan, entra en Azure con OIDC (identidad administrada `vankoo-github-ci`, sin contraseñas), publica con
   `Azure/functions-action` (build remoto, `sku: flexconsumption`) y comprueba `GET /api/health`.
3. **Integración continua** — `ci.yml` en cada push/PR a `main` y `develop`.

Primer despliegue:

```bash
# Crea la capa functions (y la salida nueva de core). Se aplica solo lo necesario, sin reconstruir imágenes:
source scripts/azure/lib.sh && setup_terraform_env && tf_apply core && tf_apply functions
terraform -chdir=terraform/functions output -raw function_app_name   # → variable AZURE_FUNCTIONAPP_NAME
# Una persona con permisos crea la credencial federada y el rol Contributor sobre el Function App (ver README del repo).
# Ejecutar el workflow "Deploy to Azure Functions" (Actions → Run workflow) para publicar el código
az functionapp keys list -g liquilabs-vankoo -n <app> --query functionKeys.default -o tsv  # → DNI_VERIFICATION_KEY
```

## Pruebas

- **Unitarias (pytest)**: dominio (`DniNumber`, coincidencia de nombres), servicio, scraper con un transporte HTTP
  simulado sobre fixtures HTML (token CSRF, cookie, DNI inexistente, tabla vacía sin aviso, 419, 500, formato inesperado, DNI distinto, reintentos),
  handlers HTTP (200, 400, 502, logs sin DNI completo) y composición.
- **Humo contra la web real**: `pytest -m live` (a demanda, fuera de CI).
- **profile-service (Jest)**: aplica VERIFIED / rechazos, deja PENDING si la función cae, no llama si está apagada,
  no re-verifica un KYC ya procesado y no bloquea la respuesta; cliente HTTP (clave, errores, estados desconocidos).
- **Local con VS Code**: extensión Azure Functions + Core Tools (`func start` / F5) y `requests.http`; guía en el README
  del repo de la función.

## Plan de hosting: por qué Flex Consumption

El primer intento fue el plan Consumption clásico (`Y1`), pero la suscripción rechazó crearlo: Azure respondió que el
límite de cuota de «Y1 VMs» era 0. Los créditos no cambian eso: la cuota es un límite técnico por suscripción y
región, y las suscripciones de estudiante suelen traer algunos tipos de plan en cero. Flex Consumption es el plan de
consumo más reciente de Azure Functions: el mismo producto, código y disparadores, y la misma idea (escala a cero, pago
por ejecución), con otro tipo de plan (`FC1`) y otra cuota. Cambia la capa Terraform y el paso de despliegue; el código
de la función no cambia.

## Limitaciones conocidas

- **eldni.com no responde a las peticiones que salen de Azure.** Al desplegar la función en Central US, la consulta
  fallaba con `404 Not Found` ya en la página de inicio (`https://eldni.com/`), mientras que desde Perú el mismo código
  funciona (verificado con DNIs reales y con DNI inexistente). Parece un bloqueo por IP o por región del sitio; no se pudo
  confirmar la causa exacta. Por eso en la nube la función corre con el proveedor `fake` (`dni_provider = "fake"` por
  defecto en `terraform/functions`), con DNIs de demostración, y el scraping real se demuestra desde local. La
  arquitectura lo previó: la fuente está detrás de un puerto intercambiable, y el error 502 informa el motivo del fallo
  (`reason`), lo que permitió diagnosticarlo en minutos. Para reintentar con la fuente real (otra región, otra IP de
  salida): `-var dni_provider=eldni`.
- eldni.com **no es la fuente oficial de RENIEC**: puede tener errores o cambiar su HTML. Mitigado con el puerto
  intercambiable, el proveedor `fake` y la regla de fallar hacia revisión manual.
- Los fixtures HTML son respuestas reales de eldni.com (capturadas en noviembre de 2026, con los datos personales
  sustituidos por datos inventados). Si el sitio cambia, `pytest -m live` es la alarma.
- Los endpoints `PATCH /investors/:id/kyc/verify|reject` de profile no tienen autenticación propia (el JWT se valida
  solo en el gateway y profile no está enrutado); es previo a esta función y debe revisarse aparte.
