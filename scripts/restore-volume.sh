#!/usr/bin/env bash
# =============================================================================
# restore-volume.sh - Descarga un volumen de B2 y lo extrae en una ruta destino.
#
# Uso:
#   bash scripts/restore-volume.sh <nombre> --path <ruta-destino> [--backup f] [--dry-run]
#
# Ejemplo n8n (en server nuevo, con el servicio n8n PARADO):
#   bash scripts/restore-volume.sh n8n --path /var/lib/docker/volumes/automate_n8n_data/_data
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

NAME="${1:-}"; [ -n "$NAME" ] || die "Uso: $0 <nombre> --path <ruta-destino> [--backup f]"
shift || true
DST_PATH=""; BACKUP=""; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   DST_PATH="$2"; shift 2 ;;
    --backup) BACKUP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done
[ -n "$DST_PATH" ] || die "Falta --path <ruta-destino>."
mkdir -p "$DST_PATH"

if [ -z "$BACKUP" ]; then
  BACKUP=$(awscli s3 cp "$(s3_base)/volumes/$NAME/latest.txt" - 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$BACKUP" ] || die "No hay backups del volumen '$NAME' en B2. Corre dump-volume.sh primero o usa --backup."
fi

step "Restaurando volumen '$NAME' ($BACKUP) en $DST_PATH"
if $DRY_RUN; then
  info "[DRY-RUN] descargar $(s3_base)/volumes/$NAME/$BACKUP y extraer en $DST_PATH"
  exit 0
fi

awscli s3 cp "$(s3_base)/volumes/$NAME/$BACKUP" "/work/$BACKUP"
if awscli s3 cp "$(s3_base)/volumes/$NAME/$BACKUP.sha256" "/work/$BACKUP.sha256" 2>/dev/null; then
  sha256_check "$BACKUP" && log "Checksum OK." || die "Checksum NO coincide."
fi

tar xzf "$WORK_DIR/$BACKUP" -C "$DST_PATH"
rm -f "$WORK_DIR/$BACKUP" "$WORK_DIR/$BACKUP.sha256"
log "Volumen '$NAME' restaurado en $DST_PATH"
warn "Ajusta owner/permisos si el contenedor corre con un UID específico (ej. n8n usa uid 1000 'node')."
