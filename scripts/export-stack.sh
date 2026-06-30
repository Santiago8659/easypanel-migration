#!/usr/bin/env bash
# =============================================================================
# export-stack.sh - Exporta la definición de los servicios de EasyPanel para
#                   recrearlos en otro server con copy/paste (Camino A).
#
# SOLO LECTURA (docker inspect). Genera archivos LOCALES en ./stack-export/
# con, por cada servicio: imagen, TODAS las variables de entorno, volúmenes,
# puertos y comando. Esos archivos CONTIENEN SECRETOS (SECRET_KEY_BASE,
# passwords) -> están en .gitignore, NUNCA se suben al repo.
#
# Uso (en el server viejo):
#   bash scripts/export-stack.sh            # todos los proyectos (menos infra)
#   bash scripts/export-stack.sh chatwood   # solo el proyecto 'chatwood'
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_docker

PROJECT_FILTER="${1:-}"
OUT_DIR="$ROOT_DIR/stack-export"

# Variables de las imágenes base que NO aportan a EasyPanel (ruido). El resto
# (SECRET_KEY_BASE, POSTGRES_*, REDIS_URL, SMTP_*, etc.) SÍ se exporta.
BASE_VARS='^(PATH|HOME|HOSTNAME|TERM|PWD|SHLVL|container|LANG|LANGUAGE|LC_ALL|GOSU_VERSION|GPG_KEY|GPG_KEYS|PG_MAJOR|PG_VERSION|PGDATA|PG_SHA256|NODE_VERSION|YARN_VERSION|RUBY_MAJOR|RUBY_VERSION|RUBY_DOWNLOAD_SHA256|RUBY_DOWNLOAD_GPG|RUBYGEMS_VERSION|BUNDLER_VERSION|REDIS_VERSION|REDIS_DOWNLOAD_SHA256|REDIS_DOWNLOAD_URL|MALLOC_ARENA_MAX|LD_PRELOAD|DEBIAN_FRONTEND)='

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

step "Exportando definición de servicios -> $OUT_DIR"
warn "Los archivos generados contienen SECRETOS. No los subas a git (ya están ignorados)."

count=0
while IFS='|' read -r name image; do
  [ -z "$name" ] && continue
  base="${name%%.*}"            # project_service  (quita .replica.taskid de Swarm)
  project="${base%%_*}"         # antes del primer _
  service="${base#*_}"          # después del primer _
  case "$project" in easypanel|traefik) continue ;; esac
  [ -n "$PROJECT_FILTER" ] && [ "$project" != "$PROJECT_FILTER" ] && continue

  sdir="$OUT_DIR/$project"; mkdir -p "$sdir"

  # --- variables de entorno (para pegar en la pestaña Environment) ---
  {
    echo "# === $project / $service ==="
    echo "# Imagen: $image"
    echo "# Pegar estas variables en EasyPanel (servicio nuevo -> Environment)."
    echo "# OJO: contiene secretos. No compartir."
    echo
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
      | grep -vE "$BASE_VARS" || true
  } > "$sdir/$service.env"

  # --- info estructural (imagen, volúmenes, puertos, comando) ---
  {
    echo "Proyecto:  $project"
    echo "Servicio:  $service"
    echo "Imagen:    $image"
    echo
    echo "== Volúmenes / Mounts =="
    docker inspect -f '{{range .Mounts}}{{.Type}}  {{.Source}}  =>  {{.Destination}}{{println}}{{end}}' "$name" 2>/dev/null
    echo "== Puertos expuestos =="
    docker inspect -f '{{range $p,$_ := .Config.ExposedPorts}}{{$p}}{{println}}{{end}}' "$name" 2>/dev/null
    echo "== Redes =="
    docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}' "$name" 2>/dev/null
    echo "== Command =="
    docker inspect -f '{{json .Config.Cmd}}' "$name" 2>/dev/null; echo
    echo "== Entrypoint =="
    docker inspect -f '{{json .Config.Entrypoint}}' "$name" 2>/dev/null; echo
  } > "$sdir/$service.info.txt"

  nvars=$(grep -cvE '^\s*#|^\s*$' "$sdir/$service.env" || true)
  echo "  ${GREEN}✓${NC} $project/$service  (imagen: $image, $nvars vars)"
  count=$((count+1))
done < <(docker ps --format '{{.Names}}|{{.Image}}' | sort)

# Guía de uso
cat > "$OUT_DIR/_LEER.txt" <<'EOF'
CÓMO USAR ESTE EXPORT (Camino A) en el EasyPanel NUEVO
======================================================
Por cada servicio (carpeta <proyecto>/<servicio>):

1. En EasyPanel nuevo: crea el proyecto y agrega el servicio con la MISMA imagen
   (ver <servicio>.info.txt -> "Imagen").
2. Abre <servicio>.env y pega TODO el bloque en la pestaña "Environment" del
   servicio. Esto incluye SECRET_KEY_BASE, POSTGRES_*, etc. -> nadie re-configura.
3. Replica los volúmenes que aparezcan en <servicio>.info.txt (Mounts) y los
   puertos/dominios si aplica.
4. Crea primero las BDs y redis, luego la app y el worker (sidekiq).
5. NO arranques la app todavía: primero restaura los datos desde B2
   (scripts 30-restore-db.sh / 40-restore-storage.sh / restore-volume.sh).

IMPORTANTE: el SECRET_KEY_BASE de chatwoot y chatwoot-sidekiq debe ser EL MISMO
que aquí (ya viene en sus .env). Así los datos cifrados siguen válidos.

Estos archivos contienen secretos: no los subas a ningún repo ni chat.
EOF

echo
log "Exportados $count servicio(s) en: $OUT_DIR"
info "Lee $OUT_DIR/_LEER.txt para el paso a paso en el server nuevo."
