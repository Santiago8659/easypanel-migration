# Migración por servicio

Resumen de cómo se migra cada servicio. Los valores reales (passwords, keys,
nombres de proyecto) van en el `.env` local, nunca en este repo público.

## Chatwoot  (Postgres + adjuntos + clave)

- **BD** (pgvector/pg17): `10-dump-db.sh chatwoot` → B2 → `30-restore-db.sh chatwoot --recreate`.
- **Adjuntos** (Active Storage local): `20-dump-storage.sh` → `40-restore-storage.sh`.
- **Clave**: copiar `SECRET_KEY_BASE` del servicio viejo a `chatwoot` **y** `chatwoot-sidekiq` nuevos (idéntico).
- En el destino, recrear los 4 servicios (app, db, redis, sidekiq) en EasyPanel antes de restaurar.

## n8n  (volumen, normalmente SQLite)

n8n suele guardar todo en su volumen (`automate_n8n_data` → `/home/node/.n8n`),
no en Postgres. Se migra **copiando el volumen**:

```bash
# Origen (idealmente con n8n PARADO para consistencia):
bash scripts/dump-volume.sh n8n --path /var/lib/docker/volumes/<proyecto>_n8n_data/_data

# Destino (servicio n8n creado y PARADO):
bash scripts/restore-volume.sh n8n --path /var/lib/docker/volumes/<proyecto>_n8n_data/_data
```

- La **clave de cifrado** de n8n vive dentro del volumen (`~/.n8n/config`) si no está
  como env. Al copiar el volumen viaja con él. Si en el destino EasyPanel define un
  `N8N_ENCRYPTION_KEY` distinto, habrá conflicto: usa el mismo o déjalo sin definir
  para que use el del config copiado.
- Si tu n8n SÍ usa Postgres externo (env `DB_TYPE=postgresdb`), entonces se migra como
  una BD normal con `10/30-*-db.sh` en vez de por volumen.

## LangGraph  (Postgres a ubicar)

Su `DATABASE_URL` apunta a un host `pgvector` (BD `langgraph_rag`) que no aparece entre
los contenedores corriendo. Hay que **localizar ese Postgres** primero:

```bash
# ¿Qué contenedores/Postgres hay (incluso parados)?
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'pgvector|postgres|langgraph'

# ¿Servicios Swarm?
docker service ls 2>/dev/null | grep -iE 'pg|langgraph'

# ¿A qué resuelve 'pgvector' desde el contenedor de langgraph?
docker exec $(docker ps -qf name=langgraph) getent hosts pgvector 2>/dev/null
```

Una vez ubicado el contenedor de su Postgres, se migra como una BD normal:
añade `langgraph` a `DATABASES` y define `LANGGRAPH_*` en el `.env`
(`LANGGRAPH_DB_NAME=langgraph_rag`, `LANGGRAPH_SRC_PG_CONTAINER=<contenedor>`, etc.),
luego `10-dump-db.sh langgraph` / `30-restore-db.sh langgraph`.
