#!/usr/bin/env bash
# =============================================================================
# backup-all.sh - Respaldo de las BDs del server (nuevo) a B2. Para cron.
#
# Dump por streaming (pg_dump | aws s3 cp -): NO escribe a disco.
# Sube a  <prefix>/backups/<servicio>/<servicio>-<fecha>.dump  + latest.txt
#
# Config por .env (opcional):
#   BACKUP_TARGETS="servicio:contenedorBD:nombreBD  servicio2:...:..."
#   default: chatwoot + n8n del server nuevo.
#
# Uso:   bash scripts/backup-all.sh
# Cron:  0 3 * * * cd /root/easypanel-migration && bash scripts/backup-all.sh >> /var/log/backup-all.log 2>&1
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env
need_docker
check_b2_config

# servicio : filtro-contenedor-BD : nombre-BD
BACKUP_TARGETS="${BACKUP_TARGETS:-chatwoot:chatwood_chatwoot-db:chatwood n8n:automate_n8n-db:automate}"

ts=$(date '+%Y%m%d-%H%M%S')
rc=0
for t in $BACKUP_TARGETS; do
  svc="${t%%:*}"; rest="${t#*:}"; cont="${rest%%:*}"; db="${rest##*:}"
  cid=$(docker ps --filter "name=$cont" --format '{{.Names}}' | head -1)
  if [ -z "$cid" ]; then warn "[$svc] contenedor '$cont' no está corriendo; se omite."; rc=1; continue; fi
  pass=$(docker exec "$cid" printenv POSTGRES_PASSWORD 2>/dev/null | tr -d '\r\n')
  user=$(docker exec "$cid" printenv POSTGRES_USER 2>/dev/null | tr -d '\r\n'); user="${user:-postgres}"
  file="${svc}-${ts}.dump"

  step "[$svc] Respaldando '$db' ($cid) -> B2 (stream)"
  if docker exec -e PGPASSWORD="$pass" "$cid" pg_dump -U "$user" -d "$db" \
       -Fc --no-owner --no-privileges \
     | awscli s3 cp - "$(s3_base)/backups/$svc/$file"; then
    echo "$file" > "$WORK_DIR/latest.txt"
    awscli s3 cp "/work/latest.txt" "$(s3_base)/backups/$svc/latest.txt" >/dev/null
    log "[$svc] OK: $(s3_base)/backups/$svc/$file"
  else
    warn "[$svc] FALLÓ el respaldo."; rc=1
  fi
done
rm -f "$WORK_DIR/latest.txt"

if [ "$rc" -eq 0 ]; then
  log "BACKUP completo ($ts)."
else
  warn "BACKUP terminó con avisos ($ts). Revisa arriba."
fi
exit $rc
