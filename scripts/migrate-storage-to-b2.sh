#!/usr/bin/env bash
# =============================================================================
# migrate-storage-to-b2.sh - Sube los adjuntos locales de Chatwoot (Active
# Storage, layout xx/yy/<key>) a un bucket B2 con la estructura PLANA que el
# servicio S3 de Active Storage espera (objeto S3 = key del blob = basename).
#
# Verificado contra el código fuente:
#  - Rails DiskService:  path = root/xx/yy/<key>  (basename == key)
#  - Rails S3Service:    objeto = key, sin prefijos ni transformación
#  - Chatwoot v4.7.0 storage.yml: servicio 's3_compatible' con STORAGE_*
#
# IMPORTANTE: solo se suben archivos a PROFUNDIDAD EXACTA 3 (xx/yy/key), que
# son los blobs reales. Archivos más profundos (p.ej. variants legacy
# 'va/ri/variants/<key>/<hash>') se EXCLUYEN a propósito: su basename no es su
# key y subirlos mal rompería; Rails los regenera solo cuando hagan falta.
#
# NO toca la BD. Eso se hace aparte con mark-blobs-service.sh, que además
# verifica una muestra de keys reales contra B2 antes de permitir el UPDATE.
#
# Lee del .env: CHATWOOT_STORAGE_PATH + STORAGE_* (bucket de media)
# Uso:
#   bash scripts/migrate-storage-to-b2.sh [--dry-run]
# Idempotente: rclone salta lo ya subido; re-ejecutar reanuda.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

: "${STORAGE_BUCKET_NAME:?Falta STORAGE_BUCKET_NAME en .env}"
: "${STORAGE_ACCESS_KEY_ID:?Falta STORAGE_ACCESS_KEY_ID en .env}"
: "${STORAGE_SECRET_ACCESS_KEY:?Falta STORAGE_SECRET_ACCESS_KEY en .env}"
: "${STORAGE_ENDPOINT:?Falta STORAGE_ENDPOINT en .env}"
STORAGE_REGION="${STORAGE_REGION:-us-east-005}"
SRC="${CHATWOOT_STORAGE_PATH:?Falta CHATWOOT_STORAGE_PATH en .env}"
[ -d "$SRC" ] || die "No existe la carpeta de storage: $SRC"

RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"
# El índice plano vive JUNTO a los datos (mismo filesystem): así los hardlinks
# funcionan siempre y NUNCA se copian datos. Jamás usar /tmp (puede ser tmpfs
# u otro fs, y un fallback a copia llenaría el disco).
FLAT="${FLAT_DIR:-$(dirname "$SRC")/.cw-flat-index}"
DRY_RUN=false; [ "${1:-}" = "--dry-run" ] && DRY_RUN=true

rclone_s3() {
  docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
    -v "$FLAT:/data:ro" "$RCLONE_IMAGE" "$@" \
    --s3-provider=Other \
    --s3-access-key-id="$STORAGE_ACCESS_KEY_ID" \
    --s3-secret-access-key="$STORAGE_SECRET_ACCESS_KEY" \
    --s3-endpoint="$STORAGE_ENDPOINT" \
    --s3-region="$STORAGE_REGION" \
    --s3-force-path-style=true
}

step "Adjuntos locales: $SRC  ->  B2 bucket: $STORAGE_BUCKET_NAME"
n_blobs=$(find "$SRC" -mindepth 3 -maxdepth 3 -type f | wc -l | tr -d ' ')
n_deep=$(find "$SRC" -mindepth 4 -type f 2>/dev/null | wc -l | tr -d ' ')
n_shallow=$(find "$SRC" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
info "Blobs (profundidad 3, se suben):        $n_blobs"
info "Variants legacy (>3, se EXCLUYEN):      $n_deep  (Rails los regenera solo)"
[ "$n_shallow" != "0" ] && warn "Archivos sueltos a profundidad <3: $n_shallow (se excluyen; revisa qué son)"
[ "$n_blobs" != "0" ] || die "No se encontraron blobs a profundidad 3. ¿Es la ruta correcta?"

if $DRY_RUN; then
  info "[DRY-RUN] aplanaría $n_blobs archivos (hardlinks) y correría: rclone copy /data :s3:$STORAGE_BUCKET_NAME"
  exit 0
fi

step "1/3 Creando índice plano (hardlinks; NO duplica datos en disco)"
rm -rf "$FLAT"; mkdir -p "$FLAT"
# Sanity: el hardlink debe funcionar (mismo filesystem). Si no, ABORTAR:
# jamás copiar (duplicaría 148G y llenaría el disco).
probe=$(find "$SRC" -mindepth 3 -maxdepth 3 -type f | head -1)
[ -n "$probe" ] || die "No se encontró ningún blob para probar."
ln "$probe" "$FLAT/.probe" 2>/dev/null \
  || die "Hardlink imposible entre $SRC y $FLAT (¿filesystems distintos?). NO se copia nada. Ajusta FLAT_DIR a una ruta del MISMO filesystem que los datos y reintenta."
rm -f "$FLAT/.probe"
# ln por lotes; los errores no se ocultan. Nunca se copia.
find "$SRC" -mindepth 3 -maxdepth 3 -type f -exec ln -t "$FLAT" {} + 2>"$FLAT/.ln-errors" || true
if [ -s "$FLAT/.ln-errors" ]; then
  warn "Algunos hardlinks fallaron ($(wc -l < "$FLAT/.ln-errors") errores). Primeras líneas:"
  head -3 "$FLAT/.ln-errors" >&2
fi
rm -f "$FLAT/.ln-errors"
nflat=$(find "$FLAT" -maxdepth 1 -type f | wc -l | tr -d ' ')
info "Índice plano listo: $nflat archivos (hardlinks, 0 bytes duplicados)"
[ "$nflat" -gt 0 ] || die "El índice plano quedó vacío. Abortando."
[ "$nflat" = "$n_blobs" ] || warn "Índice ($nflat) != blobs locales ($n_blobs). Si difiere mucho, detente y avísame."

step "2/3 Subiendo a B2 con rclone (paralelo, reanudable)"
warn "Puede tardar horas (148 GB). Corre esto dentro de screen/nohup."
rclone_s3 copy /data ":s3:$STORAGE_BUCKET_NAME" \
  --transfers=8 --checkers=8 --stats=30s --stats-one-line --retries=5

step "3/3 Verificando conteo en B2"
remote=$(rclone_s3 size ":s3:$STORAGE_BUCKET_NAME" 2>/dev/null | grep -oE 'Total objects: *[0-9.]+[kM]?' | grep -oE '[0-9.]+[kM]?' || echo "?")
info "Objetos en B2: $remote   |   índice local: $nflat"
rm -rf "$FLAT"
log "Subida terminada (rclone verificó tamaño/checksum por archivo al copiar)."
info "Siguiente paso: bash scripts/mark-blobs-service.sh  (verifica muestra real contra B2 antes del UPDATE)"
info "NO borres los archivos locales todavía."
