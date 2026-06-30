#!/usr/bin/env bash
# =============================================================================
# test/run-test.sh - Prueba E2E del flujo de migración SIN tocar infra real.
#
# Levanta con docker compose:
#   - pg-src  (Postgres con datos semilla, simula ORIGEN)
#   - pg-dst  (Postgres vacío, simula DESTINO)
#   - minio   (S3-compatible, simula Backblaze B2)
#
# Luego ejecuta el flujo real:  dump -> B2(minio) -> restore -> verify
# y comprueba que los conteos de origen y destino coinciden.
#
# Uso:
#   bash test/run-test.sh           # corre y limpia al final
#   bash test/run-test.sh --keep    # deja todo arriba para inspeccionar
# =============================================================================
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TEST_DIR")"

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true

# Detectar 'docker compose' (v2) o 'docker-compose' (v1)
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi

cleanup() {
  if ! $KEEP; then
    echo "==> Limpiando entorno de prueba..."
    (cd "$TEST_DIR" && $DC down -v >/dev/null 2>&1 || true)
  else
    echo "==> --keep activo: el entorno sigue arriba (cd test && $DC down -v para bajar)."
  fi
}
trap cleanup EXIT

echo "==> Levantando pg-src, pg-dst y minio..."
(cd "$TEST_DIR" && $DC up -d)

echo "==> Esperando a que Postgres esté listo..."
for c in pg-src pg-dst; do
  cid="$(cd "$TEST_DIR" && $DC ps -q $c)"
  for i in $(seq 1 30); do
    st=$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)
    [ "$st" = "healthy" ] && break
    sleep 2
  done
  [ "$st" = "healthy" ] || { echo "ERROR: $c no quedó healthy"; exit 1; }
done

# ---- Config de migración apuntando al entorno de prueba ----
export MIG_DOCKER_NETWORK=migtest
export WORK_DIR="$ROOT/_work"
export PG_IMAGE=postgres:16
export AWS_IMAGE=amazon/aws-cli:latest
export B2_BUCKET=migtest-bucket
export B2_KEY_ID=minioadmin
export B2_APP_KEY=minioadmin
export B2_ENDPOINT=http://minio:9000
export B2_REGION=us-east-1
export B2_PREFIX=easypanel-migration
export DATABASES=chatwoot
export CHATWOOT_DB_NAME=chatwoot
export SRC_PG_HOST=pg-src SRC_PG_PORT=5432 SRC_PG_USER=postgres SRC_PG_PASSWORD=testpass
export DST_PG_HOST=pg-dst DST_PG_PORT=5432 DST_PG_USER=postgres DST_PG_PASSWORD=testpass
export JOBS=1

source "$ROOT/lib/common.sh"

echo "==> Creando bucket en minio..."
for i in $(seq 1 15); do
  if awscli s3 mb "s3://$B2_BUCKET" >/dev/null 2>&1 || awscli s3 ls "s3://$B2_BUCKET" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
awscli s3 ls "s3://$B2_BUCKET" >/dev/null 2>&1 || { echo "ERROR: no se pudo preparar el bucket en minio"; exit 1; }

echo "==> Cargando datos semilla en pg-src..."
pgtool pg-src 5432 postgres testpass psql -d chatwoot -v ON_ERROR_STOP=1 < "$TEST_DIR/seed.sql" >/dev/null

echo
echo "############# FASE DUMP #############"
bash "$ROOT/scripts/10-dump-db.sh" chatwoot

echo
echo "############# FASE RESTORE #############"
bash "$ROOT/scripts/30-restore-db.sh" chatwoot --recreate

echo
echo "############# FASE VERIFY #############"
if bash "$ROOT/scripts/50-verify.sh" chatwoot; then
  echo
  echo "==================================================="
  echo "  ✅ TEST E2E PASÓ: dump -> B2 -> restore -> verify"
  echo "==================================================="
  exit 0
else
  echo
  echo "==================================================="
  echo "  ❌ TEST E2E FALLÓ"
  echo "==================================================="
  exit 1
fi
