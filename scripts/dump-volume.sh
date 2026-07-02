#!/usr/bin/env bash
# =============================================================================
# dump-volume.sh - Empaqueta un volumen/carpeta del host y lo sube a B2.
#
# Genérico: sirve para n8n (automate_n8n_data) o cualquier volumen Docker.
# El backup queda en B2 bajo:  <prefix>/volumes/<nombre>/
#
# Uso:
#   bash scripts/dump-volume.sh <nombre> --path <ruta-en-host> [--dry-run]
#
# Ejemplo n8n:
#   bash scripts/dump-volume.sh n8n --path /var/lib/docker/volumes/automate_n8n_data/_data
#
# ⚠️ Para consistencia (ej. SQLite de n8n), idealmente PARA el servicio antes de
#    copiar su volumen, y vuélvelo a levantar después.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

NAME="${1:-}"; [ -n "$NAME" ] || die "Uso: $0 <nombre> --path <ruta> [--dry-run]"
shift || true
SRC_PATH=""; DRY_RUN=false; STREAM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) SRC_PATH="$2"; shift 2 ;;
    --stream) STREAM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done
[ -n "$SRC_PATH" ] || die "Falta --path <ruta-en-host>."
[ -d "$SRC_PATH" ] || die "La ruta '$SRC_PATH' no existe o no es un directorio."

ts=$(date '+%Y%m%d-%H%M%S')
file="${NAME}-${ts}.tar.gz"

step "Empaquetando volumen '$NAME': $SRC_PATH"
if $DRY_RUN; then
  info "[DRY-RUN] tar -C $SRC_PATH .  ->  $(s3_base)/volumes/$NAME/$file  (stream=$STREAM)"
  exit 0
fi

upload_latest() {
  echo "$file" > "$WORK_DIR/latest.txt"
  awscli s3 cp "/work/latest.txt" "$(s3_base)/volumes/$NAME/latest.txt" >/dev/null
  rm -f "$WORK_DIR/latest.txt"
}

if $STREAM; then
  step "Streaming tar -> B2 (sin disco local)"
  tar czf - -C "$SRC_PATH" . | awscli s3 cp - "$(s3_base)/volumes/$NAME/$file"
  upload_latest
  log "Volumen '$NAME' (stream) subido: $(s3_base)/volumes/$NAME/$file"
  warn "Modo stream no genera checksum sidecar."
else
  tar czf "$WORK_DIR/$file" -C "$SRC_PATH" .
  log "Empaquetado: $WORK_DIR/$file ($(du -h "$WORK_DIR/$file" | cut -f1))"
  sha256_make "$file"
  step "Subiendo a B2"
  awscli s3 cp "/work/$file" "$(s3_base)/volumes/$NAME/$file"
  awscli s3 cp "/work/$file.sha256" "$(s3_base)/volumes/$NAME/$file.sha256"
  upload_latest
  rm -f "$WORK_DIR/$file" "$WORK_DIR/$file.sha256"
  log "Volumen '$NAME' subido: $(s3_base)/volumes/$NAME/$file"
fi
