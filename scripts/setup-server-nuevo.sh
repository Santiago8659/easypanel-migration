#!/usr/bin/env bash
# =============================================================================
# setup-server-nuevo.sh - Prepara un VPS limpio para ser el DESTINO EasyPanel.
#
# Basado en el hardening del setup de Odoo (mismo dueño):
#   1. DNS estable (systemd-resolved falla intermitente en algunos VPS)
#   2. Sistema actualizado
#   3. Firewall ufw: solo 22, 80, 443
#   4. SSH hardening (sin password, solo llaves; root con llave)
#   5. fail2ban (protege SSH de fuerza bruta)
#   6. Swap 4G + swappiness bajo (colchón anti-OOM)
#   7. Docker + EasyPanel
#
# Idempotente: se puede re-ejecutar. Pensado para Ubuntu/Debian.
# Uso (como root en el server NUEVO):
#   bash setup-server-nuevo.sh [--dry-run]
# =============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
log()  { echo "${GREEN}[OK]${NC}   $*"; }
info() { echo "${CYAN}[INFO]${NC} $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo; echo "${BOLD}==> $*${NC}"; }

DRY=false; [ "${1:-}" = "--dry-run" ] && DRY=true
run() { if $DRY; then echo "  [DRY-RUN] $*"; else eval "$@"; fi; }

[ "$(id -u)" = "0" ] || die "Ejecutar como root."

step "1/7 DNS estable"
if ! grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  run "rm -f /etc/resolv.conf && printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf"
  run "systemctl disable systemd-resolved 2>/dev/null || true"
  run "systemctl stop systemd-resolved 2>/dev/null || true"
  log "DNS fijado a 8.8.8.8 / 1.1.1.1"
else
  log "DNS ya configurado."
fi

step "2/7 Actualizar sistema"
run "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
log "Sistema al día."

step "3/7 Firewall (ufw): solo 22, 80, 443"
run "apt-get install -y -qq ufw"
run "ufw default deny incoming"
run "ufw default allow outgoing"
run "ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp"
run "ufw --force enable"
log "Firewall activo (22/80/443)."
warn "El puerto 3000 (UI de EasyPanel) queda CERRADO desde fuera: accede vía túnel SSH:"
warn "  ssh -L 3000:localhost:3000 root@IP   ->  http://localhost:3000"

step "4/7 SSH hardening"
SSHC=/etc/ssh/sshd_config
if [ -f "$SSHC" ]; then
  run "cp $SSHC ${SSHC}.backup.\$(date +%Y%m%d) 2>/dev/null || true"
  # Antes de desactivar password: verificar que HAY una llave autorizada
  if [ -s /root/.ssh/authorized_keys ] || $DRY; then
    run "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSHC"
    run "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' $SSHC"
    run "systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true"
    log "SSH: solo llaves (password deshabilitado)."
  else
    warn "NO hay llaves en /root/.ssh/authorized_keys: se OMITE deshabilitar password"
    warn "(te quedarías fuera). Agrega tu llave pública y re-ejecuta."
  fi
fi

step "5/7 fail2ban"
run "apt-get install -y -qq fail2ban"
if [ ! -f /etc/fail2ban/jail.local ] && ! $DRY; then
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
fi
run "systemctl enable --now fail2ban"
log "fail2ban activo (SSH protegido)."

step "6/7 Swap 4G + swappiness"
if ! swapon --show | grep -q .; then
  run "fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
  run "grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  log "Swap 4G creado."
else
  log "Swap ya existe."
fi
run "sysctl -w vm.swappiness=10 >/dev/null"
run "grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf"
log "swappiness=10 (swap solo como colchón)."

step "7/7 Docker + EasyPanel"
if ! command -v docker >/dev/null 2>&1; then
  run "curl -fsSL https://get.docker.com | sh"
  log "Docker instalado."
else
  log "Docker ya presente: $(docker --version 2>/dev/null | head -1)"
fi
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q easypanel; then
  info "Instalando EasyPanel..."
  run "docker run --rm -v /etc/easypanel:/etc/easypanel -v /var/run/docker.sock:/var/run/docker.sock:ro easypanel/easypanel setup"
  log "EasyPanel instalado."
else
  log "EasyPanel ya corriendo."
fi

echo
log "SERVER LISTO. Siguientes pasos (ver docs/FASE-B.md):"
echo "  1. Accede a EasyPanel:  ssh -L 3000:localhost:3000 root@<IP>  ->  http://localhost:3000"
echo "  2. Crea el proyecto y los servicios usando stack-export/ del server viejo"
echo "  3. Clona este repo, configura .env (DST_*) y restaura desde B2"
