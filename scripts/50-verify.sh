#!/usr/bin/env bash
# =============================================================================
# 50-verify.sh - Verifica la migración comparando conteos de filas por tabla
#                entre ORIGEN y DESTINO para un servicio.
#
# Soporta modo exec (contenedor) y modo red, igual que dump/restore.
# Sale 0 si todas las tablas cuadran; 1 si hay diferencias.
#
# Uso: bash scripts/50-verify.sh <servicio>
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

SERVICE="${1:-}"; [ -n "$SERVICE" ] || die "Uso: $0 <servicio>"
db=$(svc_dbname "$SERVICE")

s_cont=$(svc_container "$SERVICE" SRC)
s_host=$(svc_get "$SERVICE" SRC HOST); s_port=$(svc_get "$SERVICE" SRC PORT)
s_user=$(svc_get "$SERVICE" SRC USER); s_pass=$(svc_get "$SERVICE" SRC PASSWORD)
d_cont=$(svc_container "$SERVICE" DST)
d_host=$(svc_get "$SERVICE" DST HOST); d_port=$(svc_get "$SERVICE" DST PORT)
d_user=$(svc_get "$SERVICE" DST USER); d_pass=$(svc_get "$SERVICE" DST PASSWORD)
s_port="${s_port:-5432}"; d_port="${d_port:-5432}"; s_user="${s_user:-postgres}"; d_user="${d_user:-postgres}"
{ [ -n "$s_cont" ] || [ -n "$s_host" ]; } && { [ -n "$d_cont" ] || [ -n "$d_host" ]; } \
  || die "Faltan datos de origen y/o destino en .env (contenedor o host)."

src_pg() { pg_target "$s_cont" "$s_host" "$s_port" "$s_user" "$s_pass" "$@"; }
dst_pg() { pg_target "$d_cont" "$d_host" "$d_port" "$d_user" "$d_pass" "$@"; }

# Una sola query devuelve 'esquema.tabla|conteo' de todas las tablas de usuario.
COUNT_SQL="
SELECT string_agg(
  format('SELECT %L AS t, count(*) AS c FROM %I.%I', n.nspname||'.'||c.relname, n.nspname, c.relname),
  ' UNION ALL '
)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema');
"

counts_src() {
  local q; q=$(src_pg psql -d "$db" -tAc "$COUNT_SQL")
  [ -n "$q" ] || { echo ""; return 0; }
  src_pg psql -d "$db" -F '|' -tA -c "$q" | sort
}
counts_dst() {
  local q; q=$(dst_pg psql -d "$db" -tAc "$COUNT_SQL")
  [ -n "$q" ] || { echo ""; return 0; }
  dst_pg psql -d "$db" -F '|' -tA -c "$q" | sort
}

step "Verificando '$SERVICE' (BD: $db)"
info "Contando filas en ORIGEN..."
src_counts=$(counts_src)
info "Contando filas en DESTINO..."
dst_counts=$(counts_dst)

src_tmp="$WORK_DIR/.verify-src.$$"; dst_tmp="$WORK_DIR/.verify-dst.$$"
printf '%s\n' "$src_counts" > "$src_tmp"
printf '%s\n' "$dst_counts" > "$dst_tmp"

mismatch=0
echo
printf "%-45s %12s %12s   %s\n" "TABLA" "ORIGEN" "DESTINO" "ESTADO"
printf -- "%.0s-" {1..85}; echo
all_tables=$(cut -d'|' -f1 "$src_tmp" "$dst_tmp" | sort -u | sed '/^$/d')
while IFS= read -r t; do
  [ -z "$t" ] && continue
  sc=$(grep -F "$t|" "$src_tmp" | head -1 | cut -d'|' -f2); sc="${sc:-—}"
  dc=$(grep -F "$t|" "$dst_tmp" | head -1 | cut -d'|' -f2); dc="${dc:-—}"
  if [ "$sc" = "$dc" ]; then estado="${GREEN}OK${NC}"; else estado="${RED}DIFIERE${NC}"; mismatch=$((mismatch+1)); fi
  printf "%-45s %12s %12s   %b\n" "$t" "$sc" "$dc" "$estado"
done <<< "$all_tables"

rm -f "$src_tmp" "$dst_tmp"
echo
if [ "$mismatch" -eq 0 ]; then
  log "VERIFICACIÓN OK: todas las tablas cuadran entre origen y destino."
  exit 0
else
  die "VERIFICACIÓN FALLIDA: $mismatch tabla(s) con diferencias."
fi
