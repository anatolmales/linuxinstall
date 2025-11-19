#!/bin/bash
set -e

### Обновление
apt update && apt upgrade -y
apt install -y mc curl wget sudo ca-certificates openssl apache2-utils

### Bash/Tmux
curl -sL https://raw.githubusercontent.com/anatolmales/linuxinstall/main/bash_History.sh | bash
wget -O /etc/tmux.conf https://raw.githubusercontent.com/anatolmales/linuxinstall/main/tmux.conf

### Docker
sudo mkdir -p /etc/apt/keyrings/
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

DISTRO=$( . /etc/os-release && echo $VERSION_CODENAME )

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $DISTRO
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

### Директория
mkdir -p /opt/docker/

### Скачивание compose
wget -O /opt/docker/docker-compose.yml \
  https://raw.githubusercontent.com/anatolmales/linuxinstall/refs/heads/main/docker-compose.yml

COMPOSE="/opt/docker/docker-compose.yml"

### Определяем внешний IP
IP=$(curl -s ifconfig.me)
if [ -z "$IP" ]; then
    echo "Ошибка: не удалось определить внешний IP"
    exit 1
fi

echo "Найден внешний IP: $IP"

### ---------- ВВОД ПАРОЛЯ (устойчивый) ----------
attempts=0
MAX=5

while [ $attempts -lt $MAX ]; do
    attempts=$((attempts+1))

    printf "Введите пароль: "
    stty -echo
    read PASSWORD
    stty echo
    echo

    printf "Подтвердите пароль: "
    stty -echo
    read PASSWORD2
    stty echo
    echo

    # удаляем '\r'
    PASSWORD=$(printf "%s" "$PASSWORD" | tr -d '\r')
    PASSWORD2=$(printf "%s" "$PASSWORD2" | tr -d '\r')

    if [ "$PASSWORD" = "$PASSWORD2" ] && [ -n "$PASSWORD" ]; then
        break
    fi

    echo "Пароли не совпадают (попытка $attempts/$MAX)"
done

if [ "$PASSWORD" != "$PASSWORD2" ]; then
    echo "Ошибка: пароль не подтверждён"
    exit 1
fi
### ---------- КОНЕЦ БЛОКА ПАРОЛЯ ----------


### Генерация bcrypt
BCRYPT_HASH=$(htpasswd -bnB admin "$PASSWORD" | cut -d: -f2)

echo "bcrypt HASH успешно создан"

### Подстановка IP
escaped_ip=$(printf '%s\n' "$IP" | sed 's/[\/&]/\\&/g')
sed -i "s/IPADDRESS/$escaped_ip/g" "$COMPOSE"

### Подстановка HASH (без Perl)
escaped_hash=$(printf '%s\n' "$BCRYPT_HASH" | sed 's/[\/&]/\\&/g')
sed -i "s|PASSWORD_HASH=.*|PASSWORD_HASH=$escaped_hash|" "$COMPOSE"

### Docker network
if ! docker network ls | grep -q "proxy"; then
    docker network create proxy
fi

### Compose up
docker compose --project-directory /opt/docker pull
docker compose --project-directory /opt/docker up -d

### Сертификат
CERT_DIR="/opt/docker/letsencrypt/certs"
mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -days 1000 \
  -newkey rsa:2048 \
  -keyout "$CERT_DIR/privkey.pem" \
  -out "$CERT_DIR/cert.pem" \
  -subj "/CN=$IP" \
  -addext "subjectAltName=IP:$IP"

chmod 600 "$CERT_DIR/privkey.pem"

echo "=== Установка завершена успешно ==="
