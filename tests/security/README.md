# Pruebas de seguridad con OWASP ZAP (4.4.4)

Escaneo **base** (pasivo) con la imagen oficial `zaproxy/zap-stable:2.17.0`. ZAP recorre la web MYPE, también con el spider AJAX porque es una SPA, y revisa cabeceras, cookies y contenido de cada respuesta. **No ataca:** se puede pasar contra AKS sin riesgo.

```bash
tests/security/zap-baseline.sh                 # contra AKS
tests/security/zap-baseline.sh http://localhost:3000
```

Deja un informe HTML y otro JSON en `tests/security/results/` (fuera de git). `rules.tsv` sirve para aceptar un riesgo con su justificación; hoy está vacío, así que se reporta todo.

## Primera ejecución (25 nov 2026, AKS)

Ningún hallazgo alto. Lo que encontró:

| Riesgo | Hallazgo | Dónde se corrige |
|---|---|---|
| Medio | Sin `Content-Security-Policy` | `nginx.conf` de la web (vankoo-mype-web) |
| Medio | Sin protección contra clickjacking (`X-Frame-Options` o `frame-ancestors`) | Ídem |
| Bajo | Sin `X-Content-Type-Options: nosniff` | Ídem |
| Bajo | Sin `Permissions-Policy` | Ídem |
| Bajo | Sin `Cross-Origin-Opener/Embedder/Resource-Policy` | Ídem |
| Informativo | Token de sesión en `localStorage` | Diseño de la web (decisión documentada en IAM) |

**Pasó, entre otros:**
- HSTS (`Strict-Transport-Security`, que pone ingress-nginx con el certificado);
- cookies seguras;
- sin librerías JS vulnerables conocidas (Retire.js);
- sin fugas por cabeceras del servidor;
- sin contenido mixto.

Corregir las cabeceras y volver a escanear es la evidencia de la «corrección aplicada» que pide el 4.4.4.

## Más allá del escaneo base

El escaneo **activo** (`zap-full-scan.py`, o `zap-api-scan.py` con el OpenAPI de cada servicio) sí envía ataques: inyecciones, XSS, etc. Pásalo solo contra un entorno propio y avisando al equipo, porque crea datos basura y puede disparar las alertas del monitoreo.
