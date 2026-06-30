#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - utilidades compartidas para la migracion EasyPanel -> EasyPanel
#
# Toda herramienta externa (pg_dump, pg_restore, psql, aws) corre dentro de
# contenedores efimeros. El UNICO requisito en el host es Docker.
# Pensado para servidores flojos: por defecto sin paralelismo y con streaming
# opcional para no llenar disco.
# =============================================================================
set -euo pipefail

# --- rutas ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$LIB_DIR")"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/_work}"

# --- colores (solo si hay TTY) ---
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=; GREEN=; YELLOW=; CYAN=; BOLD=; NC=
fi
log()  { echo "${GREEN}[OK]${NC}   $*"; }
info() { echo "${CYAN}[INFO]${NC} $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo; echo "${BOLD}==> $*${NC}"; }

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

# --- cargar .env de forma segura (sin ejecutar el archivo) ---
load_env() {
  local f="${1:-$ROOT_DIR/.env}"
  if [ ! -f "$f" ]; then
    # Si no hay .env pero la config ya viene por variables de entorno
    # (p.ej. el harness de test la exporta), continuamos sin error.
    if [ -n "${B2_BUCKET:-}" ] && [ -n "${DATABASES:-}" ]; then
      return 0
    fi
    die "No existe $f. Copia .env.example a .env y complétalo."
  fi
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%$'\r'}"
    if [[ "$val" == \"*\" ]]; then val="${val#\"}"; val="${val%\"}"; fi
    if [[ "$val" == \'*\' ]]; then val="${val#\'}"; val="${val%\'}"; fi
    export "$key=$val"
  done < "$f"
}

# --- docker ---
need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker no está instalado / en PATH."
  docker info >/dev/null 2>&1 || die "El daemon de Docker no responde (¿permisos? ¿está corriendo?)."
}

# Red de docker opcional. En los tests apunta a la red de compose (minio/pg);
# en producción normalmente se deja vacío (bridge) o se usa la red de EasyPanel
# para alcanzar el contenedor de Postgres por su nombre de servicio.
NET_ARGS=()
if [ -n "${MIG_DOCKER_NETWORK:-}" ]; then NET_ARGS=(--network "$MIG_DOCKER_NETWORK"); fi

# Imagen cliente de Postgres (pg_dump/pg_restore/psql).
# IMPORTANTE: su major debe ser >= al del servidor de Postgres de ORIGEN.
PG_IMAGE="${PG_IMAGE:-postgres:16}"
# Imagen de aws-cli para hablar con B2 (S3-compatible).
AWS_IMAGE="${AWS_IMAGE:-amazon/aws-cli:latest}"

# pgtool <host> <port> <user> <password> <pg_dump|pg_restore|psql> [args...]
# Monta WORK_DIR en /work dentro del contenedor.
pgtool() {
  local host=$1 port=$2 user=$3 pass=$4 tool=$5; shift 5
  docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
    -e PGPASSWORD="$pass" \
    -e PGCONNECT_TIMEOUT=15 \
    -v "$WORK_DIR:/work" \
    "$PG_IMAGE" "$tool" -h "$host" -p "$port" -U "$user" "$@"
}

# awscli [args...]  -> aws --endpoint-url <B2> [args...]
awscli() {
  docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
    -e AWS_ACCESS_KEY_ID="${B2_KEY_ID:-}" \
    -e AWS_SECRET_ACCESS_KEY="${B2_APP_KEY:-}" \
    -e AWS_DEFAULT_REGION="${B2_REGION:-us-east-1}" \
    -e AWS_S3_ADDRESSING_STYLE=path \
    -v "$WORK_DIR:/work" \
    "$AWS_IMAGE" --endpoint-url "${B2_ENDPOINT:?Falta B2_ENDPOINT}" "$@"
}

s3_base() { echo "s3://${B2_BUCKET:?Falta B2_BUCKET}/${B2_PREFIX:-easypanel-migration}"; }

# --- resolución de config por servicio (con override por servicio) ---
# Para el servicio "chatwoot", lado "SRC", campo "HOST":
#   usa CHATWOOT_SRC_PG_HOST si existe, si no SRC_PG_HOST.
svc_get() {
  local svc=$1 side=$2 field=$3 up spec gen
  up=$(upper "$svc")
  spec="${up}_${side}_PG_${field}"
  gen="${side}_PG_${field}"
  echo "${!spec:-${!gen:-}}"
}
# Nombre real de la BD para el servicio. chatwoot -> CHATWOOT_DB_NAME (default: el nombre del servicio)
svc_dbname() {
  local up v; up=$(upper "$1"); v="${up}_DB_NAME"
  echo "${!v:-$1}"
}

# sha256 portable (Linux: sha256sum, macOS: shasum -a 256)
sha256_make() { # <archivo-en-WORK_DIR>  -> crea <archivo>.sha256
  ( cd "$WORK_DIR" && { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } > "$1.sha256" )
}
sha256_check() { # <archivo-en-WORK_DIR>  -> 0 si coincide
  ( cd "$WORK_DIR" && { sha256sum -c "$1.sha256" 2>/dev/null || shasum -a 256 -c "$1.sha256"; } )
}

mkdir -p "$WORK_DIR"
