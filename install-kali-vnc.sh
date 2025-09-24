#!/usr/bin/env bash
set -euo pipefail

# Detectar usuario objetivo (si script lanzado con sudo, usa SUDO_USER; si no, usa $USER)
TARGET_USER="${SUDO_USER:-${USER:-kali}}"
HOME_DIR=$(eval echo "~$TARGET_USER")

# Parámetros
DISPLAY_NUMBER=1
PORT=$((5900 + DISPLAY_NUMBER))
VNC_PASS="${VNC_PASS:-}"

if [ -z "$VNC_PASS" ]; then
  echo "ERROR: debes exportar la variable VNC_PASS antes de ejecutar este script."
  echo "Ejemplo: export VNC_PASS='MiVNCsuperSecreta!' && sudo bash install-kali-vnc.sh"
  exit 1
fi

echo "Instalando VNC para el usuario: $TARGET_USER (home: $HOME_DIR) en display :$DISPLAY_NUMBER (puerto $PORT)"

# 1) Actualizar e instalar paquetes
apt update
DEBIAN_FRONTEND=noninteractive apt install -y xfce4 xfce4-goodies tigervnc-standalone-server tigervnc-common wget

# 2) Crear directorio .vnc y fichero xstartup
VNC_DIR="$HOME_DIR/.vnc"
mkdir -p "$VNC_DIR"
chown "$TARGET_USER":"$TARGET_USER" "$VNC_DIR"
chmod 700 "$VNC_DIR"

cat > "$VNC_DIR/xstartup" <<'EOF'
#!/bin/sh
# xstartup para XFCE
xrdb $HOME/.Xresources 2>/dev/null || true
# evitar arranques múltiples
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
startxfce4 &
EOF

chown "$TARGET_USER":"$TARGET_USER" "$VNC_DIR/xstartup"
chmod +x "$VNC_DIR/xstartup"

# 3) Crear la contraseña VNC no interactiva
# Usamos vncpasswd -f para generar el formato correcto y guardarlo en ~/.vnc/passwd
# NOTA: TigerVNC codifica la contraseña en formato binario
printf "%s\n%s\n" "$VNC_PASS" "$VNC_PASS" | vncpasswd -f > "$VNC_DIR/passwd"
chown "$TARGET_USER":"$TARGET_USER" "$VNC_DIR/passwd"
chmod 600 "$VNC_DIR/passwd"

# 4) Crear unit systemd para vncserver@:<display>.service
SERVICE_PATH="/etc/systemd/system/vncserver@.service"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=TigerVNC server for display %i
After=network.target

[Service]
Type=forking
# Usuario que ejecuta el servidor VNC
User=$TARGET_USER
PAMName=login
PIDFile=$HOME_DIR/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || true
ExecStart=/usr/bin/vncserver -geometry 1366x768 -depth 24 :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_PATH"

# 5) Recargar systemd y habilitar servicio en display 1
systemctl daemon-reload
systemctl enable --now "vncserver@${DISPLAY_NUMBER}.service"

echo
echo "-----"
echo "VNC instalado y servicio iniciado."
echo "Usuario: $TARGET_USER"
echo "Display: :$DISPLAY_NUMBER  -> puerto TCP $PORT"
echo "Directo (no recomendado sin tunel): vnc://<IP-DE-KALI>:$PORT"
echo
echo "Conexión segura recomendada (túnel SSH desde Mac):"
echo "  En el Mac, ejecuta:"
echo "    ssh -L 5901:localhost:$PORT $TARGET_USER@<IP-DE-KALI>"
echo "  Luego abre en el Mac el cliente VNC y conéctate a: vnc://localhost:5901"
echo
echo "Si prefieres conectar directamente (menos seguro):"
echo "  abre tu cliente VNC y conéctate a: <IP-DE-KALI>:$PORT  (o vnc://<IP-DE-KALI>:$PORT)"
echo
echo "Para ver logs: sudo journalctl -u vncserver@${DISPLAY_NUMBER}.service -f"
echo "Para reiniciar: sudo systemctl restart vncserver@${DISPLAY_NUMBER}.service"
echo "Para parar: sudo systemctl stop vncserver@${DISPLAY_NUMBER}.service"
echo "-----"
