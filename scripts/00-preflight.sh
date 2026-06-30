#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh - Chequeos previos antes de migrar nada.
#   Docker, acceso a B2, conectividad a cada BD (modo exec o red).
# Uso: bash scripts/00-preflight.sh
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

fail=0
mark() { if [ "$1" = "0" ]; then log "$2"; else warn "$2"; fail=$((fail+1)); fi; }

step "1) Docker"
log "Docker disponible y daemon activo."

step "2) Acceso a B2 (bucket: ${B2_BUCKET:-?})"
if awscli s3 ls "s3://${B2_BUCKET}/" >/dev/null 2>&1; then
  mark 0 "B2 accesible: $(s3_base)"
else
  mark 1 "No se pudo listar el bucket B2. Revisa B2_* en .env (endpoint/region/keys)."
fi

step "3) Conectividad a las BDs"
for svc in $DATABASES; do
  db=$(svc_dbname "$svc")
  # ORIGEN
  sc=$(svc_container "$svc" SRC); sh=$(svc_get "$svc" SRC HOST); sp=$(svc_get "$svc" SRC PORT)
  su=$(svc_get "$svc" SRC USER); sw=$(svc_get "$svc" SRC PASSWORD); sp="${sp:-5432}"; su="${su:-postgres}"
  if [ -n "$sc" ] || [ -n "$sh" ]; then
    if pg_target "$sc" "$sh" "$sp" "$su" "$sw" psql -d "$db" -tAc "select 1" >/dev/null 2>&1; then
      v=$(pg_target "$sc" "$sh" "$sp" "$su" "$sw" psql -d "$db" -tAc "show server_version" 2>/dev/null | tr -d '[:space:]')
      mark 0 "[$svc] ORIGEN ${sc:+exec $sc}${sc:-$sh:$sp}/$db OK (server $v)"
    else
      mark 1 "[$svc] ORIGEN ${sc:+exec $sc}${sc:-$sh:$sp}/$db NO conecta."
    fi
  else
    warn "[$svc] sin contenedor/host de ORIGEN (se omite)."
  fi
  # DESTINO
  dc=$(svc_container "$svc" DST); dh=$(svc_get "$svc" DST HOST); dp=$(svc_get "$svc" DST PORT)
  du=$(svc_get "$svc" DST USER); dw=$(svc_get "$svc" DST PASSWORD); dp="${dp:-5432}"; du="${du:-postgres}"
  if [ -n "$dc" ] || [ -n "$dh" ]; then
    if pg_target "$dc" "$dh" "$dp" "$du" "$dw" psql -d postgres -tAc "select 1" >/dev/null 2>&1; then
      mark 0 "[$svc] DESTINO ${dc:+exec $dc}${dc:-$dh:$dp} OK"
    else
      mark 1 "[$svc] DESTINO ${dc:+exec $dc}${dc:-$dh:$dp} NO conecta."
    fi
  else
    warn "[$svc] sin contenedor/host de DESTINO (se omite; normal si aún no lo creas)."
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  log "PREFLIGHT OK."
else
  warn "PREFLIGHT con $fail aviso(s). Revisa lo marcado antes de continuar."
  exit 1
fi
