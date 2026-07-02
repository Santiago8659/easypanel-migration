# Fase B — Montar el server nuevo y ensayar hasta que el cutover sea aburrido

Objetivo: dejar el destino funcionando con **dominio temporal**, ensayar el
restore **varias veces**, y solo entonces hacer el corte de DNS. Nada se
apaga en el server viejo hasta validar el nuevo.

> Repo público: aquí no van IPs, passwords ni nombres internos. Los valores
> reales viven en el `.env` local y en `stack-export/` (ambos gitignored).

## 0. Preparar el VPS (una vez)

```bash
# en el server NUEVO, como root:
git clone https://github.com/Santiago8659/easypanel-migration.git
cd easypanel-migration
bash scripts/setup-server-nuevo.sh        # hardening + Docker + EasyPanel
```

Hace: DNS estable, ufw (22/80/443), SSH solo-llaves, fail2ban, swap 4G,
Docker y EasyPanel. La UI de EasyPanel NO queda expuesta: se entra por túnel
`ssh -L 3000:localhost:3000 root@<IP-NUEVA>` → http://localhost:3000

## 1. Recrear los servicios (con stack-export del viejo)

En el server viejo ya corrimos `export-stack.sh` → carpetas `stack-export/<proyecto>/`.
Cópialas al nuevo por scp (NO por git):

```bash
# desde el server viejo:
scp -r stack-export root@<IP-NUEVA>:~/easypanel-migration/
```

En la UI de EasyPanel del nuevo, por cada servicio (orden: db y redis primero,
luego app y worker):

1. Crear servicio con la **misma imagen** (ver `<servicio>.info.txt`).
2. Pegar el bloque completo de `<servicio>.env` en Environment.
3. Replicar volúmenes de `.info.txt` (Mounts).
4. **NO arrancar la app todavía** (db/redis sí pueden arrancar).

Cambios de variables en el NUEVO (los únicos):
- `FRONTEND_URL` de Chatwoot → el **dominio temporal** (se cambia al real en el cutover).
- Todo lo demás (SECRET_KEY_BASE, STORAGE_*, SMTP...) **idéntico al viejo**.

## 2. Restaurar datos desde B2

```bash
# en el server nuevo:
cd ~/easypanel-migration
cp .env.example .env    # llenar: B2_*, CHATWOOT_DST_PG_CONTAINER=<proyecto>_chatwoot-db, password del pg NUEVO
bash scripts/00-preflight.sh
bash scripts/30-restore-db.sh chatwoot --recreate
```

- Los **adjuntos NO se migran**: ya viven en B2; el Chatwoot nuevo los lee con
  las mismas `STORAGE_*`. (Por eso este server puede ser chico.)
- n8n: crear el servicio en EasyPanel (misma imagen), **pararlo**, y:
  `bash scripts/restore-volume.sh n8n --path /var/lib/docker/volumes/<proyecto>_n8n_data/_data`
  → arrancar. La clave de cifrado viaja dentro del volumen.
- LangGraph: pendiente ubicar su Postgres (`docs/SERVICES.md`).

## 3. Dominio temporal y pruebas

1. Apunta un subdominio temporal (p.ej. `chat-test.<tu-dominio>`) a la IP nueva.
2. Asígnalo al servicio chatwoot en EasyPanel (Let's Encrypt automático).
3. Arranca app + sidekiq y prueba:
   - Login con usuarios reales (vienen en la BD restaurada)
   - Conversaciones históricas + **adjuntos viejos** (deben venir de B2)
   - Enviar mensaje interno de prueba
   - `bash scripts/50-verify.sh chatwoot` → conteos viejo vs nuevo

⚠️ NO conectes canales de WhatsApp/Evolution en el server nuevo durante las
pruebas (crearía respuestas duplicadas con producción). Validar con la UI basta.

## 4. Ensayar el restore (mínimo 2 veces)

La gracia de tener la BD en B2: puedes repetir dump→restore las veces que
quieras sin tocar producción.

```bash
# en el viejo (produccion sigue normal):
bash scripts/10-dump-db.sh chatwoot --stream
# en el nuevo:
bash scripts/30-restore-db.sh chatwoot --recreate && bash scripts/50-verify.sh chatwoot
```

Cronometra el ciclo completo: ese será tu downtime real del cutover.

## 5. Cutover (cuando los ensayos aburran de lo bien que salen)

1. Poner Chatwoot viejo en pausa (parar app+sidekiq; db sigue viva).
2. `bash scripts/10-dump-db.sh chatwoot --stream` (dump final, minutos).
3. En el nuevo: `30-restore-db.sh chatwoot --recreate` + `50-verify.sh`.
4. Cambiar `FRONTEND_URL` al dominio real en el nuevo; repuntar **DNS** del
   dominio real → IP nueva.
5. Reconectar canales (WhatsApp/Evolution) en el nuevo.
6. Validación post-corte; el viejo queda apagado pero intacto (rollback = DNS).
7. Decomisionar el viejo tras periodo de gracia (días).

## Checklist rápido

- [ ] VPS nuevo con **NVMe** (no SSD compartido)
- [ ] `setup-server-nuevo.sh` corrido
- [ ] stack-export copiado por scp
- [ ] Servicios recreados (db/redis → app/worker)
- [ ] `SECRET_KEY_BASE` idéntico en app y sidekiq
- [ ] `STORAGE_*` idénticas (mismos adjuntos B2)
- [ ] Restore + verify OK
- [ ] Dominio temporal funcionando (login + históricos + adjuntos)
- [ ] 2+ ensayos de dump→restore cronometrados
- [ ] n8n restaurado y workflows visibles
- [ ] Cutover + DNS + validación
