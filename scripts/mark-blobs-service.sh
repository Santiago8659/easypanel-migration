#!/usr/bin/env bash
# =============================================================================
# mark-blobs-service.sh - Cambia active_storage_blobs.service_name de 'local'
# a 's3_compatible' para que Chatwoot lea los adjuntos desde B2.
#
# SEGURIDAD (en este orden):
#   1. Muestra el estado actual de service_name en la BD.
#   2. VERIFICA una muestra aleatoria de keys reales de la BD contra el bucket
#      B2 (head-object). Si falta UNA sola, ABORTA sin tocar nada.
#   3. Pide confirmación explícita (SI).
#   4. UPDATE en una sola sentencia (atómica en Postgres).
#
# ES REVERSIBLE mientras NO borres los archivos locales:
#   revertir = UPDATE active_storage_blobs SET service_name='local'
#              WHERE service_name='s3_compatible';
# Por eso: NO borrar los 148G locales hasta validar Chatwoot con B2 en vivo.
#
# Uso:
#   bash scripts/mark-blobs-service.sh [servicio] [--sample N]
#   (servicio por defecto: chatwoot; muestra por defecto: 25 keys)
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker

: "${STORAGE_BUCKET_NAME:?Falta STORAGE_BUCKET_NAME en .env}"
: "${STORAGE_ACCESS_KEY_ID:?Falta STORAGE_ACCESS_KEY_ID en .env}"
: "${STORAGE_SECRET_ACCESS_KEY:?Falta STORAGE_SECRET_ACCESS_KEY en .env}"
: "${STORAGE_ENDPOINT:?Falta STORAGE_ENDPOINT en .env}"

SERVICE="chatwoot"; FROM="local"; TO="s3_compatible"; SAMPLE=25
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift 2 ;;
    --from)   FROM="$2"; shift 2 ;;
    --to)     TO="$2"; shift 2 ;;
    -*) die "Opción desconocida: $1" ;;
    *) SERVICE="$1"; shift ;;
  esac
done

cont=$(svc_container "$SERVICE" SRC)
host=$(svc_get "$SERVICE" SRC HOST); port=$(svc_get "$SERVICE" SRC PORT)
user=$(svc_get "$SERVICE" SRC USER); pass=$(svc_get "$SERVICE" SRC PASSWORD)
db=$(svc_dbname "$SERVICE"); port="${port:-5432}"; user="${user:-postgres}"
[ -n "$cont" ] || [ -n "$host" ] || die "Falta contenedor/host de la BD en .env"
# </dev/null: docker exec -i consumiría el stdin del script (se tragaría el 'SI'
# de la confirmación). Ninguna de estas queries necesita stdin.
pg() { pg_target "$cont" "$host" "$port" "$user" "$pass" "$@" </dev/null; }

# head-object contra el bucket de media con las credenciales STORAGE_*
media_head() {
  docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
    -e AWS_ACCESS_KEY_ID="$STORAGE_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$STORAGE_SECRET_ACCESS_KEY" \
    -e AWS_DEFAULT_REGION="${STORAGE_REGION:-us-east-005}" \
    -e AWS_S3_ADDRESSING_STYLE=path \
    "$AWS_IMAGE" --cli-connect-timeout 10 \
    --endpoint-url "$STORAGE_ENDPOINT" \
    s3api head-object --bucket "$STORAGE_BUCKET_NAME" --key "$1" >/dev/null 2>&1
}

step "1) Estado actual de active_storage_blobs (BD: $db)"
pg psql -d "$db" -c "SELECT service_name, count(*) FROM active_storage_blobs GROUP BY service_name ORDER BY 2 DESC;"

n=$(pg psql -d "$db" -tAc "SELECT count(*) FROM active_storage_blobs WHERE service_name='$FROM';" | tr -d '[:space:]')
[ "$n" != "0" ] || die "No hay blobs con service_name='$FROM'. Nada que hacer."

step "2) Verificando $SAMPLE keys aleatorias de la BD contra B2 ($STORAGE_BUCKET_NAME)"
keys=$(pg psql -d "$db" -tAc \
  "SELECT key FROM active_storage_blobs WHERE service_name='$FROM' ORDER BY random() LIMIT $SAMPLE;")
[ -n "$keys" ] || die "No se pudieron leer keys de la BD."

ok=0; bad=0
while IFS= read -r k; do
  k=$(echo "$k" | tr -d '[:space:]'); [ -z "$k" ] && continue
  if media_head "$k"; then
    ok=$((ok+1)); echo "  ${GREEN}✓${NC} $k"
  else
    bad=$((bad+1)); echo "  ${RED}✗ FALTA${NC} $k"
  fi
done <<< "$keys"

echo
if [ "$bad" -gt 0 ]; then
  die "ABORTADO: $bad de $((ok+bad)) keys NO están en B2. La subida no está completa. Re-ejecuta migrate-storage-to-b2.sh (reanuda) y vuelve a intentar. La BD NO fue modificada."
fi
log "Muestra verificada: $ok/$ok keys existen en B2."

step "3) Confirmación"
warn "Se cambiará service_name '$FROM' -> '$TO' en $n blobs."
warn "Reversible mientras NO borres los archivos locales:"
warn "  UPDATE active_storage_blobs SET service_name='$FROM' WHERE service_name='$TO';"
read -rp "Confirma escribiendo SI en mayúsculas: " c
[ "$c" = "SI" ] || die "Cancelado (no se escribió SI). La BD NO fue modificada."

step "4) Actualizando (una sentencia atómica)"
pg psql -d "$db" -v ON_ERROR_STOP=1 -c \
  "UPDATE active_storage_blobs SET service_name='$TO' WHERE service_name='$FROM';"

step "Estado final"
pg psql -d "$db" -c "SELECT service_name, count(*) FROM active_storage_blobs GROUP BY service_name ORDER BY 2 DESC;"
log "Listo. Ahora en EasyPanel pon en chatwoot Y chatwoot-sidekiq:"
echo "    ACTIVE_STORAGE_SERVICE=s3_compatible"
echo "    STORAGE_BUCKET_NAME=$STORAGE_BUCKET_NAME"
echo "    STORAGE_ACCESS_KEY_ID=...   STORAGE_SECRET_ACCESS_KEY=..."
echo "    STORAGE_REGION=${STORAGE_REGION:-us-east-005}"
echo "    STORAGE_ENDPOINT=$STORAGE_ENDPOINT"
echo "    STORAGE_FORCE_PATH_STYLE=true"
echo "  y reinicia ambos. NO borres los archivos locales hasta validar adjuntos viejos y nuevos."
