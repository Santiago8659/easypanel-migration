# EASYPANEL_MIGRATION

Migración de servicios autoalojados entre dos servidores **EasyPanel** (ambos corren Docker por debajo):
**Chatwoot** (crítico, tiene la BD), **n8n** y **LangGraph**.

La estrategia: respaldar las bases de datos PostgreSQL a **Backblaze B2** (S3-compatible) y
consumirlas desde ahí para restaurarlas en el servidor destino. Todo el tooling
(`pg_dump`, `pg_restore`, `psql`, `aws`) corre en **contenedores efímeros**, así que el
único requisito en cualquiera de los dos hosts es **Docker**.

> ⚠️ Nada se ejecuta contra infra real hasta que tú lo decidas. El flujo está probado de
> punta a punta con un test local (ver más abajo).

## Por qué este diseño (servidor flojo)

El servidor es limitado, así que:
- **Sin instalar nada** además de Docker (no aws-cli, no postgres-client en el host).
- **`--stream`**: el dump va `pg_dump | aws s3 cp -` directo a B2 **sin escribir a disco local**.
- **`JOBS=1`** por defecto (sin paralelismo) para no saturar CPU/RAM.
- Formato de dump **custom comprimido** (`-Fc`): pesa poco y es fiable.

## Estructura

```
.env.example          # plantilla de configuración (copiar a .env)
migrate.sh            # orquestador: dump | restore | verify | all
lib/common.sh         # helpers compartidos (docker, B2, postgres, env)
scripts/
  00-preflight.sh     # chequeos: docker, B2, conectividad, versiones
  10-dump-db.sh       # dump de una BD -> B2   (--stream para no usar disco)
  20-dump-storage.sh  # empaqueta storage local de Chatwoot -> B2
  30-restore-db.sh    # descarga de B2 -> restaura en destino (--recreate)
  40-restore-storage.sh
  50-verify.sh        # compara conteos de filas origen vs destino
  b2.sh               # ls / latest sobre el bucket
test/
  docker-compose.yml  # pg-src + pg-dst + minio (simula B2)
  seed.sql            # datos de prueba tipo Chatwoot
  run-test.sh         # prueba E2E: dump -> B2 -> restore -> verify
```

## Requisitos

- Docker (con el daemon corriendo) en la máquina desde donde ejecutes los scripts.
- Un bucket en Backblaze B2 + Application Key (keyID + appKey) con permisos de lectura/escritura.
- Acceso de red a los Postgres de origen y/o destino (ver "Conectividad" abajo).

## Configuración

```bash
cp .env.example .env
# Edita .env con: credenciales B2, hosts/usuarios/passwords de cada Postgres,
# y PG_IMAGE con un major >= al de tu servidor de origen.
```

### Conectividad a las BDs (EasyPanel)

Tienes dos formas de alcanzar el Postgres de un proyecto EasyPanel:

1. **Por la red de Docker del proyecto** (recomendado, no expone la BD):
   - Mira el nombre de la red: `docker network ls`
   - Ponla en `MIG_DOCKER_NETWORK` y usa el **nombre del servicio** de Postgres como host
     (p.ej. `CHATWOOT_SRC_PG_HOST=chatwoot_postgres`).
2. **Por puerto publicado / IP**: deja `MIG_DOCKER_NETWORK=` y usa el host:puerto expuesto.

Si cada servicio tiene su propio Postgres, usa los overrides por servicio del `.env`
(`CHATWOOT_SRC_PG_*`, `N8N_SRC_PG_*`, etc.).

## Uso

```bash
# 0) Chequeos previos (no modifica nada)
bash scripts/00-preflight.sh

# 1) Dump de todas las BDs de origen a B2
bash migrate.sh dump
#   o, en servidor con poco disco:
bash migrate.sh dump --stream

# 2) Restore en destino (BD limpia)
bash migrate.sh restore --recreate

# 3) Verificar que los conteos cuadran
bash migrate.sh verify

# Todo de una:
bash migrate.sh all --recreate

# Por servicio individual:
bash scripts/10-dump-db.sh chatwoot --stream
bash scripts/30-restore-db.sh chatwoot --recreate
bash scripts/50-verify.sh chatwoot

# Storage local de Chatwoot (adjuntos):
bash scripts/20-dump-storage.sh --path /ruta/al/storage
bash scripts/40-restore-storage.sh --path /ruta/destino

# Inspeccionar el bucket:
bash scripts/b2.sh ls
bash scripts/b2.sh ls chatwoot
```

## Probarlo sin tocar infra real

```bash
bash test/run-test.sh
```

Levanta `pg-src` (con datos semilla), `pg-dst` (vacío) y `minio` (simula B2),
corre el flujo real **dump → B2 → restore → verify** y comprueba que los conteos
de filas coinciden. `--keep` deja el entorno arriba para inspeccionar.

> ✅ Probado: el roundtrip completo y el modo `--stream` pasan con conteos idénticos.

## Runbook de cutover (migración real)

1. **Backup verificado** del origen: `bash migrate.sh dump` (queda en B2 con checksum).
2. **Provisionar destino** en el EasyPanel nuevo: crear los servicios (Chatwoot/n8n/LangGraph)
   con **las mismas versiones** y, sobre todo, **las mismas claves de cifrado**:
   - Chatwoot: `SECRET_KEY_BASE`
   - n8n: `N8N_ENCRYPTION_KEY`
   - (sin ellas, los datos cifrados quedan inservibles aunque la BD migre bien).
3. **Restaurar** en destino: `bash migrate.sh restore --recreate`.
4. **Verificar**: `bash migrate.sh verify` + login manual y revisión funcional.
5. **Ventana de corte**: poner origen en mantenimiento, hacer **dump final** (datos frescos),
   restaurar de nuevo, migrar storage, y **repuntar DNS** al destino.
6. **Validación post-corte** y monitoreo.
7. **Decomisionar origen** solo tras un periodo de gracia.

Detalles y notas de cada servicio en [CLAUDE.md](CLAUDE.md).

## Notas importantes

- **Extensiones de Postgres**: el dump incluye `CREATE EXTENSION` (p.ej. `pgvector`, `pg_trgm`
  que usa Chatwoot). El **servidor destino** debe tener esas extensiones disponibles. El
  contenedor cliente (`PG_IMAGE`) solo ejecuta `pg_restore`, no aporta extensiones al server.
- **Modo `--stream`** no genera checksum sidecar; la integridad la valida `pg_restore` al leer
  el dump. El modo archivo (default) sí guarda y verifica `sha256`.
- **`--recreate`** hace `DROP DATABASE` en destino: úsalo solo en migración limpia.
