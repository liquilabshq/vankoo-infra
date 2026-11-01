# 3.5 Funciones serverless

## Resumen

Se diseñó e implementó una función serverless en **Azure Functions** (Python 3.12) que verifica el DNI del
inversor. Está integrada con `vankoo-profile-service`, se despliega automáticamente con GitHub Actions y Terraform
y tiene pruebas automatizadas. Código: repositorio `vankoo-dni-verification-function`.

| Requisito | Cómo se cumple |
|---|---|
| Función serverless | Azure Functions, plan de consumo (Linux, Y1), modelo de programación v2 de Python |
| Caso de uso | Validar que el DNI del inversor existe y que los nombres declarados le pertenecen, en lugar de la revisión 100 % manual del KYC del inversor. El RUC de la MYPE ya se verifica en risk-service |
| Disparador | **HTTP trigger** `POST /api/verify-dni` (nivel de autorización `function`, clave en `x-functions-key`) |
| Integración | profile-service la llama al completar el perfil del inversor y aplica el veredicto con `verifyKyc` / `rejectKyc` |
| Despliegue automatizado | Terraform (capa `functions`) crea la infraestructura; el workflow `deploy.yml` publica el código al fusionar en `main` |
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

1. **Infraestructura** — `terraform/functions`: cuenta de almacenamiento, plan de consumo, Function App (Python 3.12),
   Application Insights conectado al workspace `vankoo-logs`. `scripts/azure/azure-deploy.sh` aplica la capa (y ahora
   exige `Microsoft.Web` y `Microsoft.Insights`); `azure-destroy.sh` la conserva salvo con `--all`, porque parada no cuesta.
2. **Código** — `.github/workflows/deploy.yml` del repo de la función: al fusionar en `main` ejecuta ruff, mypy y
   pytest; si pasan, publica con `Azure/functions-action` (build remoto con Oryx) y comprueba `GET /api/health`.
3. **Integración continua** — `ci.yml` en cada push/PR a `main` y `develop`.

Primer despliegue:

```bash
scripts/azure/azure-deploy.sh --env-file .env      # crea la capa functions
terraform -chdir=terraform/functions output -raw function_app_name
az functionapp deployment list-publishing-profiles -g liquilabs-vankoo -n <app> --xml   # → secreto del repo
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

## Limitaciones conocidas

- eldni.com **no es la fuente oficial de RENIEC**: puede tener errores o cambiar su HTML. Mitigado con el puerto
  intercambiable, el proveedor `fake` y la regla de fallar hacia revisión manual.
- Los fixtures HTML son respuestas reales de eldni.com (capturadas en noviembre de 2026, con los datos personales
  sustituidos por datos inventados). Si el sitio cambia, `pytest -m live` es la alarma.
- Los endpoints `PATCH /investors/:id/kyc/verify|reject` de profile no tienen autenticación propia (el JWT se valida
  solo en el gateway y profile no está enrutado); es previo a esta función y debe revisarse aparte.
