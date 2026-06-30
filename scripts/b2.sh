#!/usr/bin/env bash
# =============================================================================
# b2.sh - Utilidades sobre el bucket B2.
#
# Uso:
#   bash scripts/b2.sh ls [servicio]     # listar backups (de un servicio o de todo)
#   bash scripts/b2.sh latest <servicio> # mostrar el backup 'latest'
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

cmd="${1:-ls}"; svc="${2:-}"
case "$cmd" in
  ls)
    if [ -n "$svc" ]; then
      step "Backups de '$svc' en B2"
      awscli s3 ls --recursive "$(s3_base)/$svc/"
    else
      step "Contenido de $(s3_base)"
      awscli s3 ls --recursive "$(s3_base)/"
    fi
    ;;
  latest)
    [ -n "$svc" ] || die "Uso: $0 latest <servicio>"
    awscli s3 cp "$(s3_base)/$svc/latest.txt" - 2>/dev/null | tr -d '[:space:]'
    echo
    ;;
  *) die "Comando desconocido: $cmd (usa: ls | latest)" ;;
esac
