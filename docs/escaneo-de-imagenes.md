# Escaneo de imágenes antes de publicarlas

El workflow reutilizable `.github/workflows/deliver-container-app.yml` construye la imagen de cada servicio, la escanea
con Trivy y solo entonces la publica en el registro y la despliega. Lo usan los pipelines de IAM, Invoicing y Profile (y
lo usarán Notification y el gateway).

## Qué bloquea y qué no

| Hallazgo | Qué pasa |
| --- | --- |
| CRITICAL con arreglo publicado, fuera de los riesgos aceptados | **Bloquea:** la imagen no se publica ni se despliega. |
| CRITICAL sin arreglo | Se informa. Bloquear no serviría: no hay versión a la que subir. |
| HIGH (con o sin arreglo) | Se informa. |

Se informa en dos sitios:
- **Resumen del job** `Build and scan image`: cuántos hallazgos hay por severidad, cuántos tienen arreglo, cuáles están
  aceptados y cuáles bloquean, con el detalle plegado.
- **Pestaña Security del repo del servicio** (code scanning), con la categoría `container-image/<imagen>`. Para eso el
  job `deliver` del servicio tiene que conceder `security-events: write`. Si no lo concede, el job
  `Upload scan to code scanning` avisa y la entrega sigue: el informe queda en el artefacto `trivy-image-sarif` del run.
  Un repo privado (hoy Notification) necesita además GitHub Code Security.

```yaml
  deliver:
    permissions:
      contents: read
      id-token: write
      security-events: write # opcional: sube el escaneo a la pestaña Security
    uses: liquilabshq/vankoo-infra/.github/workflows/deliver-container-app.yml@develop
```

El permiso no se pide dentro del workflow reutilizable a propósito: un job que pide más de lo que concede el caller hace
fallar el run entero al arrancar, y los callers actuales solo conceden `contents: read` e `id-token: write`.

La configuración de Trivy y la lista de ignorados salen del workflow, nunca del repo del servicio: un `trivy.yaml` o un
`.trivyignore` del servicio no puede silenciar el gate. La versión de Trivy está fijada (`SCANNER_VERSION`) y las
actions, por commit.

## Estado de las imágenes al activar el gate

Escaneo del 25 nov 2026 con Trivy 0.76.2 de las imágenes desplegadas (etiqueta `aks`; en Invoicing y Profile también
`development`, con el mismo resultado). Cuenta paquetes afectados, no CVE distintos.

| Imagen | Base | CRITICAL | CRITICAL con arreglo | HIGH | HIGH con arreglo |
| --- | --- | ---: | ---: | ---: | ---: |
| iam-service | Ubuntu 22.04 (Java) | 20 | 20 | 48 | 48 |
| invoicing-service | Ubuntu 24.04 (.NET) | 0 | 0 | 1 | 1 |
| profile-service | Alpine 3.24 (Node.js) | 3 | 3 | 57 | 57 |
| notification-service | Alpine 3.24 (Node.js) | 2 | 2 | 31 | 31 |
| api-gateway | Ubuntu 22.04 (Java) | 6 | 6 | 50 | 50 |

Ningún hallazgo está en los paquetes del sistema operativo: todos son dependencias de la aplicación (los JAR de Spring
Boot y los `node_modules`), y todos tienen arreglo.

## Riesgos aceptados

### CRITICAL con arreglo ya desplegados (22 CVE, vencen el 31 ene 2027)

**Qué se acepta.** Los 22 CVE CRITICAL con arreglo que ya tenían las imágenes desplegadas el día que se activó el gate.
La lista está en el paso `Write the accepted risks` del workflow, con formato `.trivyignore` y fecha de vencimiento
(`exp:2027-01-31`). Solo se ignoran esos identificadores: cualquier CRITICAL nuevo con arreglo bloquea. El escaneo
informativo y la pestaña Security los siguen mostrando.

| Servicio | Paquete | CVE | Arreglo según Trivy |
| --- | --- | --- | --- |
| IAM, gateway | `spring-boot` 4.0.2 / 4.0.3 | CVE-2026-40976 | 4.0.6 |
| IAM | `spring-security-web` 7.0.2 | CVE-2026-22732 | 7.0.4 |
| IAM | `spring-webmvc` 7.0.3 | CVE-2026-47884, CVE-2026-47890 | 7.0.9 |
| gateway | `spring-webflux` 7.0.5 | CVE-2026-47890, CVE-2026-47892 | 7.0.9 |
| IAM | `tomcat-embed-core` 11.0.18 | CVE-2026-41293, CVE-2026-43512, CVE-2026-43515, CVE-2026-55276, CVE-2026-65182, CVE-2026-65905, CVE-2026-68525 | 11.0.25 |
| IAM | `thymeleaf`, `thymeleaf-spring6` 3.1.3 | CVE-2026-40477, CVE-2026-40478, CVE-2026-41901 | 3.1.5 |
| IAM | `kafka-clients` 4.1.1 | CVE-2026-33557 | 4.1.2 |
| gateway | `netty-handler` 4.2.10 | CVE-2026-75595 | 4.2.17 |
| IAM, gateway | `bcprov-jdk18on` 1.81 | CVE-2025-14813, CVE-2026-8763 | 1.85 |
| Profile, Notification | `form-data` 2.3.3 | CVE-2025-7783 | 2.5.4 |
| Profile | `proxy-addr` 2.0.7 | CVE-2026-90711 | 2.0.8 |
| Profile, Notification | `tar` 7.5.9 (dentro del pnpm global de la imagen) | CVE-2026-59873 | 7.5.19 |

**Por qué.** Esas vulnerabilidades ya están en lo desplegado. Bloquear la entrega no las quita de ahí: solo impediría
publicar el arreglo cuando llegue, y dejaría a cuatro de los cinco servicios sin poder desplegar el mismo día de la
entrega del curso. El arreglo es subir versiones en el repo de cada servicio, que es trabajo de sus dueños y no de este
repo.

**Qué lo mitiga.**
- El tráfico externo entra por el gateway: en Container Apps, IAM, Invoicing y Profile solo tienen ingress interno
  (`terraform/apps/main.tf`).
- La aceptación vence sola: desde el 31 ene 2027 esos CVE vuelven a bloquear sin que nadie tenga que acordarse.
- Siguen visibles en el resumen de cada entrega y en la pestaña Security.

**Plan de corrección.**
1. IAM y gateway: subir Spring Boot a la última 4.0.x y `bcprov-jdk18on` a 1.85 o posterior, y comprobar con el escaneo
   que Tomcat, Thymeleaf, Kafka y Netty llegan a las versiones de la tabla (si no, fijarlas).
2. Profile y Notification: actualizar las dependencias que traen `form-data` 2.3.3 y `proxy-addr` 2.0.7, y no dejar pnpm
   en la imagen final (o usar uno con `tar` 7.5.19 o posterior).
3. Al corregir un servicio, quitar de la lista los CVE que ya no aparezcan en ninguna imagen.
