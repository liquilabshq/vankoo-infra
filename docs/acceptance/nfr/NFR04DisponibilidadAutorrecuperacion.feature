# language: es
@NFR @NFR04 @disponibilidad @infra @kubernetes
Característica: Disponibilidad ante la falla de un microservicio
  Como empresario MYPE o inversionista
  Quiero que la plataforma siga operando aunque falle un servicio
  Para poder consultar y operar mis facturas en cualquier momento

  # Atributo de calidad 2.1.1: Disponibilidad. Medida: 99,5 % de uptime.
  # Kubernetes usa las sondas de Spring Boot Actuator para reiniciar o aislar los pods.

  Escenario: Reiniciar automáticamente un servicio que deja de responder
    Dado que Investment está desplegado en AKS con estas sondas:
      | sonda     | ruta                       | periodo | fallos permitidos |
      | liveness  | /actuator/health/liveness  | 20 s    | 3                 |
      | readiness | /actuator/health/readiness | 10 s    | 3                 |
    Cuando el pod de Investment deja de responder a la sonda de liveness
    Entonces Kubernetes reinicia el contenedor sin intervención del equipo
    Y el servicio vuelve a estar disponible en menos de 2 minutos

  Escenario: No enviar tráfico a un pod que todavía no está listo
    Dado que un pod nuevo de Investment está arrancando
    Y su sonda de readiness todavía no responde correctamente
    Cuando el Service de Kubernetes reparte las peticiones
    Entonces no le envía peticiones a ese pod
    Y las peticiones las atienden los pods que ya están listos

  Escenario: Aislar la falla de un servicio del resto de la plataforma
    Dado que el pod de Notification está caído
    Cuando un inversionista compra una participación
    Entonces la compra se registra correctamente en Investment
    Y el evento queda en Kafka para notificarse cuando Notification se recupere

  Escenario: Medir la disponibilidad mensual
    Dado que el monitoreo registra la disponibilidad del API Gateway durante un mes
    Cuando se calcula el porcentaje de tiempo en que respondió correctamente
    Entonces la disponibilidad es de al menos 99,5 %
