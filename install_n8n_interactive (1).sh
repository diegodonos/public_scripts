#!/bin/bash

echo "🛠️ Instalador interactivo de n8n (modo systemd + Node.js)"
echo "------------------------------------------------------------"

# Preguntar por el dominio o webhook URL
read -p "🔧 Introduce el dominio o URL del webhook [por defecto: http://localhost:5678]: " webhook
webhook=${webhook:-http://localhost:5678}

# Extraer solo el hostname del webhook para N8N_HOST
n8n_host=$(echo "$webhook" | sed -E 's#https?://##' | cut -d/ -f1)

# Generar claves seguras por defecto
N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
N8N_USER_MANAGEMENT_JWT_SECRET=$(openssl rand -hex 16)

# Crear carpeta para .env
echo "📁 Creando /etc/n8n y archivo de entorno..."
sudo mkdir -p /etc/n8n

cat <<EOF | sudo tee /etc/n8n/.env > /dev/null
N8N_DISABLE_PRODUCTION_MAIN_WARNING=true
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_EDITOR_BASE_URL=${webhook}
N8N_DIAGNOSTICS_ENABLED=false
N8N_HOST=${n8n_host}
N8N_RUNNERS_ENABLED=true
N8N_PERSONALIZATION_ENABLED=false
N8N_CORS_ALLOW_ORIGIN=${webhook}
N8N_SECURE_COOKIE=false
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_USER_MANAGEMENT_JWT_SECRET}
WEBHOOK_URL=${webhook}
EOF

echo "✅ Archivo .env creado correctamente."

# Confirmar si n8n está instalado
if ! command -v n8n &> /dev/null; then
  echo "⏳ Instalando n8n globalmente vía npm..."
  sudo npm install -g n8n
else
  echo "✅ n8n ya está instalado."
fi

# Crear archivo systemd con variables directas
echo "⚙️ Generando servicio systemd para n8n..."

cat <<EOF | sudo tee /etc/systemd/system/n8n.service > /dev/null
[Unit]
Description=n8n automation
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/n8n/.env
ExecStart=$(which n8n) start
Restart=on-failure
WorkingDirectory=/root

# Variables de localización
Environment=GENERIC_TIMEZONE=Europe/Madrid
Environment=N8N_DEFAULT_LOCALE=es

[Install]
WantedBy=multi-user.target
EOF

# Recargar, habilitar e iniciar el servicio
echo "🔄 Recargando y activando el servicio..."
sudo systemctl daemon-reload
sudo systemctl enable n8n
sudo systemctl restart n8n

echo "🎉 Instalación completada."
echo "🌐 Accede a n8n desde: ${webhook}"
