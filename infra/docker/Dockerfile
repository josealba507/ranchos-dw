# Imagen del Cloud Run Job que corre "dbt build --target prod" después de
# cada sincronización 3x/día del pipeline EL (ver
# infra/workflows/trigger_el_transfer.yaml y docs/fase_orquestacion_dbt.md).
#
# python:3.12-slim para matchear la versión de Python usada en desarrollo
# local (.venv). `dbt deps` corre en BUILD TIME, no en cada ejecución del
# job — evita depender de la disponibilidad del Hub de paquetes de dbt en
# cada corrida programada y acelera el arranque del contenedor.
FROM python:3.12-slim

WORKDIR /app

# Solo requirements.txt primero — aprovecha la cache de capas de Docker,
# así un cambio en los modelos (sin tocar dependencias) no reinstala nada.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# El resto del proyecto dbt — mismo contenido que un checkout local, salvo
# lo excluido en .dockerignore (.venv, target, dbt_packages, logs, .git).
COPY dbt_project.yml packages.yml package-lock.yml ./
COPY models ./models
COPY macros ./macros
COPY snapshots ./snapshots
COPY tests ./tests
COPY seeds ./seeds
COPY analyses ./analyses

# dbt_profiles.yml de este directorio (infra/docker/), NO el de
# ~/.dbt/profiles.yml del desarrollador — sin secretos (method: oauth, sin
# key file), ver el comentario dentro de ese archivo para el porqué es
# seguro versionarlo. Nombrado distinto a "profiles.yml" a propósito: ese
# nombre literal ya está en .gitignore/.gcloudignore (para nunca commitear
# el profiles.yml LOCAL de un desarrollador) y ese patrón, sin `/` inicial,
# matchea en cualquier profundidad — incluido este archivo, aunque sea uno
# distinto y sin secretos. Renombrar evita la colisión en vez de tocar el
# .gitignore existente.
COPY infra/docker/dbt_profiles.yml /root/.dbt/profiles.yml

RUN dbt deps

# method: oauth con Application Default Credentials — en Cloud Run, ADC
# resuelve solo contra el service account adjunto al Job (sin gcloud login
# ni key file), mismo mecanismo que ya usa el desarrollador en local vía
# `gcloud auth application-default login`.
CMD ["dbt", "build", "--target", "prod"]
