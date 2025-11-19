#!/usr/bin/env bash
# install_vps.sh
# Полный инсталляционный скрипт: ставит docker, загружает docker-compose.yml, подставляет IP и bcrypt HASH,
# генерирует самоподписанный сертификат с SAN=IP, запускает контейнеры.
set -euo pipefail
IFS=$'\n\t'

echo "=== Начало установки VPS стека ==="

# ---- Настройки ----
GIT_RAW_URL="https://raw.githubusercontent.com/anatolmales/linuxinstall/main"
COMPOSE_URL="$GIT_RAW_URL/docker-compose.yml"
INSTALL_PATH="/opt/docker"
COMPOSE_FILE="$INSTALL_PATH/docker-compose.yml"
CERT_DIR="$INSTALL_PATH/letsencrypt/certs"
PROJECT_DIR="$INSTALL_PATH"
CURL_LINK="curl -sL https://raw.githubusercontent.com/anatolmales/linuxinstall/main/vps_install.sh | bash"

# ---- 1) Обновление и установка базовых пакетов ----
echo "=== Обновление пакетов ==="
apt update && apt upgrade -y

echo "=== Установка необходимых пакетов (mc, curl, wget, sudo, ca-certificates, openssl, apache2-utils) ==="
apt install -y mc curl wget sudo ca-certificates openssl apache2-utils apt-transport-https ca-certificates gnupg lsb-release

# Установка Docker (официальный репозиторий)
echo "=== Установка Docker от Docker Inc. ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc || true

# Добавляем репозиторий (поддержка Debian/Ubuntu)
DIST_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
if [ -z "$DIST_CODENAME" ]; then
  DIST_CODENAME=$(lsb_release -cs 2>/dev/null || echo "buster")
fi

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $DIST_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ---- 2) Настройка окружения и загрузка docker-compose.yml ----
echo "=== Создание каталога $INSTALL_PATH ==="
mkdir -p "$INSTALL_PATH"

echo "=== Загрузка docker-compose.yml ==="
wget -O "$COMPOSE_FILE" "$COMPOSE_URL"

# Доп. конфиги (bash_history, tmux) — опционально, как в примере
echo "=== Доп. конфиги (bash history и tmux) ==="
curl -sL "$GIT_RAW_URL/bash_History.sh" | bash || true
wget -O /etc/tmux.conf "$GIT_RAW_URL/tmux.conf" || true

# ---- 3) Определение внешнего IP (несколько fallback'ов) ----
echo "=== Определение внешнего (публичного) IP ==="
get_ip_from() {
  local url="$1"
  local out
  out=$(curl -s --max-time 5 "$url" 2>/dev/null || true)
  # простая проверка: содержит цифры/точки (IPv4) или двоеточия (IPv6)
  if [[ $out =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ $out =~ : ]]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

IP=""
SERVICES=("https://ifconfig.me" "https://ifconfig.co" "https://icanhazip.com" "https://ipinfo.io/ip")
for s in "${SERVICES[@]}"; do
  echo "Попытка: $s"
  ip_candidate=$(get_ip_from "$s" || true)
  if [ -n "$ip_candidate" ]; then
    IP="$ip_candidate"
    break
  fi
done

# Если не удалось — запросим у пользователя
if [ -z "${IP}" ]; then
  echo
  read -r -p "Не удалось определить внешний IP автоматически. Введите IP вручную: " IP
fi

echo "Найден внешний IP: $IP"

# ---- 4) Интерактивный ввод пароля и генерация bcrypt HASH ----
echo
echo "=== Введите пароль для веб-интерфейса (пароль не будет показан) ==="
# читаем дважды, проверка совпадения
while true; do
  read -s -p "Пароль: " PASSWORD
  echo
  read -s -p "Подтвердите пароль: " PASSWORD2
  echo
  if [ "$PASSWORD" != "$PASSWORD2" ]; then
    echo "Пароли не совпадают — попробуйте снова."
  elif [ -z "$PASSWORD" ]; then
    echo "Пароль пустой — попробуйте снова."
  else
    break
  fi
done

# Генерация bcrypt через htpasswd (apache2-utils)
# htpasswd выведет "user:$2y$...". Используем user 'admin' просто для генерации хэша.
echo "=== Генерация bcrypt HASH (htpasswd) ==="
# htpasswd возвращает код ошибки >0 если команда не доступна — проверяем
if command -v htpasswd >/dev/null 2>&1; then
  # -B bcrypt, -n выводит в stdout, -b использовали бы для без интерактива, но используем -nB:
  BCRYPT_HASH=$(htpasswd -bnB admin "${PASSWORD}" 2>/dev/null | cut -d: -f2)
  if [ -z "$BCRYPT_HASH" ]; then
    echo "Ошибка генерации bcrypt через htpasswd. Попробуем через Docker (если доступен)..."
  fi
fi

# Фоллбек: если htpasswd не сработал, пробуем через Docker (требует установленного Docker)
if [ -z "${BCRYPT_HASH:-}" ]; then
  if command -v docker >/dev/null 2>&1; then
    echo "Попытка генерации хэша через temporary Python контейнер..."
    BCRYPT_HASH=$(docker run --rm -i python:3 bash -lc "pip install bcrypt >/dev/null 2>&1 || true; python - <<'PY'
import sys, bcrypt
p = sys.stdin.read().strip()
h = bcrypt.hashpw(p.encode(), bcrypt.gensalt())
print(h.decode())
PY" <<<"$PASSWORD")
  fi
fi

# Ещё фоллбек: если всё совсем плохо — предупредить и выйти
if [ -z "${BCRYPT_HASH:-}" ]; then
  echo "Не удалось сгенерировать bcrypt-хэш. Убедитесь, что установлен apache2-utils (htpasswd) или Docker."
  exit 1
fi

echo "bcrypt HASH успешно сгенерирован: ${BCRYPT_HASH}"

# ---- 5) Подстановка IP и HASH в docker-compose.yml ----
echo "=== Подстановка IP и PASSWORD_HASH в $COMPOSE_FILE ==="

# Экранируем для sed символы, которые могут сломать замену
escaped_ip=$(printf '%s\n' "$IP" | sed -e 's/[\/&]/\\&/g')
escaped_hash=$(printf '%s\n' "$BCRYPT_HASH" | sed -e 's/[\/&]/\\&/g')

# Заменяем все вхождения IPADDRESS (включая в traefik email admin@IPADDRESS и т.д.)
sed -i "s/IPADDRESS/$escaped_ip/g" "$COMPOSE_FILE"

# Заменяем значение PASSWORD_HASH=... (т.к. в файле YAML строка выглядит как "- PASSWORD_HASH=$$2y$$...")
# Найдём строку, где есть "PASSWORD_HASH=" и заменим всё после = на наш хеш
# Используем perl для корректной работы с символами $
if command -v perl >/dev/null 2>&1; then
  perl -0777 -pe "s/(PASSWORD_HASH=).*/\1$escaped_hash/s" -i "$COMPOSE_FILE"
else
  # fallback на sed (должно работать тоже)
  sed -i "s/\(PASSWORD_HASH=\).*$/\1$escaped_hash/" "$COMPOSE_FILE"
fi

echo "Проверка подстановок (фрагмент файла):"
grep -E "PASSWORD_HASH=|WG_HOST|hostname=|admin@" -n "$COMPOSE_FILE" || true

# ---- 6) Создание docker-сети proxy, если нужно ----
echo "=== Проверка/создание docker сети 'proxy' ==="
if docker network ls --format '{{.Name}}' | grep -q '^proxy$'; then
  echo "Сеть proxy уже существует."
else
  echo "Сеть proxy не найдена — создаю..."
  docker network create proxy
  echo "Сеть proxy создана."
fi

# ---- 7) Запуск docker compose (pull + up -d) ----
echo "=== docker compose: pull && up -d ==="
docker compose --project-directory "$PROJECT_DIR" pull --quiet || true
docker compose --project-directory "$PROJECT_DIR" up -d --remove-orphans

# ---- 8) Генерация самоподписанного сертификата с SAN=IP (1000 дней) ----
echo "=== Генерация самоподписанного сертификата для x-ui (1000 дней) ==="
mkdir -p "$CERT_DIR"

CERT_KEY="$CERT_DIR/privkey.pem"
CERT_CRT="$CERT_DIR/cert.pem"

# Сначала пробуем современный вариант с -addext (OpenSSL >=1.1.1)
if openssl req -x509 -nodes -days 1000 -newkey rsa:2048 -keyout "$CERT_KEY" -out "$CERT_CRT" -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" 2>/dev/null; then
  echo "Сертификат создан через -addext."
else
  echo "Флаг -addext не поддерживается. Генерирую через временный openssl.cnf (fallback)."
  TMP_CNF=$(mktemp)
  # Берём системный конфиг если есть, иначе минимальный
  OPENSSL_SYS_CNF="/etc/ssl/openssl.cnf"
  if [ -f "$OPENSSL_SYS_CNF" ]; then
    cp "$OPENSSL_SYS_CNF" "$TMP_CNF"
    # Добавим секцию v3_req в конец (если её нет)
    cat >> "$TMP_CNF" <<EOF

[ v3_req_for_ip ]
subjectAltName = @alt_names

[ alt_names ]
IP.1 = $IP
EOF
    openssl req -x509 -nodes -days 1000 -newkey rsa:2048 -keyout "$CERT_KEY" -out "$CERT_CRT" -subj "/CN=$IP" -extensions v3_req_for_ip -config "$TMP_CNF"
  else
    # минимальный конфиг
    cat > "$TMP_CNF" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req_for_ip
prompt = no

[req_distinguished_name]
CN = $IP

[v3_req_for_ip]
subjectAltName = @alt_names

[alt_names]
IP.1 = $IP
EOF
    openssl req -x509 -nodes -days 1000 -newkey rsa:2048 -keyout "$CERT_KEY" -out "$CERT_CRT" -config "$TMP_CNF"
  fi
  rm -f "$TMP_CNF"
fi

# Права на приватный ключ
chmod 600 "$CERT_KEY" || true
chown root:root "$CERT_KEY" || true

echo "Сертификат создан: $CERT_CRT"
echo "Приватный ключ: $CERT_KEY"

# ---- 9) Финальные сообщения и проверка статуса контейнеров ----
echo "=== Проверка статуса контейнеров (docker ps --filter 'name=wgeasy' и т.д.) ==="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true

echo
echo "=== Установка завершена ==="
echo "Если хотите запустить этот скрипт через curl | bash используйте команду:"
echo "$CURL_LINK"

echo
echo "Путь к docker-compose: $COMPOSE_FILE"
echo "Путь к сертификатам: $CERT_DIR"
echo
echo "Генерация и подстановка IP и PASSWORD_HASH завершены."
echo "Убедитесь, что firewall/сетевые правила VPS допускают порты WireGuard/HTTP(S)."

exit 0
