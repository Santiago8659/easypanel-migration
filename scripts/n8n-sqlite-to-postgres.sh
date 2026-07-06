#!/usr/bin/env bash
# =============================================================================
# n8n-sqlite-to-postgres.sh - Migra n8n de SQLite (server viejo) a Postgres
# (server nuevo) con pgloader. IDÉNTICO: workflows, credenciales, usuarios,
# proyectos, tags Y ejecuciones (execution history), preservando IDs.
#
# Basado en el script pgloader de la comunidad n8n (3 fases):
#   1. tablas dinámicas 'data_table_user_%' (casteo datetime->timestamptz)
#   2. todos los datos excepto execution_data y migrations
#   3. execution_data (blobs grandes, batching especial)
# Fuente: gist.github.com/kacrouse/92e95097bc22d8b351f637134a79fc1f
#
# ── PREREQUISITOS (server NUEVO) ─────────────────────────────────────────────
#  1. Servicios n8n + n8n-runner + n8n-db (plantilla Postgres) creados.
#  2. n8n ARRANCADO UNA VEZ para que cree el esquema en Postgres, y LUEGO
#     DETENIDO (app parada; n8n-db SIGUE corriendo). Sin esto, no hay tablas.
#  3. N8N_ENCRYPTION_KEY del n8n nuevo = la del viejo (si no, credenciales
#     ilegibles). n8n MISMA versión en ambos (mismo set de migraciones).
#  4. Backup del volumen viejo en B2 (dump-volume.sh n8n) — trae database.sqlite.
#
# Red de seguridad: si algo sale mal, el Postgres es reconstruible (borrar la
# BD + arrancar n8n de nuevo recrea el esquema) y el SQLite viejo sigue intacto.
#
# Uso (server NUEVO):
#   bash scripts/n8n-sqlite-to-postgres.sh [--backup <archivo.tar.gz>]
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

PGLOADER_IMAGE="${PGLOADER_IMAGE:-dimitri/pgloader:latest}"
DB_FILTER="${N8N_DB_FILTER:-automate_n8n-db}"
APP_FILTER="${N8N_APP_FILTER:-automate_n8n}"
PG_DB="${N8N_PG_DB:-automate}"
PG_USER="${N8N_PG_USER:-postgres}"
BACKUP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP="$2"; shift 2 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

# --- localizar el contenedor de Postgres del n8n nuevo ---
DBCID=$(docker ps --filter "name=$DB_FILTER" --format '{{.Names}}' | head -1)
[ -n "$DBCID" ] || die "No encontré '$DB_FILTER' corriendo. ¿Creaste la plantilla n8n Postgres?"
info "Postgres n8n: $DBCID"
PG_PASS=$(docker exec "$DBCID" printenv POSTGRES_PASSWORD 2>/dev/null | tr -d '\r\n')
[ -n "$PG_PASS" ] || die "No pude leer POSTGRES_PASSWORD del contenedor."

# --- avisar si la app n8n sigue corriendo (no debe, para no escribir durante la migración) ---
APPCID=$(docker ps --format '{{.Names}}' | grep "$APP_FILTER" | grep -vE 'runner|\-db' | head -1 || true)
if [ -n "$APPCID" ]; then
  warn "El servicio n8n (app: $APPCID) parece ESTAR CORRIENDO. Deténlo en EasyPanel antes de continuar (Ctrl+C para abortar)."
  sleep 5
fi

# --- verificar que el esquema exista (n8n arrancó una vez) ---
has_schema=$(docker exec "$DBCID" psql -U "$PG_USER" -d "$PG_DB" -tAc \
  "SELECT to_regclass('public.workflow_entity') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]' || echo "f")
[ "$has_schema" = "t" ] || die "El esquema de n8n NO existe en Postgres. Arranca el n8n nuevo UNA VEZ (crea las tablas) y luego páralo. Reintenta."
log "Esquema de n8n presente en Postgres."

# --- resolver backup ---
if [ -z "$BACKUP" ]; then
  BACKUP=$(awscli s3 cp "$(s3_base)/volumes/n8n/latest.txt" - 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$BACKUP" ] || die "No hay 'latest.txt' del volumen n8n en B2. Usa --backup <archivo>."
fi
info "Backup a usar: $BACKUP"

# --- descargar y extraer database.sqlite ---
step "1/4 Descargando SQLite desde B2"
awscli s3 cp "$(s3_base)/volumes/n8n/$BACKUP" "/work/$BACKUP"
rm -rf "$WORK_DIR/n8n-sqlite" "$WORK_DIR/pgloader"; mkdir -p "$WORK_DIR/n8n-sqlite" "$WORK_DIR/pgloader"
tar xzf "$WORK_DIR/$BACKUP" -C "$WORK_DIR/n8n-sqlite"
SRC_SQLITE=$(find "$WORK_DIR/n8n-sqlite" -name 'database.sqlite' | head -1)
[ -n "$SRC_SQLITE" ] || die "No encontré database.sqlite dentro del backup."
# copia writable (pgloader/WAL puede necesitar abrir en modo escritura)
cp "$SRC_SQLITE" "$WORK_DIR/pgloader/database.sqlite"
info "SQLite: $(du -h "$WORK_DIR/pgloader/database.sqlite" | cut -f1)"

# --- generar los 3 archivos pgloader ---
PGCONN="postgres:${PG_PASS}@localhost:5432/${PG_DB}"

cat > "$WORK_DIR/pgloader/1-schema.load" <<EOF
load database
  from sqlite:///pg/database.sqlite
  into pgsql://${PGCONN}
with include drop, create tables, create indexes, reset sequences, quote identifiers
CAST type datetime to "timestamptz not null default current_timestamp" drop default
including only table names like 'data_table_user_%';
EOF

cat > "$WORK_DIR/pgloader/2-data.load" <<EOF
load database
  from sqlite:///pg/database.sqlite
  into pgsql://${PGCONN}
with include no drop, create no tables, create no indexes, reset sequences, truncate, data only, quote identifiers
excluding table names like 'execution_data', 'migrations'
BEFORE LOAD DO
\$\$ ALTER TABLE "test_case_execution"
     ADD COLUMN IF NOT EXISTS "pastExecutionId" INTEGER,
     ADD COLUMN IF NOT EXISTS "evaluationExecutionId" INTEGER \$\$;
EOF

cat > "$WORK_DIR/pgloader/3-executions.load" <<EOF
load database
  from sqlite:///pg/database.sqlite
  into pgsql://${PGCONN}
with include no drop, create no tables, create no indexes, reset sequences, truncate, data only, quote identifiers,
     workers = 4, concurrency = 1, batch rows = 1, batch size = 20MB, batch concurrency = 1
set work_mem to '16MB', maintenance_work_mem to '512 MB'
including only table names like 'execution_data';
EOF

run_pgloader() {
  # --network container:<db> comparte el stack de red del Postgres -> localhost:5432
  docker run --rm --network "container:$DBCID" \
    -v "$WORK_DIR/pgloader:/pg" \
    "$PGLOADER_IMAGE" pgloader --verbose "/pg/$1"
}

step "2/4 pgloader fase 1: tablas dinámicas (data tables)"
run_pgloader 1-schema.load || warn "Fase 1 con avisos (normal si no usas 'data tables')."

step "3/4 pgloader fase 2: datos (workflows, credenciales, usuarios, ejecuciones-metadata...)"
run_pgloader 2-data.load

step "4/4 pgloader fase 3: execution_data (blobs de ejecuciones)"
run_pgloader 3-executions.load

step "Verificación"
docker exec "$DBCID" psql -U "$PG_USER" -d "$PG_DB" -c \
  "SELECT (SELECT count(*) FROM workflow_entity) AS workflows,
          (SELECT count(*) FROM credentials_entity) AS credenciales,
          (SELECT count(*) FROM execution_entity) AS ejecuciones,
          (SELECT count(*) FROM \"user\") AS usuarios;"

rm -rf "$WORK_DIR/n8n-sqlite" "$WORK_DIR/$BACKUP"
# el sqlite temporal en pgloader/ contiene datos: bórralo también
rm -f "$WORK_DIR/pgloader/database.sqlite"
log "Migración pgloader terminada. Compara los conteos con el viejo."
info "Ahora: en EasyPanel arranca el servicio n8n (app) y valida:"
echo "   · workflows presentes y activos"
echo "   · abrir una credencial y probar un nodo (descifra = encryption key OK)"
echo "   · Executions: aparece el historial"
warn "Si algo quedó mal: borra la BD 'automate', arranca n8n para recrear esquema, y reintenta. El SQLite viejo sigue intacto."
