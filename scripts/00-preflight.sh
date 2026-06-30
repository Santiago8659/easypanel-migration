#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh - Chequeos previos antes de migrar nada.
#
# Verifica: Docker, acceso a B2, conectividad a cada BD de origen/destino y
# compatibilidad de versiones (major del PG_IMAGE >= major del servidor origen).
#
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
  mark 1 "No se pudo listar el bucket B2. Revisa B2_* en .env y el endpoint/region."
fi

step "3) Conectividad a las BDs"
for svc in $DATABASES; do
  db=$(svc_dbname "$svc")
  # ORIGEN
  sh=$(svc_get "$svc" SRC HOST); sp=$(svc_get "$svc" SRC PORT); su=$(svc_get "$svc" SRC USER); sw=$(svc_get "$svc" SRC PASSWORD)
  if [ -n "$sh" ]; then
    if pgtool "$sh" "${sp:-5432}" "$su" "$sw" psql -d "$db" -tAc "select 1" >/dev/null 2>&1; then
      srvver=$(pgtool "$sh" "${sp:-5432}" "$su" "$sw" psql -d "$db" -tAc "show server_version_num" 2>/dev/null | tr -d '[:space:]')
      mark 0 "[$svc] ORIGEN $sh:${sp:-5432}/$db OK (server_version_num=$srvver)"
    else
      mark 1 "[$svc] ORIGEN $sh:${sp:-5432}/$db NO conecta."
    fi
  else
    warn "[$svc] sin SRC_PG_HOST configurado (se omite)."
  fi
  # DESTINO
  dh=$(svc_get "$svc" DST HOST); dp=$(svc_get "$svc" DST PORT); du=$(svc_get "$svc" DST USER); dw=$(svc_get "$svc" DST PASSWORD)
  if [ -n "$dh" ]; then
    if pgtool "$dh" "${dp:-5432}" "$du" "$dw" psql -d postgres -tAc "select 1" >/dev/null 2>&1; then
      mark 0 "[$svc] DESTINO $dh:${dp:-5432} OK"
    else
      mark 1 "[$svc] DESTINO $dh:${dp:-5432} NO conecta."
    fi
  else
    warn "[$svc] sin DST_PG_HOST configurado (se omite)."
  fi
done

step "4) Versión del cliente PG_IMAGE"
client_ver=$(docker run --rm "$PG_IMAGE" pg_dump --version | grep -oE '[0-9]+' | head -1)
info "PG_IMAGE=$PG_IMAGE -> pg_dump major $client_ver. Debe ser >= al major del servidor de ORIGEN."

echo
if [ "$fail" -eq 0 ]; then
  log "PREFLIGHT OK. Listo para migrar."
else
  die "PREFLIGHT con $fail problema(s). Resuélvelos antes de continuar."
fi
