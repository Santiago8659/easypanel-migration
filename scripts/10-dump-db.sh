#!/usr/bin/env bash
# =============================================================================
# 10-dump-db.sh - Dump de una BD de ORIGEN y subida a B2
#
# Funciona en dos modos (se elige solo según el .env):
#   - EXEC (recomendado EasyPanel/Swarm): si hay <SVC>_SRC_PG_CONTAINER, entra
#     al contenedor de la BD con `docker exec` y usa su propio pg_dump (versión
#     correcta, p.ej. pg17/pgvector).
#   - RED: si no, conecta por red con PG_IMAGE a <host>:<port>.
#
# Uso:
#   bash scripts/10-dump-db.sh <servicio> [opciones]
# Opciones:
#   --stream      pg_dump -> B2 sin escribir a disco local (servidor flojo).
#   --keep        No borrar el dump local tras subir (modo archivo).
#   --dry-run     Mostrar sin ejecutar.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

SERVICE="${1:-}"; [ -n "$SERVICE" ] || die "Uso: $0 <servicio> [--stream] [--keep] [--dry-run]"
shift || true
STREAM=false; KEEP=false; DRY_RUN=false
for a in "$@"; do
  case "$a" in
    --stream) STREAM=true ;;
    --keep)   KEEP=true ;;
    --dry-run) DRY_RUN=true ;;
    *) die "Opción desconocida: $a" ;;
  esac
done

cont=$(svc_container "$SERVICE" SRC)
host=$(svc_get "$SERVICE" SRC HOST); port=$(svc_get "$SERVICE" SRC PORT)
user=$(svc_get "$SERVICE" SRC USER); pass=$(svc_get "$SERVICE" SRC PASSWORD)
db=$(svc_dbname "$SERVICE"); port="${port:-5432}"; user="${user:-postgres}"
[ -n "$cont" ] || [ -n "$host" ] || die "Configura $(upper "$SERVICE")_SRC_PG_CONTAINER (modo exec) o SRC_PG_HOST (modo red)."

pg() { pg_target "$cont" "$host" "$port" "$user" "$pass" "$@"; }

ts=$(date '+%Y%m%d-%H%M%S')
file="${SERVICE}-${ts}.dump"

step "Dump de '$db' (servicio: $SERVICE)  [modo: ${cont:+exec $cont}${cont:-red $host:$port}]"

info "Comprobando conexión..."
pg psql -d "$db" -tAc "select 1" >/dev/null || die "No conecta a la BD '$db'. Revisa credenciales/contenedor."
size=$(pg psql -d "$db" -tAc "select pg_size_pretty(pg_database_size('$db'))" 2>/dev/null | tr -d '[:space:]' || echo "?")
info "Tamaño de la BD: ${size}"

if $DRY_RUN; then
  info "[DRY-RUN] pg_dump -Fc -d $db  ->  $(s3_base)/$SERVICE/$file"
  exit 0
fi

upload_latest() {
  echo "$file" > "$WORK_DIR/latest.txt"
  awscli s3 cp "/work/latest.txt" "$(s3_base)/$SERVICE/latest.txt" >/dev/null
  rm -f "$WORK_DIR/latest.txt"
}

if $STREAM; then
  step "Streaming pg_dump -> B2 (sin disco local)"
  pg pg_dump -d "$db" -Fc --no-owner --no-privileges \
    | awscli s3 cp - "$(s3_base)/$SERVICE/$file"
  upload_latest
  log "Dump (stream) subido: $(s3_base)/$SERVICE/$file"
  warn "Modo stream no genera checksum sidecar; la integridad la valida pg_restore al restaurar."
else
  info "Generando dump local (formato custom comprimido)..."
  pg pg_dump -d "$db" -Fc --no-owner --no-privileges > "$WORK_DIR/$file"
  log "Dump local: $WORK_DIR/$file ($(du -h "$WORK_DIR/$file" | cut -f1))"

  info "Calculando sha256..."
  sha256_make "$file"

  step "Subiendo a B2"
  awscli s3 cp "/work/$file" "$(s3_base)/$SERVICE/$file"
  awscli s3 cp "/work/$file.sha256" "$(s3_base)/$SERVICE/$file.sha256"
  upload_latest
  log "Subido: $(s3_base)/$SERVICE/$file"

  if ! $KEEP; then
    rm -f "$WORK_DIR/$file" "$WORK_DIR/$file.sha256"
    info "Limpieza local hecha (usa --keep para conservar el dump)."
  fi
fi

log "DUMP de '$SERVICE' completado."
