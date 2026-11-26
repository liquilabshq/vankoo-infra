# language: es
@NFR @NFR03 @rendimiento @infra @k6
Característica: Rendimiento del marketplace bajo carga
  Como inversionista
  Quiero que el marketplace responda rápido aunque muchos usuarios lo usen
  Para no perder oportunidades mientras se fondean

  # Atributo de calidad 2.1.1: Rendimiento. Se ejecuta con k6 (tests/performance)
  # y usa los mismos SLO del monitoreo (k8s/monitoring).

  Escenario: Cumplir el SLO con la carga esperada
    Dado que Vankoo está desplegado en AKS
    Y la prueba "load" simula inversionistas que recorren el marketplace:
      | etapa         | duración | usuarios virtuales |
      | subida        | 1 min    | 0 a 20             |
      | carga estable | 5 min    | 20                 |
      | bajada        | 1 min    | 20 a 0             |
    Cuando termina la ejecución de k6
    Entonces se cumplen estos umbrales:
      | métrica          | umbral    |
      | p95 de respuesta | < 1000 ms |
      | tasa de errores  | < 1 %     |

  Escenario: Escalar horizontalmente ante un pico de demanda
    Dado que la prueba "stress" aumenta por escalones hasta 80 usuarios virtuales
    Cuando el uso de CPU de Investment supera el 70 %
    Entonces el HPA aumenta sus réplicas sin pasar de 3
    Y el p95 de respuesta se mantiene por debajo de 3000 ms
