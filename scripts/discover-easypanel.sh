#!/usr/bin/env bash
# =============================================================================
# discover-easypanel.sh - Descubre datos de conexión en un host EasyPanel.
#
# SOLO LECTURA: usa `docker ps/inspect`. No modifica nada.
# Ejecútalo POR SSH en el servidor (origen o destino):
#   bash discover-easypanel.sh
#
# Imprime, para cada Postgres encontrado: nombre, red, credenciales y puerto;
# y para apps tipo Chatwoot/n8n: sus claves de cifrado y volúmenes de storage.
# Copia los valores sugeridos a tu .env.
# =============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
h() { echo; echo "${BOLD}== $* ==${NC}"; }

command -v docker >/dev/null 2>&1 || { echo "Docker no disponible en este host."; exit 1; }

ins_env()  { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null; }
ins_nets() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$1" 2>/dev/null | sed '/^$/d'; }
ins_mounts(){ docker inspect -f '{{range .Mounts}}{{.Source}} => {{.Destination}}{{println}}{{end}}' "$1" 2>/dev/null | sed '/^$/d'; }
ins_ports() { docker inspect -f '{{range $p,$c := .NetworkSettings.Ports}}{{$p}} {{range $c}}{{.HostIp}}:{{.HostPort}}{{end}}{{println}}{{end}}' "$1" 2>/dev/null | sed '/^$/d'; }

h "Contenedores en este host"
docker ps --format '{{.Names}}\t{{.Image}}' | sort

# --- Postgres ---
h "Bases de datos PostgreSQL detectadas"
pg_containers=$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -iE 'postgres|pgvector|timescale' | awk '{print $1}' || true)
if [ -z "$pg_containers" ]; then
  echo "${YELLOW}No se detectaron contenedores de Postgres por imagen. Revisa 'docker ps' arriba.${NC}"
else
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    echo
    echo "${CYAN}● Contenedor:${NC} $c"
    env=$(ins_env "$c")
    user=$(echo "$env" | grep -E '^POSTGRES_USER=' | head -1 | cut -d= -f2-)
    pass=$(echo "$env" | grep -E '^POSTGRES_PASSWORD=' | head -1 | cut -d= -f2-)
    dbnm=$(echo "$env" | grep -E '^POSTGRES_DB=' | head -1 | cut -d= -f2-)
    nets=$(ins_nets "$c" | paste -sd, -)
    echo "   Redes:       ${nets:-<none>}"
    echo "   Host (interno desde otro contenedor): ${BOLD}$c${NC}  (o el nombre de servicio EasyPanel)"
    echo "   Usuario:     ${user:-<no POSTGRES_USER>}"
    echo "   Password:    ${pass:-<no POSTGRES_PASSWORD>}"
    echo "   Database:    ${dbnm:-<no POSTGRES_DB>}"
    echo "   Bases existentes:"
    docker exec "$c" psql -U "${user:-postgres}" -tAc \
      "select '     - '||datname||' ('||pg_size_pretty(pg_database_size(datname))||')' from pg_database where datistemplate=false order by datname" 2>/dev/null \
      || echo "     (no se pudo listar; revisa el usuario)"
    pp=$(ins_ports "$c"); [ -n "$pp" ] && { echo "   Puertos publicados:"; echo "$pp" | sed 's/^/     /'; }
    echo "   ${GREEN}.env sugerido:${NC}"
    echo "     MIG_DOCKER_NETWORK=$(ins_nets "$c" | head -1)"
    echo "     SRC_PG_HOST=$c"
    echo "     SRC_PG_PORT=5432"
    echo "     SRC_PG_USER=${user:-postgres}"
    echo "     SRC_PG_PASSWORD=${pass:-?}"
  done <<< "$pg_containers"
fi

# --- Apps: claves de cifrado ---
h "Claves de cifrado (NO se pueden perder)"
app_containers=$(docker ps --format '{{.Names}}' | grep -iE 'chatwoot|n8n|langgraph|langraph' || true)
if [ -z "$app_containers" ]; then
  echo "${YELLOW}No se detectaron apps por nombre. Búscalas en 'docker ps' arriba.${NC}"
else
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    echo
    echo "${CYAN}● App:${NC} $c"
    ins_env "$c" | grep -E '^(SECRET_KEY_BASE|N8N_ENCRYPTION_KEY|RAILS_ENV|NODE_ENV|POSTGRES_|DATABASE_URL|REDIS_URL|ACTIVE_STORAGE_SERVICE)=' \
      | sed 's/^/   /' || echo "   (sin variables relevantes)"
    mounts=$(ins_mounts "$c")
    if [ -n "$mounts" ]; then
      echo "   ${GREEN}Volúmenes (storage):${NC}"
      echo "$mounts" | sed 's/^/     /'
    fi
  done <<< "$app_containers"
fi

h "Redes Docker"
docker network ls --format '{{.Name}}' | sed 's/^/   /'

echo
echo "${BOLD}Listo.${NC} Copia los valores sugeridos a tu .env (origen -> SRC_*, destino -> DST_*)."
echo "Para el storage de Chatwoot usa el 'Source' del volumen que termina en /storage."
