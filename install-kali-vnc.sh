#!/usr/bin/env bash
set -euo pipefail

### === Params / Detect user ===
TARGET_USER="${TARGET_USER_OVERRIDE:-${SUDO_USER:-${USER:-kali}}}"
HOME_DIR="$(eval echo "~$TARGET_USER")"
DISPLAY_NUMBER="${DISPLAY_NUMBER:-1}"
PORT=$((5900 + DISPLAY_NUMBER))

echo ">>> Configurando VNC para usuario: $TARGET_USER (home: $HOME_DIR), display :$DISPLAY_NUMBER (puerto $PORT)"

### === 0) Repos: fijar mirror estable y limpiar índices ===
echo ">>> Ajustando repos a kali.download y limpiando índices APT…"
tee /etc/apt/sources.list >/dev/null <<'EOF'
deb https://kali.download/kali kali-rolling main contrib non-free non-free-firmware
EOF

apt clean
rm -rf /var/lib/apt/lists/*

### Opciones APT robustas: IPv4 + reintentos + sin caché intermedia
APT_OPTS=(
  "-o" "Acquire::ForceIPv4=true"
  "-o" "Acquire::Retries=5"
  "-o" "Acquire::http::No-Cache=true"
  "-o" "Acquire::https::No-Cache=true"
)

echo ">>> apt update (IPv4 + reintentos)…"
apt "${APT_OPTS[@]}" update

### === 1) Paquetes necesarios (XFCE mínimo + TigerVNC) ===
echo ">>> Instalando XFCE mínimo + TigerVNC…"
DEBIAN_FRONTEND=noninteractive apt "${APT_OPTS[@]}" install -y \
  xfce4 xfce4-terminal thunar tigervnc-standalone-server tigervnc-common wget

### === 2) Directorio y xstartup ===
VNC_DIR="$HOME_DIR/.vnc"
mkdir -p "$VNC_DIR"
chown "$TARGET_USER:$TARGET_USER" "$VNC_DIR"
chmod 700 "$VNC_DIR"

cat > "$VNC_DIR/xstartup" <<'EOF'
#!/bin/sh
xrdb $HOME/.Xresources 2>/dev/null || true
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
startxfce4 &
EOF

chown "$TARGET_USER:$TARGET_USER" "$VNC_DIR/xstartup"
chmod +x "$VNC_DIR/xstartup"

### === 3) Contraseña VNC: usar VNC_PASS o pedirla ===
if [ -z "${VNC_PASS:-}" ]; then
  echo ">>> No se encontró VNC_PASS; te pediré la contraseña de forma segura."
  read -r -s -p "Introduce contraseña VNC: " VNC_PASS; echo
  if [ -z "$VNC_PASS" ]; then
    echo "ERROR: la contraseña VNC no puede estar vacía."
    exit 1
  fi
fi

# Guardar passwd en formato TigerVNC
echo ">>> Guardando contraseña VNC…"
# vncpasswd -f lee de stdin; usamos printf y redirigimos al fichero passwd
printf "%s\n" "$VNC_PASS" | vncpasswd -f > "$VNC_DIR/passwd"
chown "$TARGET_USER:$TARGET_USER" "$VNC_DIR/passwd"
chmod 600 "$VNC_DIR/passwd"

### === 4) Servicio systemd ===
SERVICE_PATH="/etc/systemd/system/vncserver@.service"
echo ">>> Creando servicio systemd en $SERVICE_PATH…"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=TigerVNC server for display %i
After=network.target

[Service]
Type=forking
User=$TARGET_USER
PAMName=login
PIDFile=$HOME_DIR/.vnc/%H:%i.pid
Environment=USER=$TARGET_USER HOME=$HOME_DIR
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || true
ExecStart=/usr/bin/vncserver -geometry 1366x768 -depth 24 :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$SERVICE_PATH"

### === 5) Habilitar y arrancar ===
echo ">>> Habilitando e iniciando vncserver@${DISPLAY_NUMBER}.service…"
systemctl daemon-reload
systemctl enable --now "vncserver@${DISPLAY_NUMBER}.service"

### === 6) Info final ===
cat <<EOF

========================================================
✅ VNC instalado y en marcha

Usuario:       $TARGET_USER
Display:       :$DISPLAY_NUMBER
Puerto TCP:    $PORT

Conexión segura (recomendada) desde tu Mac:
  ssh -L 5901:localhost:$PORT $TARGET_USER@<IP-DE-KALI>
  Luego conecta con tu cliente VNC a: vnc://localhost:5901

Conexión directa (menos segura):
  vnc://<IP-DE-KALI>:$PORT

Logs:
  sudo journalctl -u vncserver@${DISPLAY_NUMBER}.service -f

Reiniciar/parar:
  sudo systemctl restart vncserver@${DISPLAY_NUMBER}.service
  sudo systemctl stop vncserver@${DISPLAY_NUMBER}.service
========================================================
EOF
