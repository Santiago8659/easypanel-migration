#!/usr/bin/env bash
# =============================================================================
# 40-restore-storage.sh - Descarga el storage de Chatwoot de B2 y lo extrae
#
# Uso:
#   bash scripts/40-restore-storage.sh --path /ruta/destino [--backup f] [--dry-run]
#
# Si no se pasa --path usa CHATWOOT_STORAGE_PATH del .env (en el server DESTINO).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

DST_PATH="${CHATWOOT_STORAGE_PATH:-}"
BACKUP=""; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   DST_PATH="$2"; shift 2 ;;
    --backup) BACKUP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[ -n "$DST_PATH" ] || die "Falta la ruta destino (CHATWOOT_STORAGE_PATH o --path)."
mkdir -p "$DST_PATH"

if [ -z "$BACKUP" ]; then
  BACKUP=$(awscli s3 cp "$(s3_base)/chatwoot/storage/latest.txt" - 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$BACKUP" ] || die "No hay storage en B2. Corre 20-dump-storage.sh primero o usa --backup."
fi

step "Restaurando storage '$BACKUP' en $DST_PATH"
if $DRY_RUN; then
  info "[DRY-RUN] descargar $(s3_base)/chatwoot/storage/$BACKUP y extraer en $DST_PATH"
  exit 0
fi

awscli s3 cp "$(s3_base)/chatwoot/storage/$BACKUP" "/work/$BACKUP"
if awscli s3 cp "$(s3_base)/chatwoot/storage/$BACKUP.sha256" "/work/$BACKUP.sha256" 2>/dev/null; then
  sha256_check "$BACKUP" && log "Checksum OK." || die "Checksum NO coincide."
fi

tar xzf "$WORK_DIR/$BACKUP" -C "$DST_PATH"
rm -f "$WORK_DIR/$BACKUP" "$WORK_DIR/$BACKUP.sha256"
log "Storage restaurado en $DST_PATH"
warn "Ajusta permisos/owner si el contenedor de Chatwoot corre con un UID específico."
