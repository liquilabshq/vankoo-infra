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

## Verificación real en la nube: API Perú (opcional)

Como el scraping de eldni.com no funciona desde Azure, la función admite una tercera fuente: la API REST de
[API Perú](https://apiperu.pe) (`dni_provider = "apiperu"`). Es una API con token, pensada para llamarse desde
servidores. Solo recibe el DNI (nunca los nombres declarados) y devuelve los nombres, que la función compara por su
cuenta. Por defecto la capa sigue en `fake`: el token es un secreto y el plan gratuito son 100 consultas al mes.

Para activarla (con la función encendida; si el Function App está detenido hay que arrancarlo antes de probar):

```bash
export TF_VAR_apiperu_token='<token>'   # no lo escribas en ningún archivo versionado
source scripts/azure/lib.sh && setup_terraform_env && tf_apply functions -var dni_provider=apiperu
```

- **Sin token no se puede elegir `apiperu`:** el plan falla con un mensaje claro (precondición en `main.tf`).
- **Es declarativo.** Si después alguien ejecuta `azure-deploy.sh` sin esas variables, la capa vuelve a `fake` y quita el
  token del Function App. Es el comportamiento seguro por defecto, pero conviene saberlo.
- **El token queda en el estado remoto** de Terraform (cuenta de almacenamiento del grupo), marcado como sensible, y no
  aparece en los planes.
- Su proveedor no declara públicamente el origen de los datos de DNI ni su identidad legal: se considera una fuente
  para demostraciones, no para producción.

## Riesgos aceptados

### La cuenta de almacenamiento de la función no restringe la red (Trivy AVD-AZU-0012, CRITICAL)

**Qué se acepta.** La cuenta `vankoofn…` de la capa `functions` acepta conexiones desde cualquier red: no tiene
`network_rules` con `default_action = "Deny"`. Trivy lo marca como CRITICAL. La línea `#trivy:ignore:AVD-AZU-0012`
de `terraform/functions/main.tf` lo excluye **solo para ese recurso**: cualquier otra cuenta de almacenamiento que se
cree seguirá vigilada por la regla.

**Por qué.** En Flex Consumption el host de la función lee y escribe esa cuenta (sus claves y el paquete de código), y
el despliegue de GitHub Actions publica ahí el código. Sin red virtual, esos accesos llegan por el endpoint público:
denegar el tráfico dejaría la función sin arrancar y sin poder desplegarse. Restringirlo exige integrar la función en
una red virtual (subred delegada, service endpoint de Storage y reglas por subred), y hoy ninguna capa de Vankoo usa
redes virtuales. Para un entorno académico ese cambio de arquitectura no compensa frente a lo que protege.

**Qué lo mitiga.**
- Sin la clave de la cuenta no se puede leer ni escribir nada. La clave solo la tienen el estado remoto de Terraform y la
  configuración del Function App.
- TLS 1.2 mínimo y sin blobs públicos (`allow_nested_items_to_be_public = false`).
- La cuenta no guarda datos personales: la función no persiste ningún DNI ni nombre.

**Plan para producción.**
1. Integrar la función en una red virtual (subred delegada para Flex Consumption).
2. Poner `network_rules` con `default_action = "Deny"` y permitir solo esa subred (service endpoint), o usar private
   endpoints.
3. Pasar de la clave de la cuenta a una identidad administrada (`storage_authentication_type`) y desactivar las claves
   compartidas.

## Limitaciones conocidas

- **eldni.com no responde a las peticiones que salen de Azure.** Al desplegar la función en Central US, la consulta
  fallaba con `404 Not Found` ya en la página de inicio (`https://eldni.com/`), mientras que desde Perú el mismo código
  funciona (verificado con DNIs reales y con DNI inexistente). Parece un bloqueo por IP o por región del sitio; no se pudo
  confirmar la causa exacta. Por eso en la nube la función corre con el proveedor `fake` (`dni_provider = "fake"` por
  defecto en `terraform/functions`), con DNIs de demostración, y el scraping real se demuestra desde local. La
  arquitectura lo previó: la fuente está detrás de un puerto intercambiable, y el error 502 informa el motivo del fallo
  (`reason`), lo que permitió diagnosticarlo en minutos. Para reintentar con la fuente real (otra región, otra IP de
  salida): `-var dni_provider=eldni`. La alternativa para una verificación real en la nube es API Perú (ver arriba).
- eldni.com **no es la fuente oficial de RENIEC**: puede tener errores o cambiar su HTML. Mitigado con el puerto
  intercambiable, el proveedor `fake` y la regla de fallar hacia revisión manual.
- Los fixtures HTML son respuestas reales de eldni.com (capturadas en noviembre de 2026, con los datos personales
  sustituidos por datos inventados). Si el sitio cambia, `pytest -m live` es la alarma.
- Los endpoints `PATCH /investors/:id/kyc/verify|reject` de profile no tienen autenticación propia (el JWT se valida
  solo en el gateway y profile no está enrutado); es previo a esta función y debe revisarse aparte.
