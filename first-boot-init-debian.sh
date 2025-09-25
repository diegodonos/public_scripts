#!/usr/bin/env bash
# first-boot-init.sh (v1.6)
# HirusecOS · Primera configuración para Debian 13 (Trixie)
# - Desactiva suspensión/hibernación *ANTES* de cualquier operación
# - Normaliza repos APT (trixie / updates / security)
# - Instala utilidades base (con fallback de disponibilidad)
# - Configura locale/TZ, ajusta journald, SSH y UFW (opcional)

set -euo pipefail
log(){ echo -e "\e[1;32m[+] $*\e[0m"; }
warn(){ echo -e "\e[1;33m[!] $*\e[0m"; }
die(){ echo -e "\e[1;31m[ERROR] $*\e[0m"; exit 1; }
require_root(){ [[ "$(id -u)" -eq 0 ]] || die "Ejecuta como root."; }

check_debian(){ . /etc/os-release; [[ "$ID" == "debian" ]] || die "Solo Debian."; }

ask_inputs(){
  read -rp "➡️  ¿Configurar locale a es_ES.UTF-8 (añadiendo en_US.UTF-8)? [S/n]: " yn1; [[ "${yn1,,}" == "n" ]] && CFG_LOCALE=0 || CFG_LOCALE=1
  read -rp "➡️  ¿Ajustar zona horaria a Europe/Madrid? [S/n]: " yn2; [[ "${yn2,,}" == "n" ]] && CFG_TZ=0 || CFG_TZ=1
  read -rp "➡️  ¿Instalar y habilitar OpenSSH Server? [S/n]: " yn3; [[ "${yn3,,}" == "n" ]] && INST_SSH=0 || INST_SSH=1
  read -rp "➡️  ¿Instalar y configurar UFW (permitir 22/tcp)? [S/n]: " yn4; [[ "${yn4,,}" == "n" ]] && INST_UFW=0 || INST_UFW=1
  read -rp "➡️  ¿Instalar Chrony (NTP)? [s/N]: " yn5; [[ "${yn5,,}" == "s" ]] && INST_CHRONY=1 || INST_CHRONY=0
}

disable_sleep(){
  log "Deshabilitando suspensión/hibernación (aplicado primero)…"
  cat > /etc/systemd/sleep.conf <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
  if grep -q '^HandleLidSwitch=' /etc/systemd/logind.conf; then
    sed -i 's/^HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
  else
    echo "HandleLidSwitch=ignore" >> /etc/systemd/logind.conf
  fi
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target || true
  systemctl restart systemd-logind || true
}

normalize_apt_sources(){
  . /etc/os-release
  log "Normalizando /etc/apt/sources.list…"
  cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free-firmware
deb http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free-firmware
EOF
  mkdir -p /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/99hirusec-apt.conf <<'EOF'
Acquire::Retries "5";
APT::Get::Assume-Yes "true";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Dpkg::Use-Pty "0";
EOF
  apt update
  apt -y full-upgrade
}

pkg_available(){ apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}' | grep -vq "(none)"; }

install_basics(){
  log "Instalando utilidades base (según disponibilidad)…"
  # Fallback para software-properties
  SPKG=""
  if pkg_available software-properties-common; then SPKG="software-properties-common";
  elif pkg_available python3-software-properties; then SPKG="python3-software-properties"; fi

  PKGS=(
    ca-certificates curl wget gnupg lsb-release
    locales tzdata sudo vim nano htop tmux tree git rsync jq bc
    unzip zip tar bzip2 xz-utils p7zip-full
    net-tools iproute2 iputils-ping traceroute mtr-tiny ethtool socat
    bind9-dnsutils nmap ncat
    lsof strace pciutils usbutils lshw smartmontools nvme-cli hdparm
    parted gdisk lvm2 mdadm
    openssl python3 python3-pip pipx
  )
  [[ -n "${SPKG}" ]] && PKGS+=("$SPKG")
  [[ "${INST_CHRONY:-0}" -eq 1 ]] && PKGS+=("chrony")

  TO_INSTALL=()
  for p in "${PKGS[@]}"; do
    if pkg_available "$p"; then TO_INSTALL+=("$p"); else warn "Paquete no disponible: $p (omitido)"; fi
  done
  ((${#TO_INSTALL[@]})) && apt -y install "${TO_INSTALL[@]}" || warn "Nada que instalar (revisa repos)."
}

configure_locale_tz(){
  [[ "${CFG_LOCALE:-1}" -eq 1 ]] && {
    log "Configurando locales…"
    sed -i -E 's/^#?(es_ES\.UTF-8)/\1/' /etc/locale.gen
    sed -i -E 's/^#?(en_US\.UTF-8)/\1/' /etc/locale.gen
    locale-gen
    update-locale LANG=es_ES.UTF-8 LC_TIME=es_ES.UTF-8
  }
  [[ "${CFG_TZ:-1}" -eq 1 ]] && { log "Zona horaria Europe/Madrid…"; timedatectl set-timezone Europe/Madrid; }
}

journald_limits(){
  log "Journal persistente (1G)…"
  mkdir -p /var/log/journal
  sed -i -E 's/^#?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf || echo "Storage=persistent" >> /etc/systemd/journald.conf
  if grep -q '^SystemMaxUse=' /etc/systemd/journald.conf; then
    sed -i 's/^SystemMaxUse=.*/SystemMaxUse=1G/' /etc/systemd/journald.conf
  else
    echo "SystemMaxUse=1G" >> /etc/systemd/journald.conf
  fi
  systemctl restart systemd-journald
}

ssh_setup(){
  [[ "${INST_SSH:-1}" -eq 1 ]] && {
    log "Instalando y habilitando OpenSSH…"
    apt -y install openssh-server
    systemctl enable --now ssh
    sed -i -E 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i -E 's/^#?PermitRootLogin\s+.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl reload ssh || true
  }
}

ufw_setup(){
  [[ "${INST_UFW:-1}" -eq 1 ]] && {
    log "Configurando UFW…"
    apt -y install ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    yes | ufw enable
    ufw status verbose || true
  }
}

finish(){
  log "Limpieza…"
  [[ "${INST_CHRONY:-0}" -eq 0 ]] && apt -y purge chrony || true
  apt -y autoremove
  apt -y autoclean
  echo
  log "✅ Primera configuración completada."
  echo "Curl: $(command -v curl || echo no-encontrado)"
  echo "SSH:  $(systemctl is-enabled ssh 2>/dev/null || echo deshabilitado)"
  echo "UFW:  $(command -v ufw >/dev/null && ufw status | head -n1 || echo no-instalado)"
}

main(){
  require_root
  check_debian
  ask_inputs
  disable_sleep             # <- PRIMERO
  normalize_apt_sources
  install_basics
  configure_locale_tz
  journald_limits
  ssh_setup
  ufw_setup
  finish
}
main "$@"
