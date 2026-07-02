#!/usr/bin/env bash
# =============================================================================
# set-env.sh - Rellena el .env de forma interactiva (sin nano).
#   Pregunta credenciales B2 + datos de la BD de origen y los escribe en .env.
#   La app key y el password se piden OCULTOS. No quedan en el historial.
#
# Uso: bash scripts/set-env.sh
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
EXAMPLE="$ROOT/.env.example"

GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

[ -f "$ENV_FILE" ] || { cp "$EXAMPLE" "$ENV_FILE"; echo "${CYAN}Creado $ENV_FILE desde la plantilla.${NC}"; }

# set_kv KEY VALUE  -> reemplaza (o agrega) KEY=VALUE en el .env sin romper nada
set_kv() {
  local key="$1"; shift; local val="$*"
  local tmp; tmp="$(mktemp)"; local found=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "${key}="* ]]; then
      printf '%s=%s\n' "$key" "$val" >> "$tmp"; found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$ENV_FILE"
  [ "$found" -eq 0 ] && printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

ask()  { local p="$1" d="${2:-}" a; read -rp "$p${d:+ [$d]}: " a; echo "${a:-$d}"; }
asks() { local p="$1" a; read -rsp "$p: " a; echo >&2; printf '%s' "$a"; }  # oculto

echo "${GREEN}== Configuración B2 ==${NC}"
b2_bucket=$(ask "B2_BUCKET" "easypanel-migration")
b2_endpoint=$(ask "B2_ENDPOINT (ej. https://s3.us-west-004.backblazeb2.com)")
region_guess=$(printf '%s' "$b2_endpoint" | sed -E 's#https?://s3\.([^.]+)\.backblazeb2\.com.*#\1#')
b2_region=$(ask "B2_REGION" "$region_guess")
b2_keyid=$(ask "B2_KEY_ID")
b2_appkey=$(asks "B2_APP_KEY (oculto)")

echo
echo "${GREEN}== BD de origen (Chatwoot) ==${NC}"
cw_container=$(ask "CHATWOOT_SRC_PG_CONTAINER" "chatwood_chatwoot-db")
cw_dbname=$(ask "CHATWOOT_DB_NAME" "chatwood")
cw_user=$(ask "CHATWOOT_SRC_PG_USER" "postgres")
cw_pass=$(asks "CHATWOOT_SRC_PG_PASSWORD (oculto)")

set_kv B2_BUCKET   "$b2_bucket"
set_kv B2_ENDPOINT "$b2_endpoint"
set_kv B2_REGION   "$b2_region"
set_kv B2_KEY_ID   "$b2_keyid"
set_kv B2_APP_KEY  "$b2_appkey"
set_kv CHATWOOT_SRC_PG_CONTAINER "$cw_container"
set_kv CHATWOOT_DB_NAME          "$cw_dbname"
set_kv CHATWOOT_SRC_PG_USER      "$cw_user"
set_kv CHATWOOT_SRC_PG_PASSWORD  "$cw_pass"

echo
echo "${GREEN}✓ .env actualizado.${NC}  (valores sensibles no se muestran)"
echo "${YELLOW}Resumen (sin secretos):${NC}"
echo "  B2_BUCKET=$b2_bucket"
echo "  B2_ENDPOINT=$b2_endpoint"
echo "  B2_REGION=$b2_region"
echo "  B2_KEY_ID=$b2_keyid"
echo "  CHATWOOT_SRC_PG_CONTAINER=$cw_container"
echo "  CHATWOOT_DB_NAME=$cw_dbname"
echo
echo "Siguiente: ${CYAN}bash scripts/00-preflight.sh${NC}"
