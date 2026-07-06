#!/usr/bin/env bash
# =============================================================================
# n8n-export.sh - Exporta TODO n8n del server VIEJO y lo sube a B2.
#
# Incluye:
#   - entidades base (usuarios, proyectos, roles, scopes, settings)  [export:entities]
#   - workflows                                                      [export:workflow --backup]
#   - credenciales CIFRADAS                                          [export:credentials --backup]
#
# Las credenciales van CIFRADAS (NO --decrypted): seguras siempre que el
# destino use la MISMA N8N_ENCRYPTION_KEY. Las ejecuciones (logs) NO se migran.
#
# Uso (server viejo):  bash scripts/n8n-export.sh [nombre-contenedor-n8n]
#   (default del filtro: automate_n8n)
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

FILTER="${1:-automate_n8n}"
# el contenedor de la app (excluye -runner y -db)
CID=$(docker ps --format '{{.Names}}' | grep "$FILTER" | grep -vE 'runner|\-db' | head -1)
[ -n "$CID" ] || die "No encontré el contenedor n8n (filtro: $FILTER). Revisa 'docker ps'."
info "Contenedor n8n: $CID"

TS=$(date '+%Y%m%d-%H%M%S')
EXP="/home/node/.n8n/export-$TS"

step "1/3 Exportando entidades base (usuarios, proyectos, roles, settings)"
docker exec "$CID" sh -c "rm -rf $EXP && mkdir -p $EXP/entities $EXP/wf $EXP/cred"
docker exec "$CID" n8n export:entities --outputDir="$EXP/entities" >/dev/null
log "Entidades base exportadas."

step "2/3 Exportando workflows"
docker exec "$CID" n8n export:workflow --backup --output="$EXP/wf/" >/dev/null
log "Workflows exportados."

step "3/3 Exportando credenciales (CIFRADAS)"
docker exec "$CID" n8n export:credentials --backup --output="$EXP/cred/" >/dev/null
log "Credenciales exportadas (cifradas)."

step "Empaquetando y subiendo a B2"
docker cp "$CID:$EXP" "$WORK_DIR/n8n-export-$TS"
tar czf "$WORK_DIR/n8n-full-$TS.tar.gz" -C "$WORK_DIR" "n8n-export-$TS"
docker exec "$CID" rm -rf "$EXP" 2>/dev/null || true

awscli s3 cp "/work/n8n-full-$TS.tar.gz" "$(s3_base)/volumes/n8n/n8n-full-$TS.tar.gz"
echo "n8n-full-$TS.tar.gz" > "$WORK_DIR/n8n-latest.txt"
awscli s3 cp "/work/n8n-latest.txt" "$(s3_base)/volumes/n8n/n8n-latest.txt" >/dev/null

rm -rf "$WORK_DIR/n8n-export-$TS" "$WORK_DIR/n8n-full-$TS.tar.gz" "$WORK_DIR/n8n-latest.txt"
log "EXPORT n8n completo en B2: $(s3_base)/volumes/n8n/n8n-full-$TS.tar.gz"
info "Ahora, en el server NUEVO: bash scripts/n8n-import.sh"
warn "Recuerda: el n8n nuevo debe tener N8N_ENCRYPTION_KEY = la del viejo, o las credenciales no descifran."
