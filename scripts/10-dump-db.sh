#!/usr/bin/env bash
# =============================================================================
# 10-dump-db.sh - Dump de una BD de ORIGEN y subida a B2
#
# Uso:
#   bash scripts/10-dump-db.sh <servicio> [opciones]
#
# Opciones:
#   --stream      Streamea pg_dump -> B2 sin escribir a disco local (servidor
#                 flojo / poco disco). Sin checksum sidecar.
#   --keep        No borrar el dump local tras subir (modo archivo).
#   --dry-run     Mostrar lo que haría, sin ejecutar.
#
# Ejemplos:
#   bash scripts/10-dump-db.sh chatwoot
#   bash scripts/10-dump-db.sh chatwoot --stream      # sin tocar disco local
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

SERVICE="${1:-}"; [ -n "$SERVICE" ] || die "Uso: $0 <servicio> [--stream] [--keep] [--dry-run]"
shift || true
STREAM=false; KEEP=false; DRY_RUN=false
for a in "$@"; do
  case "$a" in
    --stream) STREAM=true ;;
    --keep)   KEEP=true ;;
    --dry-run) DRY_RUN=true ;;
    *) die "Opción desconocida: $a" ;;
  esac
done

host=$(svc_get "$SERVICE" SRC HOST); port=$(svc_get "$SERVICE" SRC PORT)
user=$(svc_get "$SERVICE" SRC USER); pass=$(svc_get "$SERVICE" SRC PASSWORD)
db=$(svc_dbname "$SERVICE")
[ -n "$host" ] || die "Falta SRC_PG_HOST (o $(upper "$SERVICE")_SRC_PG_HOST) en .env"
port="${port:-5432}"

ts=$(date '+%Y%m%d-%H%M%S')
file="${SERVICE}-${ts}.dump"

step "Dump de '$db' desde $host:$port  (servicio: $SERVICE)"

info "Comprobando conexión..."
pgtool "$host" "$port" "$user" "$pass" psql -d "$db" -tAc "select 1" >/dev/null \
  || die "No conecta a la BD '$db' en $host:$port. Revisa credenciales/red (MIG_DOCKER_NETWORK)."
size=$(pgtool "$host" "$port" "$user" "$pass" psql -d "$db" -tAc \
  "select pg_size_pretty(pg_database_size('$db'))" 2>/dev/null | tr -d '[:space:]' || echo "?")
info "Tamaño de la BD: ${size}"

if $DRY_RUN; then
  info "[DRY-RUN] pg_dump -Fc -d $db  ->  $(s3_base)/$SERVICE/$file"
  exit 0
fi

if $STREAM; then
  # ---- Modo streaming: pg_dump (stdout) | aws s3 cp - (stdin) ----
  # No usa disco local. Ideal para servidores con poco almacenamiento.
  step "Streaming pg_dump -> B2 (sin disco local)"
  set -o pipefail
  docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
      -e PGPASSWORD="$pass" -e PGCONNECT_TIMEOUT=15 \
      "$PG_IMAGE" pg_dump -h "$host" -p "$port" -U "$user" -d "$db" \
      -Fc --no-owner --no-privileges \
    | docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
      -e AWS_ACCESS_KEY_ID="$B2_KEY_ID" -e AWS_SECRET_ACCESS_KEY="$B2_APP_KEY" \
      -e AWS_DEFAULT_REGION="${B2_REGION:-us-east-1}" -e AWS_S3_ADDRESSING_STYLE=path \
      "$AWS_IMAGE" --endpoint-url "$B2_ENDPOINT" s3 cp - "$(s3_base)/$SERVICE/$file"
  echo "$file" > "$WORK_DIR/latest.txt"
  awscli s3 cp "/work/latest.txt" "$(s3_base)/$SERVICE/latest.txt"
  rm -f "$WORK_DIR/latest.txt"
  log "Dump (stream) subido: $(s3_base)/$SERVICE/$file"
  warn "Modo stream no genera checksum sidecar; la integridad la valida pg_restore al restaurar."
else
  # ---- Modo archivo: dump a disco + sha256 + subida verificable ----
  info "Generando dump local (formato custom comprimido)..."
  pgtool "$host" "$port" "$user" "$pass" pg_dump -d "$db" \
    -Fc --no-owner --no-privileges -f "/work/$file"
  log "Dump local: $WORK_DIR/$file ($(du -h "$WORK_DIR/$file" | cut -f1))"

  info "Calculando sha256..."
  sha256_make "$file"

  step "Subiendo a B2"
  awscli s3 cp "/work/$file" "$(s3_base)/$SERVICE/$file"
  awscli s3 cp "/work/$file.sha256" "$(s3_base)/$SERVICE/$file.sha256"
  echo "$file" > "$WORK_DIR/latest.txt"
  awscli s3 cp "/work/latest.txt" "$(s3_base)/$SERVICE/latest.txt"
  log "Subido: $(s3_base)/$SERVICE/$file"

  if ! $KEEP; then
    rm -f "$WORK_DIR/$file" "$WORK_DIR/$file.sha256" "$WORK_DIR/latest.txt"
    info "Limpieza local hecha (usa --keep para conservar el dump)."
  fi
fi

log "DUMP de '$SERVICE' completado."
