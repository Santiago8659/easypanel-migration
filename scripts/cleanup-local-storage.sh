#!/usr/bin/env bash
# =============================================================================
# cleanup-local-storage.sh - Borra los adjuntos locales de Chatwoot SOLO tras
# verificar que todo está en B2 y que la BD ya no apunta a 'local'.
#
# COMPUERTAS (si una falla, NO borra nada):
#   1. La BD no debe tener ningún blob con service_name='local'
#      (si los hay, aún se leen del disco: borrar los rompería).
#   2. rclone check: coteja TODOS los archivos locales (tamaño+hash) contra el
#      bucket. Un solo archivo faltante/distinto -> aborta.
#   3. Confirmación explícita escribiendo BORRAR.
#
# Uso:
#   bash scripts/cleanup-local-storage.sh            # compuertas + borrado
#   bash scripts/cleanup-local-storage.sh --check    # solo verificar (no borra)
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

: "${STORAGE_BUCKET_NAME:?Falta STORAGE_BUCKET_NAME en .env}"
: "${STORAGE_ACCESS_KEY_ID:?Falta STORAGE_ACCESS_KEY_ID en .env}"
: "${STORAGE_SECRET_ACCESS_KEY:?Falta STORAGE_SECRET_ACCESS_KEY en .env}"
: "${STORAGE_ENDPOINT:?Falta STORAGE_ENDPOINT en .env}"
SRC="${CHATWOOT_STORAGE_PATH:?Falta CHATWOOT_STORAGE_PATH en .env}"
[ -d "$SRC" ] || die "No existe: $SRC"

CHECK_ONLY=false; [ "${1:-}" = "--check" ] && CHECK_ONLY=true
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"
FLAT="${FLAT_DIR:-/tmp/cw-flat-check}"

SERVICE="chatwoot"
cont=$(svc_container "$SERVICE" SRC)
host=$(svc_get "$SERVICE" SRC HOST); port=$(svc_get "$SERVICE" SRC PORT)
user=$(svc_get "$SERVICE" SRC USER); pass=$(svc_get "$SERVICE" SRC PASSWORD)
db=$(svc_dbname "$SERVICE"); port="${port:-5432}"; user="${user:-postgres}"
[ -n "$cont" ] || [ -n "$host" ] || die "Falta contenedor/host de la BD en .env"
pg() { pg_target "$cont" "$host" "$port" "$user" "$pass" "$@" </dev/null; }

step "COMPUERTA 1/3: la BD no debe tener blobs 'local'"
nlocal=$(pg psql -d "$db" -tAc "SELECT count(*) FROM active_storage_blobs WHERE service_name='local';" | tr -d '[:space:]')
if [ "$nlocal" != "0" ]; then
  die "Hay $nlocal blobs con service_name='local' (aún se leen del disco). Corre antes mark-blobs-service.sh. NO se borró nada."
fi
log "BD OK: 0 blobs en 'local'."

step "COMPUERTA 2/3: cotejo COMPLETO local vs B2 (rclone check, tamaño+hash)"
rm -rf "$FLAT"; mkdir -p "$FLAT"
if ! find "$SRC" -mindepth 3 -maxdepth 3 -type f -exec ln -t "$FLAT" {} + 2>/dev/null; then
  find "$SRC" -mindepth 3 -maxdepth 3 -type f -exec sh -c \
    'for f; do ln "$f" "'"$FLAT"'/$(basename "$f")" 2>/dev/null || cp "$f" "'"$FLAT"'/"; done' _ {} +
fi
nflat=$(find "$FLAT" -maxdepth 1 -type f | wc -l | tr -d ' ')
info "Cotejando $nflat archivos contra s3:$STORAGE_BUCKET_NAME ..."
set +e
docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} -v "$FLAT:/data:ro" "$RCLONE_IMAGE" \
  check /data ":s3:$STORAGE_BUCKET_NAME" --one-way \
  --s3-provider=Other \
  --s3-access-key-id="$STORAGE_ACCESS_KEY_ID" \
  --s3-secret-access-key="$STORAGE_SECRET_ACCESS_KEY" \
  --s3-endpoint="$STORAGE_ENDPOINT" \
  --s3-region="${STORAGE_REGION:-us-east-005}" \
  --s3-force-path-style=true \
  --checkers=16 2>&1 | tail -8
rc=${PIPESTATUS[0]}
set -e
rm -rf "$FLAT"
if [ "$rc" -ne 0 ]; then
  die "rclone check encontró diferencias (archivos faltantes o distintos en B2). Re-ejecuta migrate-storage-to-b2.sh y reintenta. NO se borró nada."
fi
log "Cotejo COMPLETO OK: los $nflat archivos locales están íntegros en B2."

if $CHECK_ONLY; then
  log "--check: verificación completa. No se borró nada."
  exit 0
fi

step "COMPUERTA 3/3: confirmación"
total=$(du -sh "$SRC" 2>/dev/null | cut -f1)
warn "Se borrará TODO el contenido de: $SRC  ($total)"
warn "Esto es IRREVERSIBLE. Los adjuntos quedan únicamente en B2 (ya cotejados)."
warn "Recomendado: haber validado la app leyendo desde B2 unos días antes de esto."
read -rp "Confirma escribiendo BORRAR en mayúsculas: " c
[ "$c" = "BORRAR" ] || die "Cancelado. No se borró nada."

step "Borrando adjuntos locales..."
find "$SRC" -mindepth 1 -delete
log "Liberado: $total. Disco:"
df -h / | tail -1
