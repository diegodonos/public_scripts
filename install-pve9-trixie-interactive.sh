#!/usr/bin/env bash
# install-pve9-trixie-interactive.sh
# Proxmox VE 9 sobre Debian 13 (Trixie) + tweaks post-instalación (no-subscription, quitar banner, etc.)
set -euo pipefail

log(){ echo -e "\e[1;32m[+] $*\e[0m"; }
warn(){ echo -e "\e[1;33m[!] $*\e[0m"; }
die(){ echo -e "\e[1;31m[ERROR] $*\e[0m"; exit 1; }

require_root(){ [[ "$(id -u)" -eq 0 ]] || die "Ejecuta como root."; }

check_debian_version(){
  . /etc/os-release
  [[ "${ID}" == "debian" ]] || die "Este script es solo para Debian."
  [[ "${VERSION_CODENAME}" == "trixie" ]] || die "Necesitas Debian 13 (trixie)."
  dpkg --print-architecture | grep -q amd64 || die "Arquitectura no soportada: $(dpkg --print-architecture)."
}

ask_inputs(){
  read -rp "➡️  FQDN del host (ej. pve.hirusec.lan): " FQDN_DEFAULT
  [[ -n "$FQDN_DEFAULT" ]] || die "El FQDN es obligatorio."
  read -rp "➡️  IP estática del host (Enter para autodetectar): " IPV4_OVERRIDE
  read -rp "➡️  Instalar Chrony (NTP)? [s/N]: " yn
  [[ "${yn,,}" == "s" ]] && INSTALL_CHRONY=1 || INSTALL_CHRONY=0
  read -rp "➡️  Reinicio automático tras kernel PVE? [S/n]: " yn2
  [[ "${yn2,,}" == "n" ]] && NO_REBOOT=1 || NO_REBOOT=0
  read -rp "➡️  Aplicar optimizaciones: repo no-subscription, quitar banner, ajustes APT? [S/n]: " yn3
  [[ "${yn3,,}" == "n" ]] && RUN_TWEAKS=0 || RUN_TWEAKS=1
}

detect_ip(){
  if [[ -n "${IPV4_OVERRIDE:-}" ]]; then
    HOST_IP="$IPV4_OVERRIDE"
  else
    HOST_IP="$(ip -4 route get 1.1.1.1 | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  [[ -n "${HOST_IP:-}" ]] || die "No se pudo autodetectar IP. Define manualmente."
}

ensure_hostname(){
  local curhn fqdn="$FQDN_DEFAULT"
  curhn="$(hostname -f 2>/dev/null || hostname)"
  if ! [[ "$curhn" == *.* ]]; then
    hostnamectl set-hostname "$fqdn"
  else
    fqdn="$curhn"
  fi
  echo "$fqdn"
}

fix_hosts(){
  local fqdn="$1" ip="$2" short="${fqdn%%.*}"
  sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1\tlocalhost.localdomain localhost/" /etc/hosts || true
  if grep -qE "^\s*${ip}\s" /etc/hosts; then
    sed -i -E "s|^(\s*${ip}\s+).*|\1${fqdn} ${short}|" /etc/hosts
  else
    printf "%s\t%s %s\n" "$ip" "$fqdn" "$short" >> /etc/hosts
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

add_pve_repo_trixie(){
  log "Añadiendo repo Proxmox VE (no-subscription, deb822)…"
  cat >/etc/apt/sources.list.d/pve-install-repo.sources <<'EOL'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL
  curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o /usr/share/keyrings/proxmox-archive-keyring.gpg
  apt -y update
  apt -y full-upgrade
}

install_kernel(){ log "Instalando kernel Proxmox…"; apt -y install proxmox-default-kernel; }

secure_boot_warn(){
  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot habilitado: puede impedir el arranque con kernel Proxmox."
  fi
}

install_core(){
  log "Instalando paquetes base Proxmox VE…"
  local extra_ntp=""
  [[ "${INSTALL_CHRONY:-0}" == "1" ]] && extra_ntp="chrony"
  DEBIAN_FRONTEND=noninteractive apt -y install proxmox-ve postfix open-iscsi ifupdown2 $extra_ntp
}

remove_debian_kernel(){
  log "Eliminando kernels Debian genéricos…"
  apt -y remove linux-image-amd64 'linux-image-6.12*' 'linux-image-6.13*' || true
  update-grub || true
}

remove_os_prober(){ apt -y remove os-prober || true; }

disable_enterprise_repo(){
  # Desactiva repos enterprise y activa no-subscription para PVE y Ceph si existieran
  for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    [[ -f "$f" ]] && sed -i 's|^deb |# deb |' "$f" || true
  done
  # Añade ceph no-sub (opcional) si se usa ceph más adelante
  cat >/etc/apt/sources.list.d/ceph-no-subscription.sources <<'EOL'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-quincy
Suites: bookworm
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL
  apt -y update || true
}

apply_community_postinstall(){
  # Ejecuta el post-install oficial de community-scripts (incluye: no-subscription, quitar banner, etc.)
  log "Aplicando optimizaciones community-scripts (post-pve-install.sh)…"
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
}

nag_remove_fallback(){
  # Fallback por si cambia el script upstream o sin internet: parcheo del banner
  # Intenta localizar proxmoxlib.js y neutralizar el check de suscripción
  local file
  file="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%s)"
    sed -i -E \
      -e "s/(Ext\.Msg\.show\(\{.*?title: )gettext\('No valid subscription'\)/\1'Subscription'/" \
      -e "s/(data\.status !== 'Active')/false/" \
      "$file" || true
    systemctl restart pveproxy || true
  fi
}

post_tweaks(){
  disable_enterprise_repo
  apt -y update
  # community script (preferente). Si falla, aplica fallback local.
  if ! apply_community_postinstall; then
    warn "community-scripts no disponible. Aplicando fallback local…"
    nag_remove_fallback
  fi
  # Ajustes finales
  apt -y dist-upgrade || true
  systemctl restart pveproxy || true
}

main_phase1(){
  require_root
  check_debian_version
  ask_inputs
  detect_ip
  local fqdn; fqdn="$(ensure_hostname)"
  log "Configurando host: ${fqdn}  | IP: ${HOST_IP}"
  fix_hosts "$fqdn" "$HOST_IP"
  apt_base_tuning
  add_pve_repo_trixie
  secure_boot_warn
  install_kernel

  if [[ "${NO_REBOOT:-0}" -eq 0 ]]; then
    log "Reiniciando para cargar kernel Proxmox…"
    sleep 2
    systemctl reboot
    exit 0
  else
    warn "Reinicio omitido. Reinicia manualmente y vuelve a ejecutar el script."
  fi
}

phase2_postboot(){
  if uname -r | grep -vq 'pve'; then
    warn "Kernel activo no es PVE ($(uname -r)). Reinicia con kernel PVE y reejecuta."
    exit 0
  fi
  install_core
  remove_debian_kernel
  remove_os_prober
  [[ "${RUN_TWEAKS:-1}" -eq 1 ]] && post_tweaks || log "Saltando optimizaciones post-instalación."
  log "✅ Proxmox VE listo."
  echo "URL: https://$(hostname -I | awk '{print $1}'):8006"
  echo "Login: root @ PAM"
}

if uname -r | grep -q 'pve'; then
  phase2_postboot
else
  main_phase1
fi
