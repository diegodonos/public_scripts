#!/bin/bash

echo "actualizar ubuntu"

echo "Set disable_coredump false" >> /etc/sudo.conf

sudo apt update && apt upgrade -y

echo "paquete de requisitos"

sudo apt-get install  curl apt-transport-https ca-certificates software-properties-common -y

echo "agregar repositorios"

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

sudo apt update

sudo apt install docker-ce -y

echo "configurar docker"
sudo groupadd docker
sudo usermod -aG docker $USER

echo "instalar docker-compose"

sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose


sudo chmod +x /usr/local/bin/docker-compose

sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

echo "instalando portainer"

docker volume create portainer_data

docker run -d -p 8000:8000 -p 9000:9000 --name=portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce

