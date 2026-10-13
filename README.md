# Vankoo Infra

Este repo contiene la infraestructura de Vankoo para levantar los servicios de Vankoo en un entorno local, utilizando Docker Compose.

## Introducción

Se recomienda usar DataGrip para este repositorio, ya que tiene soporte para Docker Compose (ver los logs y ejecutar los scripts) y para las diferentes bases de datos que se usan en Vankoo (PostgreSQL, MongoDB, Oracle, Redis). Sin embargo, también puedes usar cualquier otro editor de código como Visual Studio Code o incluso solo la terminal para ejecutar los comandos manualmente.

## Configuración de DataGrip

Te recomiendo instalar estos plugins antes que nada:

- YAML: indispensable para que DataGrip use la indentación correcta en los archivos YAML, como el `docker-compose.yaml`.
- Docker: para poder ver los logs de los contenedores de Docker.
- Shell Script: para poder ejecutar los scripts de shell (.sh) desde DataGrip.
- .env files: para poder trabajar con archivos .env desde DataGrip.
- Terminal: para tener una terminal integrada en DataGrip que no trae por defecto (aunque no es indispensable si prefieres una terminal externa).

También puedes instalar temas para mejorar la experiencia de usuario, como el tema "Material Theme UI" o "One Dark Theme", así como iconos para los archivos, como "Material Icon Theme" o "Atom Material Icons". Esto es opcional.

## Configurar las variables de entorno

Se incluye un archivo `.env.example` con las variables de entorno necesarias para levantar los servicios de Vankoo. Deberás crear un archivo `.env` en la raíz del repositorio y copiar las variables de entorno del archivo `.env.example` al archivo `.env`. Luego, puedes modificar las variables de entorno según tus necesidades.

Ten en cuenta que el archivo `docker-compose.yaml` ya tiene variables de entorno por defecto, por lo que no será estrictamente necesario configurar el archivo `.env` para levantar los servicios de Vankoo, pero es recomendable hacerlo para tener un mejor control sobre las variables de entorno y para evitar posibles conflictos con otras aplicaciones que puedan estar usando las mismas variables de entorno.

## Usar los scripts

- Todos son scripts de shell (`.sh`). En Linux y macOS se ejecutan directamente; en Windows, desde Git Bash o WSL.
- Los de `scripts/local/` manejan el entorno local con Docker Compose, y los de `scripts/azure/` el despliegue en Azure. Se pueden ejecutar desde cualquier carpeta.

Si estás en DataGrip, puedes ejecutar los scripts con el plugin "Shell Script" para que que aparezca un botón de "Run" al lado de cada script.

## Usar el docker compose

### Para levantar los servicios:

- Puedes ejecutar el script `scripts/local/local-start.sh` para levantar los servicios. Este script levantará los servicios de Vankoo utilizando Docker Compose.
- También puedes usar el comando `docker compose up --build -d` en la raíz del repositorio. Esto levantará todos los servicios de Vankoo en contenedores de Docker.

### Para detener los servicios:

- Puedes ejecutar el script `scripts/local/local-stop.sh` para detener los servicios. Este script detendrá los servicios de Vankoo utilizando Docker Compose, sin borrar sus datos.
- También puedes usar el comando `docker compose stop` en la raíz del repositorio. Esto detendrá todos los servicios de Vankoo que estén corriendo en contenedores de Docker.

### Para eliminar los servicios:

- Puedes ejecutar el script `scripts/local/local-remove.sh` para eliminar los servicios. Este script eliminará los contenedores, las redes y también los volúmenes, es decir, los datos de las bases de datos (`docker compose down -v`).
- También puedes usar el comando `docker compose down` en la raíz del repositorio. Esto eliminará los contenedores y las redes de Vankoo, pero conservará los volúmenes; para borrarlos también, añade `-v`.

> Nota: DataGrip no tiene terminal integrada, así que deberás descargar el plugin `Terminal` oficial de JetBrains si quieres ejecutar los comandos desde el IDE. En caso quieras ejecutarlos manualmente sin los scripts, tendrás que hacerlo desde una terminal externa como Git Bash o WSL (en Windows) o Terminal (en macOS o Linux). También te sugiero descargar Warp, que es una terminal más moderna y con mejor experiencia de usuario que las terminales tradicionales, pero no es indispensable.

### Para ver los logs de los servicios:

Usa la pestaña "Services" de DataGrip para ver los logs de los servicios de Vankoo. Esto te permitirá ver la salida de los servicios en la consola de DataGrip.

## Usar las bases de datos

Para crear un nuevo datasource y conectarse a las bases de datos levantadas en docker:

1. Ve a la pestaña "Database" en DataGrip.
2. Haz clic en el botón "+" para agregar un nuevo datasource.
3. Selecciona el tipo de base de datos que quieres conectar (PostgreSQL, MongoDB, Oracle, Redis).
4. Configura la conexión con los siguientes datos:
   - Name: te sugiero usar la siguiente convención: `{tipo-de-bd}-{microservicio}-docker-{puerto}` (ejemplo: `postgresql-iam-docker-5432`).
   - Host: localhost
   - Port: el puerto que corresponda según el tipo de base de datos y el microservicio (puedes ver los puertos en el archivo `docker-compose.yaml` o en tus variables de entorno).
   - User: el usuario que corresponda según el tipo de base de datos y el microservicio (puedes ver los usuarios en el archivo `docker-compose.yaml` o en tus variables de entorno).
   - Password: la contraseña que corresponda según el tipo de base de datos y el microservicio (puedes ver las contraseñas en el archivo `docker-compose.yaml` o en tus variables de entorno).
   - Database: el nombre de la base de datos que corresponda según el tipo de base de datos y el microservicio (puedes ver los nombres de las bases de datos en el archivo `docker-compose.yaml` o en tus variables de entorno).
5. Haz clic en "Test Connection" para verificar que la conexión se estableció correctamente.
6. Si la conexión es exitosa, haz clic en "Apply" y luego en "OK" para guardar el datasource.

> Nota: Algunas bases de datos, como Oracle, pueden requerir configuraciones adicionales. Para ello, revisa el archivo [Conectarse a Oracle Database con Data Source](docs/guides/oracle-data-source.md) para configurar correctamente la conexión a Oracle Database en DataGrip.

## Despliegue en Azure

El despliegue en Azure se hace con Terraform y tres scripts: `scripts/azure/azure-deploy.sh` para crear, actualizar o reanudar, `scripts/azure/azure-stop.sh` para detener sin borrar y `scripts/azure/azure-destroy.sh` para borrar todo. Los requisitos, las capas y cómo añadir un servicio están en [terraform/README.md](terraform/README.md).

## Info adicional

El resto de carpetas (`database` y `postman`) no se usan aún, se hablará luego de eso.

Los servicios restantes del `docker-compose.yaml` se irán agregando a medida que vayamos avanzando.