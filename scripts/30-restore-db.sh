#!/usr/bin/env bash
# =============================================================================
# 30-restore-db.sh - Descarga un dump de B2 y lo restaura en el DESTINO
#
# Modo EXEC (recomendado): si hay <SVC>_DST_PG_CONTAINER, restaura con
# `docker exec` dentro del contenedor de la BD destino. Si no, conecta por red.
# Detecta el formato del backup (custom .dump / SQL .sql / .sql.gz).
#
# Uso:
#   bash scripts/30-restore-db.sh <servicio> [opciones]
# Opciones:
#   --backup <archivo>  Restaurar un dump específico (default: latest.txt en B2)
#   --recreate          DROP + CREATE de la BD destino antes de restaurar
#   --force             Restaurar sobre una BD existente sin recrearla
#   --keep              No borrar el dump descargado
#   --dry-run           Mostrar sin ejecutar
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

SERVICE="${1:-}"; [ -n "$SERVICE" ] || die "Uso: $0 <servicio> [--recreate] [--backup f] ..."
shift || true
BACKUP=""; RECREATE=false; FORCE=false; KEEP=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)   BACKUP="$2"; shift 2 ;;
    --recreate) RECREATE=true; shift ;;
    --force)    FORCE=true; shift ;;
    --keep)     KEEP=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

cont=$(svc_container "$SERVICE" DST)
host=$(svc_get "$SERVICE" DST HOST); port=$(svc_get "$SERVICE" DST PORT)
user=$(svc_get "$SERVICE" DST USER); pass=$(svc_get "$SERVICE" DST PASSWORD)
db=$(svc_dbname "$SERVICE"); port="${port:-5432}"; user="${user:-postgres}"
[ -n "$cont" ] || [ -n "$host" ] || die "Configura $(upper "$SERVICE")_DST_PG_CONTAINER (exec) o DST_PG_HOST (red)."

pg() { pg_target "$cont" "$host" "$port" "$user" "$pass" "$@"; }

step "Restore de '$SERVICE' (BD: $db)  [modo: ${cont:+exec $cont}${cont:-red $host:$port}]"

if [ -z "$BACKUP" ]; then
  info "Resolviendo backup más reciente (latest.txt)..."
  BACKUP=$(awscli s3 cp "$(s3_base)/$SERVICE/latest.txt" - 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$BACKUP" ] || die "No hay 'latest.txt' en B2 para '$SERVICE'. Usa --backup <archivo>."
fi
info "Backup a restaurar: $BACKUP"

if $DRY_RUN; then
  info "[DRY-RUN] descargar $(s3_base)/$SERVICE/$BACKUP y restaurar en $db (recreate=$RECREATE)"
  exit 0
fi

step "Descargando desde B2"
awscli s3 cp "$(s3_base)/$SERVICE/$BACKUP" "/work/$BACKUP"
if awscli s3 cp "$(s3_base)/$SERVICE/$BACKUP.sha256" "/work/$BACKUP.sha256" 2>/dev/null; then
  info "Verificando sha256..."
  sha256_check "$BACKUP" && log "Checksum OK." || die "Checksum NO coincide: descarga corrupta."
else
  warn "Sin checksum sidecar (dump en modo stream). Se omite verificación previa."
fi

step "Preparando BD destino"
exists=$(pg psql -d postgres -tAc "select 1 from pg_database where datname='$db'" | tr -d '[:space:]' || true)
if $RECREATE; then
  warn "Recreando BD '$db' (se eliminan datos actuales en destino)..."
  pg psql -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='$db' and pid<>pg_backend_pid()" >/dev/null || true
  pg psql -d postgres -c "DROP DATABASE IF EXISTS \"$db\""
  pg psql -d postgres -c "CREATE DATABASE \"$db\""
elif [ -z "$exists" ]; then
  info "Creando BD '$db' (no existía)..."
  pg psql -d postgres -c "CREATE DATABASE \"$db\""
else
  $FORCE || die "La BD '$db' ya existe en destino. Usa --recreate (reemplazar) o --force."
  warn "Restaurando SOBRE una BD existente (--force)."
fi

step "Restaurando '$BACKUP'"
# Se alimenta el dump por stdin (sirve igual en modo exec y red).
set +e
case "$BACKUP" in
  *.sql.gz|*.sql.gzip|*.gz)
    info "Formato: SQL plano comprimido (gzip) -> gunzip | psql"
    gunzip -c "$WORK_DIR/$BACKUP" | pg psql -d "$db" -v ON_ERROR_STOP=0
    rc=$?
    ;;
  *.sql)
    info "Formato: SQL plano -> psql"
    pg psql -d "$db" -v ON_ERROR_STOP=0 < "$WORK_DIR/$BACKUP"
    rc=$?
    ;;
  *)
    info "Formato: dump custom -> pg_restore"
    pg pg_restore -d "$db" --no-owner --no-privileges --verbose < "$WORK_DIR/$BACKUP"
    rc=$?
    ;;
esac
set -e
if [ "$rc" -ne 0 ]; then
  warn "La restauración terminó con código $rc (suele ser por extensiones/roles ya existentes). Verifica con 50-verify.sh."
else
  log "Restauración completada sin errores."
fi

$KEEP || { rm -f "$WORK_DIR/$BACKUP" "$WORK_DIR/$BACKUP.sha256"; info "Limpieza local hecha."; }
log "RESTORE de '$SERVICE' completado. Ejecuta: bash scripts/50-verify.sh $SERVICE"
