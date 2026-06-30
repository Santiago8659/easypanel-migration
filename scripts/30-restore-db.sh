#!/usr/bin/env bash
# =============================================================================
# 30-restore-db.sh - Descarga un dump de B2 y lo restaura en el DESTINO
#
# Uso:
#   bash scripts/30-restore-db.sh <servicio> [opciones]
#
# Opciones:
#   --backup <archivo>  Restaurar un dump específico (por defecto: latest.txt en B2)
#   --recreate          DROP + CREATE de la BD destino antes de restaurar (recomendado en migración limpia)
#   --force             Permite restaurar sobre una BD existente sin recrearla
#   --jobs N            Paralelismo de pg_restore (default: JOBS del .env, normalmente 1)
#   --keep              No borrar el dump descargado
#   --dry-run           Mostrar sin ejecutar
#
# Ejemplos:
#   bash scripts/30-restore-db.sh chatwoot --recreate
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

SERVICE="${1:-}"; [ -n "$SERVICE" ] || die "Uso: $0 <servicio> [--recreate] [--backup f] ..."
shift || true
BACKUP=""; RECREATE=false; FORCE=false; KEEP=false; DRY_RUN=false
JOBS_N="${JOBS:-1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)   BACKUP="$2"; shift 2 ;;
    --recreate) RECREATE=true; shift ;;
    --force)    FORCE=true; shift ;;
    --jobs)     JOBS_N="$2"; shift 2 ;;
    --keep)     KEEP=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

host=$(svc_get "$SERVICE" DST HOST); port=$(svc_get "$SERVICE" DST PORT)
user=$(svc_get "$SERVICE" DST USER); pass=$(svc_get "$SERVICE" DST PASSWORD)
db=$(svc_dbname "$SERVICE")
[ -n "$host" ] || die "Falta DST_PG_HOST (o $(upper "$SERVICE")_DST_PG_HOST) en .env"
port="${port:-5432}"

dpsql() { pgtool "$host" "$port" "$user" "$pass" psql "$@"; }

step "Restore de '$SERVICE' en destino $host:$port (BD: $db)"

if [ -z "$BACKUP" ]; then
  info "Resolviendo backup más reciente (latest.txt)..."
  BACKUP=$(awscli s3 cp "$(s3_base)/$SERVICE/latest.txt" - 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$BACKUP" ] || die "No hay 'latest.txt' en B2 para '$SERVICE'. Usa --backup <archivo> o corre el dump primero."
fi
info "Backup a restaurar: $BACKUP"

if $DRY_RUN; then
  info "[DRY-RUN] descargar $(s3_base)/$SERVICE/$BACKUP y pg_restore -d $db (recreate=$RECREATE)"
  exit 0
fi

step "Descargando desde B2"
awscli s3 cp "$(s3_base)/$SERVICE/$BACKUP" "/work/$BACKUP"
if awscli s3 cp "$(s3_base)/$SERVICE/$BACKUP.sha256" "/work/$BACKUP.sha256" 2>/dev/null; then
  info "Verificando sha256..."
  sha256_check "$BACKUP" && log "Checksum OK." || die "Checksum NO coincide: descarga corrupta."
else
  warn "No hay checksum sidecar (dump en modo stream). Se omite verificación previa."
fi

step "Preparando BD destino"
exists=$(dpsql -d postgres -tAc "select 1 from pg_database where datname='$db'" | tr -d '[:space:]' || true)
if $RECREATE; then
  warn "Recreando BD '$db' (se eliminan datos actuales en destino)..."
  dpsql -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='$db' and pid<>pg_backend_pid()" >/dev/null || true
  dpsql -d postgres -c "DROP DATABASE IF EXISTS \"$db\""
  dpsql -d postgres -c "CREATE DATABASE \"$db\""
elif [ -z "$exists" ]; then
  info "Creando BD '$db' (no existía)..."
  dpsql -d postgres -c "CREATE DATABASE \"$db\""
else
  $FORCE || die "La BD '$db' ya existe en destino. Usa --recreate (reemplazar) o --force (restaurar encima)."
  warn "Restaurando SOBRE una BD existente (--force)."
fi

step "Restaurando '$BACKUP'"
# Detecta el formato automáticamente para servir tanto con dumps nuestros
# (pg_dump -Fc) como con los que genera EasyPanel u otros (SQL plano .sql/.sql.gz).
# pg_restore/psql pueden emitir avisos no fatales (roles/extensiones); no abortamos.
set +e
case "$BACKUP" in
  *.sql.gz|*.sql.gzip|*.gz)
    info "Formato: SQL plano comprimido (gzip) -> gunzip | psql"
    docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
      -e PGPASSWORD="$pass" -e PGCONNECT_TIMEOUT=15 -v "$WORK_DIR:/work" "$PG_IMAGE" \
      bash -c "gunzip -c /work/$BACKUP | psql -h $host -p $port -U $user -d \"$db\" -v ON_ERROR_STOP=0"
    rc=$?
    ;;
  *.sql)
    info "Formato: SQL plano -> psql"
    pgtool "$host" "$port" "$user" "$pass" psql -d "$db" -v ON_ERROR_STOP=0 -f "/work/$BACKUP"
    rc=$?
    ;;
  *)
    info "Formato: dump custom/directorio -> pg_restore -j $JOBS_N"
    pgtool "$host" "$port" "$user" "$pass" pg_restore -d "$db" \
      --no-owner --no-privileges -j "$JOBS_N" --verbose "/work/$BACKUP"
    rc=$?
    ;;
esac
set -e
if [ "$rc" -ne 0 ]; then
  warn "pg_restore terminó con código $rc (suele ser por extensiones/roles ya existentes). Verifica con 50-verify.sh."
else
  log "pg_restore completado sin errores."
fi

$KEEP || { rm -f "$WORK_DIR/$BACKUP" "$WORK_DIR/$BACKUP.sha256"; info "Limpieza local hecha."; }
log "RESTORE de '$SERVICE' completado. Ejecuta: bash scripts/50-verify.sh $SERVICE"
