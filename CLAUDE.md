# EASYPANEL_MIGRATION

Migración de servicios autoalojados de un servidor **EasyPanel (origen)** a otro **EasyPanel (destino)**.

## ⚠️ REPOSITORIO PÚBLICO — no exponer información sensible

Este repo es **público**. **Nunca** commitear ni escribir en archivos versionados:

- Credenciales: passwords de Postgres, keys de B2, `SECRET_KEY_BASE`, `N8N_ENCRYPTION_KEY`, `DATABASE_URL`, tokens.
- Datos internos de infraestructura: IPs/hostnames del servidor, nombres reales de proyectos/servicios/contenedores, rutas de volúmenes específicas.

Reglas:
- Los valores reales viven **solo en el `.env` local** de cada servidor (está en `.gitignore`).
- `.env.example` es **solo plantilla** con placeholders genéricos (`<proyecto>`, `tu-key-id`, etc.).
- Antes de cada commit, verifica que no se cuele nada: `git grep -niE 'password=|secret|key_id|app_key|[0-9]{1,3}(\.[0-9]{1,3}){3}'`.
- Si algún dato sensible llega a aparecer en el chat o en logs, trátalo como secreto: no lo copies a archivos del repo.

## Objetivo

Mover, sin pérdida de datos, los siguientes servicios:

1. **Chatwoot** — ⚠️ **EL MÁS CRÍTICO.** Contiene la base de datos (PostgreSQL) y Redis con todas las conversaciones, contactos, agentes, adjuntos y configuración. La migración debe garantizar **cero pérdida de datos** y el menor downtime posible.
2. **n8n** — Automatizaciones / workflows. Tiene su propia BD (PostgreSQL) con los workflows, credenciales (cifradas) y ejecuciones.
3. **LangGraph** — Servicio de agentes/orquestación LLM. Estado y/o checkpoints (puede usar PostgreSQL/Redis según el setup).

> El orden de prioridad y dificultad es: **Chatwoot > n8n > LangGraph**.

## Principios de la migración

- **Datos primero, sin pérdida.** Antes de tocar nada en origen, hacer y verificar un backup completo (dump de Postgres + volúmenes/adjuntos + Redis si aplica).
- **No destruir el origen.** El servidor de origen NO se apaga ni se borra hasta confirmar que el destino funciona al 100% y los datos cuadran.
- **Verificar paridad de versiones.** La versión de Chatwoot / n8n / LangGraph y de sus dependencias (Postgres, Redis) debe coincidir entre origen y destino, o seguir el path de upgrade oficial.
- **Secrets y variables de entorno** deben replicarse exactamente. En Chatwoot y n8n hay claves de cifrado (`SECRET_KEY_BASE` en Chatwoot, `N8N_ENCRYPTION_KEY` en n8n) sin las cuales los datos cifrados (credenciales/cookies) quedan inservibles. **Copiar estas claves es obligatorio.**
- **DNS y dominios** se cambian al final, una vez validado el destino.

## Estado actual

- ✅ Tooling de migración **construido y probado E2E** (dump → B2 → restore → verify, incl. modo `--stream`).
- Ambos servidores son **EasyPanel** (Docker por debajo). El servidor es flojo → los scripts
  están optimizados para bajo consumo (ver "Decisiones de diseño").
- Pendiente: completar `.env` con los datos reales de conexión de origen y destino.
- Cómo usarlo: ver [README.md](README.md). Único requisito en el host: **Docker**.

## Decisiones de diseño (servidor flojo)

- **Solo Docker**: `pg_dump`/`pg_restore`/`psql`/`aws` corren en contenedores efímeros; no se
  instala nada en el host.
- **`--stream`**: dump directo `pg_dump | aws s3 cp -` a B2, **sin escribir a disco local**.
- **`JOBS=1`** por defecto (sin paralelismo) para no saturar CPU/RAM.
- Dump en formato **custom comprimido** (`-Fc`): liviano y fiable.
- La BD vive en B2 (Backblaze) y se **consume desde ahí** para restaurar en destino.

## Datos de entornos (rellenar)

> Completar con la información real. NO commitear secrets reales en texto plano: usar variables de entorno, `.env` ignorado por git, o un gestor de secretos.

### Origen (EasyPanel actual)
- Host / IP:
- URL EasyPanel:
- Proyecto(s):

### Destino (EasyPanel nuevo)
- Host / IP:
- URL EasyPanel:
- Proyecto(s):

## Por servicio

### Chatwoot (CRÍTICO)
- **Componentes**: app web (Rails), worker (Sidekiq), PostgreSQL, Redis.
- **A migrar**:
  - Dump de PostgreSQL (`pg_dump`/`pg_dumpall`).
  - Volumen de almacenamiento / adjuntos (uploads) — o storage externo (S3) si está configurado.
  - Variables de entorno, en especial `SECRET_KEY_BASE`, credenciales SMTP, claves de canales (WhatsApp, etc.).
- **Riesgo principal**: perder `SECRET_KEY_BASE` invalida tokens/datos cifrados.

### n8n
- **Componentes**: app n8n + PostgreSQL.
- **A migrar**: dump de Postgres + `N8N_ENCRYPTION_KEY` (sin ella las credenciales guardadas no se pueden descifrar).
- Revisar webhooks que apunten a URLs del dominio antiguo.

### LangGraph
- **Componentes**: servicio de orquestación de agentes (depende del setup: API + posible Postgres/Redis para checkpoints/estado).
- **A migrar**: variables de entorno (API keys de LLMs), persistencia de checkpoints si existe.
- Revisar integraciones cruzadas con Chatwoot y n8n (URLs internas).

## Plan de migración (alto nivel)

1. **Inventario**: versiones, variables de entorno, volúmenes y conexiones entre servicios.
2. **Backups verificados** en origen (dumps + volúmenes + secrets).
3. **Provisionar destino** con las mismas versiones y variables de entorno.
4. **Restaurar datos** en destino y validar integridad (conteos de filas, login, conversaciones, workflows).
5. **Pruebas funcionales** en destino con dominio temporal.
6. **Ventana de corte**: poner origen en mantenimiento, hacer dump final/incremental, restaurar, repuntar DNS.
7. **Validación post-corte** y monitorización.
8. **Decomisionar origen** solo tras periodo de gracia.

## Convenciones

- Idioma: español.
- Git: no añadir líneas `Co-Authored-By` ni co-autores en los commits.
- No commitear secretos. Usar `.env` (gitignored) o el gestor de secretos del entorno.
- Documentar cada paso ejecutado de la migración (runbook) para poder repetirlo/revertirlo.
