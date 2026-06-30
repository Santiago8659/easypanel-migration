#!/usr/bin/env bash
# =============================================================================
# migrate.sh - Orquestador de la migración EasyPanel -> EasyPanel.
#
# Fases (puedes correrlas por separado o todas juntas):
#   dump      Dump de todas las BDs de ORIGEN -> B2
#   restore   Restore de todas las BDs en DESTINO desde B2
#   verify    Comparar conteos origen vs destino
#   all       dump -> restore -> verify
#
# Uso:
#   bash migrate.sh dump
#   bash migrate.sh restore --recreate
#   bash migrate.sh verify
#   bash migrate.sh all --recreate
#   bash migrate.sh all --recreate --stream     # dump por streaming (server flojo)
#
# Las opciones extra (--recreate, --stream, --dry-run, --keep) se pasan a los
# subscripts correspondientes.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib/common.sh"
load_env

PHASE="${1:-}"; [ -n "$PHASE" ] || die "Uso: bash migrate.sh <dump|restore|verify|all> [opciones]"
shift || true
EXTRA=("$@")

do_dump() {
  for svc in $DATABASES; do
    step "DUMP servicio: $svc"
    # solo pasa flags relevantes a dump (--stream/--dry-run/--keep)
    local f=()
    for a in ${EXTRA[@]+"${EXTRA[@]}"}; do
      case "$a" in --stream|--dry-run|--keep) f+=("$a") ;; esac
    done
    bash "$ROOT/scripts/10-dump-db.sh" "$svc" ${f[@]+"${f[@]}"}
  done
}

do_restore() {
  for svc in $DATABASES; do
    step "RESTORE servicio: $svc"
    local f=()
    for a in ${EXTRA[@]+"${EXTRA[@]}"}; do
      case "$a" in --recreate|--force|--dry-run|--keep) f+=("$a") ;; esac
    done
    bash "$ROOT/scripts/30-restore-db.sh" "$svc" ${f[@]+"${f[@]}"}
  done
}

do_verify() {
  local rc=0
  for svc in $DATABASES; do
    step "VERIFY servicio: $svc"
    bash "$ROOT/scripts/50-verify.sh" "$svc" || rc=1
  done
  return $rc
}

case "$PHASE" in
  dump)    do_dump ;;
  restore) do_restore ;;
  verify)  do_verify ;;
  all)     do_dump; do_restore; do_verify ;;
  *) die "Fase desconocida: $PHASE (usa dump|restore|verify|all)" ;;
esac

log "Fase '$PHASE' finalizada."
