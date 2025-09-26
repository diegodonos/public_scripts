#!/usr/bin/env bash
# install-pve9-trixie-onepass.sh
# Proxmox VE 9 sobre Debian 13 (Trixie) en una sola pasada:
#  - Repo + keyring PVE (no-subscription)
#  - proxmox-default-kernel + proxmox-ve + open-iscsi + ifupdown2 (+ chrony opcional)
#  - Hostname/FQDN + /etc/hosts
#  - Configuración de red interactiva con vmbr0 (DHCP o estática)
#  - Desactivar repo enterprise, quitar banner suscripción (community-scripts; fallback local)
#  - Eliminar kernels Debian + os-prober
#  - Reboot final (único)

set -euo pipefail

log(){ echo -e "\e[1;32m[+] $*\e[0m"; }
warn(){ echo -e "\e[1;33m[!] $*\e[0m"; }
err(){ echo -e "\e[1;31m[ERROR] $*\e[0m"; }
die(){ err "$*"; exit 1; }

require_root(){ [[ "$(id -u)" -eq 0 ]] || die "Ejecuta como root."; }

check_env(){
  . /etc/os-release
  [[ "${ID}" == "debian" ]] || die "Este script es solo para Debian."
  [[ "${VERSION_CODENAME}" == "trixie" ]] || die "Necesitas Debian 13 (trixie); detectado: ${VERSION_CODENAME}."
  dpkg --print-architecture | grep -q '^amd64$' || die "Arquitectura no soportada: $(dpkg --print-architecture)."
}

ask_inputs(){
  read -rp "➡️  FQDN del host (ej. pve.hirusec.lan): " FQDN
  [[ -n "$FQDN" ]] || die "El FQDN es obligatorio."

  read -rp "➡️  Instalar Chrony (NTP)? [s/N]: " yn
  [[ "${yn,,}" == "s" ]] && INSTALL_CHRONY=1 || INSTALL_CHRONY=0

  read -rp "➡️  Aplicar optimizaciones (no-subscription, quitar banner, ajustes APT)? [S/n]: " yn2
  [[ "${yn2,,}" == "n" ]] && RUN_TWEAKS=0 || RUN_TWEAKS=1
}

detect_ip(){
  HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -n "${HOST_IP:-}" ]] || HOST_IP="(definirás IP en la red)"
}

ensure_hostname(){
  local curhn
  curhn="$(hostname -f 2>/dev/null || hostname)"
  if ! [[ "$curhn" == *.* ]]; then
    hostnamectl set-hostname "$FQDN"
  else
    FQDN="$curhn"
  fi
}

fix_hosts(){
  local short="${FQDN%%.*}"
  sed -i -E "s/^127\.0\.1\.1\s+.*/# &/" /etc/hosts || true
  if [[ "$HOST_IP" != "(definirás IP en la red)" ]]; then
    if grep -qE "^\s*${HOST_IP//./\\.}\s" /etc/hosts; then
      sed -i -E "s|^(\s*${HOST_IP//./\\.}\s+).*|\1${FQDN} ${short}|" /etc/hosts
    else
      printf "%s\t%s %s\n" "$HOST_IP" "$FQDN" "$short" >> /etc/hosts
    fi
  fi
  grep -q "^::1" /etc/hosts || cat >>/etc/hosts <<'EOF'
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
}

apt_base_tuning(){
  mkdir -p /etc/apt/apt.conf.d
  cat >/etc/apt/apt.conf.d/99hirusec-apt.conf <<'EOF'
Acquire::Retries "5";
APT::Get::Assume-Yes "true";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Dpkg::Use-Pty "0";
EOF
  apt -y update || true
}

add_pve_repo(){
  log "Añadiendo repo Proxmox VE (no-subscription) y keyring…"
  curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o /usr/share/keyrings/proxmox-archive-keyring.gpg
  cat >/etc/apt/sources.list.d/pve-install-repo.sources <<'EOL'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL
  apt -y update
  apt -y full-upgrade
}

secure_boot_warn(){
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot habilitado: el kernel de Proxmox podría no arrancar. Considera deshabilitarlo en la UEFI."
  fi
}

preseed_postfix(){
  echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
  echo "postfix postfix/mailname string $FQDN" | debconf-set-selections
}

install_all_packages(){
  log "Instalando kernel y paquetes base de Proxmox VE…"
  preseed_postfix
  local extras="open-iscsi ifupdown2"
  [[ "${INSTALL_CHRONY:-0}" -eq 1 ]] && extras="$extras chrony"
  DEBIAN_FRONTEND=noninteractive apt -y install proxmox-default-kernel proxmox-ve postfix $extras
}

remove_debian_kernel_and_osprober(){
  log "Eliminando kernels Debian genéricos y os-prober…"
  apt -y remove linux-image-amd64 'linux-image-6.*-amd64' os-prober || true
  update-grub || true
}

disable_enterprise_and_enable_nosub(){
  for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    [[ -f "$f" ]] && sed -i 's/^\s*deb /# &/' "$f" || true
  done
  apt -y update || true
}

apply_community_postinstall(){
  if [[ "${RUN_TWEAKS:-1}" -eq 1 ]]; then
    log "Aplicando optimizaciones community-scripts (post-pve-install.sh)…"
    if ! bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"; then
      warn "No se pudo ejecutar community-scripts. Aplicando fallback local para banner…"
      nag_remove_fallback
    fi
  fi
}

nag_remove_fallback(){
  local file="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%s)"
    sed -i -E \
      -e "s/(data\.status !== 'Active')/false/" \
      -e "s/gettext\('No valid subscription'\)/'Subscription'/" \
      "$file" || true
    systemctl restart pveproxy || true
  fi
}

configure_network(){
  log "Configuración de red para Proxmox (vmbr0)…"

  # Detectar primera NIC física razonable
  NIC="$(ls -1 /sys/class/net | grep -E '^(en|eth)' | head -n1 || true)"
  [[ -n "$NIC" ]] || die "No se detectó interfaz física. Configura /etc/network/interfaces manualmente."

  echo "Interfaz detectada: $NIC"
  read -rp "➡️  ¿Configurar red con DHCP? [S/n]: " yn
  if [[ "${yn,,}" == "n" ]]; then
    read -rp "IP estática (ej: 192.168.1.100): " IPADDR
    read -rp "Prefijo CIDR (ej: 24): " PREFIX
    read -rp "Gateway (ej: 192.168.1.1): " GATEWAY
    read -rp "DNS (ej: 1.1.1.1 8.8.8.8): " DNS
    [[ -n "$IPADDR" && -n "$PREFIX" && -n "$GATEWAY" ]] || die "Datos de red incompletos."

    cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $NIC
iface $NIC inet manual

auto vmbr0
iface vmbr0 inet static
    address $IPADDR/$PREFIX
    gateway $GATEWAY
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
    dns-nameservers $DNS
EOF
  else
    cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $NIC
iface $NIC inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
EOF
  fi

  log "Archivo /etc/network/interfaces generado:"
  sed -n '1,200p' /etc/network/interfaces

  # Aplica en caliente si es posible (no interrumpe si estás por consola)
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a || true
  fi
}

final_summary(){
  echo
  log "Instalación completada. Reiniciando…"
  echo
  echo "Acceso previsto tras reinicio:"
  echo "  URL   : https://${HOST_IP:-<tu-IP>}:8006 (o la IP configurada)"
  echo "  Login : root  | Realm: PAM"
  echo
}

main(){
  require_root
  check_env
  ask_inputs
  detect_ip
  ensure_hostname
  fix_hosts
  apt_base_tuning
  add_pve_repo
  secure_boot_warn
  install_all_packages
  remove_debian_kernel_and_osprober
  disable_enterprise_and_enable_nosub
  apply_community_postinstall
  configure_network
  final_summary
  sleep 2
  systemctl reboot
}

main "$@"
