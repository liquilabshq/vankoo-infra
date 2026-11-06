# Registro de despliegue — Sprint 4, 2026-11-05 (hora de Lima)

## Preparación y preflight iniciales

- Rama Infra: `feature/investment-azure-deployment`.
- Rama Investment: `feature/azure-deployment-11`.
- Terraform fmt y validate: correctos.
- Terraform test: cuatro planes con proveedores mock, cuatro correctos.
- Bash `-n`: correcto para script de operación y plantilla de instalación Oracle.
- Investment `mvn test -q`: salida 0, incluidas tres pruebas nuevas de configuración
  y arranque independiente/persistencia del outbox. BD H2 aislada; no valida Oracle.
- Se creó una clave administrativa local fuera de los repositorios; Terraform
  recibe únicamente su parte pública. No se incorpora material privado a Git.
- Backend Investment inicializado en la cuenta de estado existente, clave
  `investment.tfstate`. No se descargaron estados a archivos versionados.
- Plan remoto bootstrap obtenido: **16 to add, 0 to change, 0 to destroy**.
  El plan no es una ejecución ni garantiza disponibilidad de tamaño/cuota de VM.
- Docker: primer intento falló por DNS al descargar Maven Central; reintento completo
  correcto. Imagen local `vankoo-investment-service:azure-validation`, no publicada.
- Entrypoint TLS probado sobre Temurin 25 JRE con certificado sintético: correcto.
  No sustituye una prueba de handshake Oracle/TCPS real.
- Verificación Java limpia: `mvn clean test -q`, salida 0, 0 fallos y 0 errores.
- Preflight remoto antes de aplicar: `Microsoft.Compute` y `Microsoft.Network`
  están `NotRegistered`; `Microsoft.App` está `Registered`. Se detuvo el despliegue
  antes de crear recursos. Debe registrar los dos proveedores un usuario con permisos
  sobre la suscripción; ser Contributor solo del grupo no garantiza ese permiso.
- Plan bootstrap actualizado y guardado localmente en `bootstrap.tfplan` (ignorado
  por Git): conserva 16 altas, 0 modificaciones y 0 eliminaciones. No aplicado.

## Ejecución real posterior

- Se registraron Compute, Network y DevTestLab. Los intentos B2s y B2als_v2
  fallaron por `SkuNotAvailable`; la red parcial se conservó. D2s_v4 permitió crear
  la VM y su disco Standard SSD de 64 GiB en Central US.
- La extensión `prepare-oracle` terminó correctamente. Azure Run Command confirmó
  Oracle `healthy` y el servicio stunnel `active`.
- Tras registrar DevTestLab se creó el horario pendiente: apagado a las 23:00 Lima;
  no hay encendido automático. El último reintento del bootstrap añadió únicamente
  ese recurso (`1 added, 0 changed, 0 destroyed`).
- Se recogieron los /32 de salida y se publicó la imagen
  `investment-service:5a7f8b9-dirty-20261106012449` en el ACR existente. La etiqueta
  identifica cambios locales sin commit; no equivale a una entrega de CI/CD.
- El despliegue final añadió la regla TLS y actualizó la Container App
  (`1 to add, 1 to change, 0 to destroy`). Se comprobó la imagen real, estado
  `Succeeded/Running` y revisión lista `vankoo-investment-service--0000001`.
- `GET /actuator/health/readiness` devolvió `UP`; este grupo incluye `db`.
  Esto valida la conexión Oracle/TCPS; no se adjuntó un listado de Flyway V1–V5.
- POST de subasta sintética: HTTP 201, id
  `19e7cd72-528b-44d9-a14f-2b5651aeb859`, PEN 1000.00. GET del mismo id: HTTP 200,
  estado `PENDING_VERIFICATION_RISK`, coherente con la integración desactivada.
- Después de reiniciar solo la revisión, una réplica nueva respondió otra vez 200
  con el mismo registro, sin repetir POST. Hubo un `Connection refused` transitorio
  durante el arranque. La respuesta posterior se compartió como texto; su captura
  sigue pendiente. No se probó reiniciar Oracle ni la VM.
- Evidencia e informe en tsp-report, sección 5.2.4.7. Capturas en
  `assets/cap5-product-implementation/sprint-4/deployment-evidence/`.

## Pendientes y límites

Antes de publicar se repitieron Maven (`test -q`, salida 0; XML con 117 casos,
9 omitidos, 0 fallos/errores), Terraform validate y cuatro tests mock (todos pasan),
sintaxis Bash y entrypoint TLS sin red (`ENTRYPOINT_TLS_TRUST_OK`). Los tests mock
sobrescriben las variables locales de despliegue para no depender de sus archivos.
Investment recibió revisión independiente APPROVED contra sus checkpoints.
Estas verificaciones no ejecutaron apply ni redesplegaron la imagen.

Integración con Gateway y Risk, alineación JWT y bindings,
credenciales y gestión del outbox antes de activar Event Hubs. No se aplicaron
cambios de Gateway/Event Hubs como parte de este despliegue. No se afirma que se
hayan verificado apagado/reanudación ni recuperación de la VM.
