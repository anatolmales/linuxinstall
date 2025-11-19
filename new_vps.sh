#!/bin/bash
set -e  # Выход при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Определение IP-адреса
detect_ip() {
    log "Определение IP-адреса сервера..."
    local ip
    ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    if [ -z "$ip" ]; then
        error "Не удалось определить IP-адрес"
    fi
    
    echo "$ip"
}

# Запрос подтверждения IP
confirm_ip() {
    local ip="$1"
    echo "Определен IP: $ip"
    read -p "Это правильный IP? [Y/n]: " confirm
    case "${confirm:-Y}" in
        [yY]*) ;;
        [nN]*) 
            read -p "Введите правильный IP: " ip
            ;;
        *) ;;
    esac
    echo "$ip"
}

# Генерация хеша пароля
generate_password_hash() {
    local password="$1"
    if command -v mkpasswd &> /dev/null; then
        echo -n "$password" | mkpasswd -m bcrypt -s
    else
        warn "mkpasswd не найден, используем дефолтный хеш"
        echo '$2y$10$hBCoykrB95WSzuV4fafBzOHWKu9sbyVa34GJr8VV5R/pIelfEMYyG'
    fi
}

# Установка зависимостей
install_dependencies() {
    log "Обновление пакетов..."
    apt update && apt upgrade -y
    
    log "Установка необходимых пакетов..."
    apt install -y mc curl wget sudo ca-certificates gettext
    
    log "Установка Docker..."
    # Ключ Docker
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    # Репозиторий Docker
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Создание сетей Docker
setup_docker_networks() {
    log "Настройка Docker сетей..."
    if ! docker network ls | grep -q proxy; then
        docker network create proxy
    fi
}

# Скачивание и настройка конфигов
setup_configs() {
    log "Скачивание дополнительных конфигураций..."
    curl -sL https://raw.githubusercontent.com/anatolmales/linuxinstall/main/bash_History.sh | bash
    wget -O /etc/tmux.conf https://raw.githubusercontent.com/anatolmales/linuxinstall/main/tmux.conf
}

# Подготовка docker-compose файла с envsubst
setup_docker_compose() {
    local ip_address="$1"
    local password_hash="$2"
    
    log "Настройка docker-compose..."
    
    # Скачивание шаблона
    wget -O /opt/docker/docker-compose-template.yml https://raw.githubusercontent.com/anatolmales/linuxinstall/refs/heads/main/docker-compose.yml
    
    # Экспорт переменных для envsubst
    export IPADDRESS="$ip_address"
    export PASSWORD_HASH="$password_hash"
    
    log "Замена переменных в конфиге..."
    # Использование envsubst для подстановки переменных
    envsubst '${IPADDRESS},${PASSWORD_HASH}' < /opt/docker/docker-compose-template.yml > /opt/docker/docker-compose.yml
    
    # Проверка результата
    if [ ! -s /opt/docker/docker-compose.yml ]; then
        error "Не удалось создать docker-compose.yml"
    fi
    
    log "Проверка замены переменных..."
    if grep -q '\${IPADDRESS}' /opt/docker/docker-compose.yml || grep -q '\${PASSWORD_HASH}' /opt/docker/docker-compose.yml; then
        warn "Некоторые переменные не были заменены"
    fi
}

# Основная установка
main() {
    log "Начало установки..."
    
    # Определение IP
    IPADDRESS=$(detect_ip)
    IPADDRESS=$(confirm_ip "$IPADDRESS")
    
    # Запрос пароля
    read -sp "Введите пароль для админки (по умолчанию: foobar123): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-foobar123}
    echo
    
    PASSWORD_HASH=$(generate_password_hash "$ADMIN_PASS")
    
    # Установка зависимостей
    install_dependencies
    
    # Настройка сетей
    setup_docker_networks
    
    # Дополнительные конфиги
    setup_configs
    
    # Создание директории
    mkdir -p /opt/docker/
    
    # Настройка docker-compose с envsubst
    setup_docker_compose "$IPADDRESS" "$PASSWORD_HASH"
    
    # Запуск сервисов
    log "Запуск Docker сервисов..."
    cd /opt/docker/
    docker compose pull
    docker compose up -d
    
    log "Установка завершена!"
    echo "IP сервера: $IPADDRESS"
    echo "Пароль: $ADMIN_PASS"
    echo "Сервисы доступны по адресам:"
    echo " - WireGuard: https://$IPADDRESS:51821"
    echo " - X-UI: http://$IPADDRESS:54321"
    echo " - Traefik: https://$IPADDRESS"
}

# Проверка прав
if [ "$EUID" -ne 0 ]; then
    error "Скрипт должен запускаться с правами root"
fi

main
