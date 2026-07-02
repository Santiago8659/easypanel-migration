#!/usr/bin/env bash
# =============================================================================
# 20-dump-storage.sh - Empaqueta el storage local de Chatwoot y lo sube a B2
#
# Chatwoot (Active Storage local) guarda adjuntos en un volumen del host.
# Esto los empaqueta (tar.gz) y sube a B2. A futuro se puede mover a S3/B2
# nativo (ver docs/STORAGE.md) y este paso deja de ser necesario.
#
# Uso:
#   bash scripts/20-dump-storage.sh [--path /ruta/al/storage] [--dry-run]
#
# Si no se pasa --path usa CHATWOOT_STORAGE_PATH del .env.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

SRC_PATH="${CHATWOOT_STORAGE_PATH:-}"
DRY_RUN=false; STREAM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) SRC_PATH="$2"; shift 2 ;;
    --stream) STREAM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[ -n "$SRC_PATH" ] || die "Falta la ruta del storage (CHATWOOT_STORAGE_PATH o --path)."
[ -d "$SRC_PATH" ] || die "La ruta '$SRC_PATH' no existe o no es un directorio."

ts=$(date '+%Y%m%d-%H%M%S')
file="chatwoot-storage-${ts}.tar.gz"

step "Empaquetando storage de Chatwoot: $SRC_PATH"
if $DRY_RUN; then
  info "[DRY-RUN] tar czf ... -C $SRC_PATH .  ->  $(s3_base)/chatwoot/storage/$file  (stream=$STREAM)"
  exit 0
fi

upload_latest() {
  echo "$file" > "$WORK_DIR/latest.txt"
  awscli s3 cp "/work/latest.txt" "$(s3_base)/chatwoot/storage/latest.txt" >/dev/null
  rm -f "$WORK_DIR/latest.txt"
}

if $STREAM; then
  # tar directo a B2, SIN escribir a disco (ideal con disco lleno).
  step "Streaming tar -> B2 (sin disco local)"
  tar czf - -C "$SRC_PATH" . | awscli s3 cp - "$(s3_base)/chatwoot/storage/$file"
  upload_latest
  log "Storage (stream) subido: $(s3_base)/chatwoot/storage/$file"
  warn "Modo stream no genera checksum sidecar."
else
  tar czf "$WORK_DIR/$file" -C "$SRC_PATH" .
  log "Empaquetado: $WORK_DIR/$file ($(du -h "$WORK_DIR/$file" | cut -f1))"
  sha256_make "$file"
  step "Subiendo a B2"
  awscli s3 cp "/work/$file" "$(s3_base)/chatwoot/storage/$file"
  awscli s3 cp "/work/$file.sha256" "$(s3_base)/chatwoot/storage/$file.sha256"
  upload_latest
  rm -f "$WORK_DIR/$file" "$WORK_DIR/$file.sha256"
  log "Storage subido: $(s3_base)/chatwoot/storage/$file"
fi
