#!/bin/bash

# ============================================================
#  3X-UI SNI Router + Separate Subscription Domain (v2)
#  Nginx Stream (SNI) + HTTPS для панели и подписки
# ============================================================

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/setup-3xui-sni.log"

echo -e "${BLUE}"
echo "======================================================"
echo "  3X-UI SNI Router + Separate Subscription  (v2)"
echo "  (Nginx Stream + HTTPS)"
echo "======================================================"
echo -e "${NC}"

# ====================== Функции ======================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >/dev/null
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: запускай скрипт от root (sudo ./setup-3xui-sni.sh)${NC}"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                echo -e "${GREEN}✓ ОС: $PRETTY_NAME${NC}"
                ;;
            *)
                echo -e "${YELLOW}⚠ ОС $PRETTY_NAME не тестировалась (ожидается Debian/Ubuntu)${NC}"
                read -rp "Продолжить? (y/n): " ans
                [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0
                ;;
        esac
    fi
}

check_port_free() {
    local port=$1
    local name=$2
    if ss -tuln | grep -qE ":${port}\s"; then
        echo -e "${RED}✗ Порт ${port} (${name}) занят${NC}"
        return 1
    else
        echo -e "${GREEN}✓ Порт ${port} (${name}) свободен${NC}"
        return 0
    fi
}

check_port_used() {
    local port=$1
    local name=$2
    if ss -tuln | grep -qE ":${port}\s"; then
        echo -e "${GREEN}✓ ${name} найден на порту ${port}${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ ${name} не найден на порту ${port}${NC}"
        return 1
    fi
}

ask_domain() {
    local prompt=$1
    local domain
    while true; do
        read -rp "$(echo -e "${CYAN}${prompt}: ${NC}")" domain
        domain=$(echo "$domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ -z "$domain" ]]; then
            echo -e "${RED}Домен не может быть пустым${NC}"
            continue
        fi
        if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            echo -e "${RED}Некорректный домен. Пример: panel.example.com${NC}"
            continue
        fi
        echo "$domain"
        return
    done
}

ask_port() {
    local prompt=$1
    local default=$2
    local port
    while true; do
        read -rp "$(echo -e "${CYAN}${prompt} [${default}]: ${NC}")" port
        port=${port:-$default}
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
            echo "$port"
            return
        fi
        echo -e "${RED}Введи корректный порт (1-65535)${NC}"
    done
}

ask_path() {
    local prompt=$1
    local default=$2
    local path
    while true; do
        read -rp "$(echo -e "${CYAN}${prompt} [${default}]: ${NC}")" path
        path=${path:-$default}
        [[ "$path" != /* ]] && path="/$path"
        [[ "$path" != */ ]] && path="${path}/"
        if [[ "$path" =~ ^/[a-zA-Z0-9/_-]+/$ ]]; then
            echo "$path"
            return
        fi
        echo -e "${RED}Путь должен быть вида /panel/ (только буквы, цифры, -, _)${NC}"
    done
}

get_server_ip() {
    local ip
    ip=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

check_dns() {
    local domain=$1
    local expected_ip=$2
    local resolved
    resolved=$(dig +short "$domain" A 2>/dev/null | head -1 || true)
    if [[ -z "$resolved" ]]; then
        echo -e "${YELLOW}⚠ DNS: $domain не резолвится${NC}"
        return 1
    fi
    if [[ "$resolved" == "$expected_ip" ]]; then
        echo -e "${GREEN}✓ DNS: $domain → $resolved${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ DNS: $domain → $resolved (ожидался $expected_ip)${NC}"
        return 1
    fi
}

backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        local bak="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$file" "$bak"
        echo -e "${GREEN}✓ Бэкап: $bak${NC}"
        log "Backup: $file → $bak"
    fi
}

# ====================== Старт ======================

check_root
check_os

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/setup-3xui-sni.log"
log "=== Запуск скрипта ==="

echo -e "${YELLOW}Введи домены (без https:// и без слэшей):${NC}"
PANEL_DOMAIN=$(ask_domain "Домен панели (например panel.example.com)")
SUB_DOMAIN=$(ask_domain "Домен подписки (например sub.example.com)")
VPN_DOMAIN=$(ask_domain "Домен REALITY / VPN (например vpn.example.com)")

echo
echo -e "${YELLOW}Порты и путь 3x-ui:${NC}"
PANEL_PORT=$(ask_port "Порт панели 3x-ui" "29395")
SUB_PORT=$(ask_port "Порт Subscription" "2096")
REALITY_PORT=$(ask_port "Локальный порт REALITY (Xray)" "443")
PANEL_PATH=$(ask_path "Web Base Path панели" "/panel/")

echo
echo -e "${BLUE}Проверяю порты...${NC}"

PORTS_OK=true

check_port_free 443  "внешний HTTPS/SNI" || PORTS_OK=false
check_port_free 80   "HTTP (для certbot)" || PORTS_OK=false
check_port_free 8443 "Nginx HTTPS панели" || PORTS_OK=false
check_port_free 8444 "Nginx HTTPS подписки" || PORTS_OK=false

echo
echo -e "${BLUE}Проверка портов 3x-ui:${NC}"
PANEL_OK=true
SUB_OK=true
check_port_used "$PANEL_PORT" "Панель 3x-ui" || PANEL_OK=false
check_port_used "$SUB_PORT" "Subscription" || SUB_OK=false

if [[ "$PORTS_OK" == false ]]; then
    echo
    echo -e "${RED}Есть занятые порты, которые нужны скрипту.${NC}"
    echo -e "${YELLOW}Останови конфликтующие сервисы (nginx, caddy, apache и т.д.) и запусти снова.${NC}"
    exit 1
fi

if [[ "$PANEL_OK" == false || "$SUB_OK" == false ]]; then
    echo
    echo -e "${YELLOW}Внимание: панель или subscription не найдены на указанных портах.${NC}"
    echo -e "Убедись, что 3x-ui слушает:"
    echo "  - Панель: 127.0.0.1:${PANEL_PORT}"
    echo "  - Subscription: 127.0.0.1:${SUB_PORT}"
    echo
    read -rp "Продолжить всё равно? (y/n): " cont
    [[ "$cont" != "y" && "$cont" != "Y" ]] && exit 0
fi

echo
echo -e "${BLUE}Проверяю DNS...${NC}"
SERVER_IP=$(get_server_ip)
echo -e "IP сервера: ${CYAN}${SERVER_IP}${NC}"

DNS_OK=true
check_dns "$PANEL_DOMAIN" "$SERVER_IP" || DNS_OK=false
check_dns "$SUB_DOMAIN" "$SERVER_IP" || DNS_OK=false

if [[ "$DNS_OK" == false ]]; then
    echo
    echo -e "${YELLOW}DNS ещё не указывает на этот сервер (или dig недоступен).${NC}"
    echo -e "Certbot может не пройти. Продолжить? (рекомендуется дождаться обновления DNS)"
    read -rp "(y/n): " cont
    [[ "$cont" != "y" && "$cont" != "Y" ]] && exit 0
fi

echo
echo -e "${GREEN}Домены:${NC}"
echo "  Панель:      $PANEL_DOMAIN"
echo "  Подписка:    $SUB_DOMAIN"
echo "  REALITY:     $VPN_DOMAIN"
echo
echo -e "${GREEN}Порты и путь:${NC}"
echo "  Панель:      $PANEL_PORT  (path: $PANEL_PATH)"
echo "  Subscription:$SUB_PORT"
echo "  REALITY:     $REALITY_PORT"
echo
read -rp "Всё верно? Продолжить установку? (y/n): " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

# ====================== Установка пакетов ======================

echo
echo -e "${BLUE}Устанавливаю Nginx + certbot + зависимости...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot python3-certbot-nginx curl dnsutils

if command -v ufw >/dev/null 2>&1; then
    echo -e "${BLUE}Открываю порты в ufw...${NC}"
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ ufw: 80 и 443 разрешены${NC}"
fi

mkdir -p /etc/nginx/stream.d
mkdir -p /etc/nginx/conf.d

if ! grep -q "include /etc/nginx/stream.d" /etc/nginx/nginx.conf; then
    if ! grep -q "^stream {" /etc/nginx/nginx.conf; then
        backup_file /etc/nginx/nginx.conf
        cat >> /etc/nginx/nginx.conf <<'EOF'

# Stream (SNI router) — добавлено setup-3xui-sni
stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
        echo -e "${GREEN}✓ Добавлен stream-блок в nginx.conf${NC}"
    else
        echo -e "${YELLOW}⚠ stream-блок уже есть, но include stream.d не найден — проверь вручную${NC}"
    fi
fi

# ====================== Сертификаты ======================

echo
echo -e "${BLUE}SSL-сертификаты...${NC}"

SKIP_CERT=false
if [[ -f "/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem" && \
      -f "/etc/letsencrypt/live/${SUB_DOMAIN}/fullchain.pem" ]]; then
    echo -e "${GREEN}Сертификаты уже существуют.${NC}"
    read -rp "Пропустить получение новых? (y/n): " skip
    [[ "$skip" == "y" || "$skip" == "Y" ]] && SKIP_CERT=true
fi

if [[ "$SKIP_CERT" == false ]]; then
    echo -e "${YELLOW}Убедись, что DNS A-записи доменов уже указывают на этот сервер!${NC}"
    systemctl stop nginx 2>/dev/null || true

    if ! certbot certonly --standalone \
        -d "$PANEL_DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --preferred-challenges http; then
        echo -e "${RED}Ошибка получения сертификата для $PANEL_DOMAIN${NC}"
        echo "Проверь DNS и что порт 80 свободен."
        exit 1
    fi

    if ! certbot certonly --standalone \
        -d "$SUB_DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --preferred-challenges http; then
        echo -e "${RED}Ошибка получения сертификата для $SUB_DOMAIN${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Сертификаты получены${NC}"
fi

# ====================== Stream (SNI Router) ======================

echo
echo -e "${BLUE}Создаю SNI-роутер...${NC}"

backup_file /etc/nginx/stream.d/sni-router.conf

cat > /etc/nginx/stream.d/sni-router.conf <<EOF
# SNI Router для 3X-UI — сгенерировано setup-3xui-sni
map \$ssl_preread_server_name \$backend {
    ${PANEL_DOMAIN}     panel_https;
    ${SUB_DOMAIN}       sub_https;
    ${VPN_DOMAIN}       xray_reality;
    default             reject;
}

upstream panel_https {
    server 127.0.0.1:8443;
}

upstream sub_https {
    server 127.0.0.1:8444;
}

upstream xray_reality {
    server 127.0.0.1:${REALITY_PORT};
}

upstream reject {
    server 127.0.0.1:9999;
}

server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    proxy_pass \$backend;
    ssl_preread on;
    proxy_protocol on;
}
EOF

# ====================== HTTPS Панель ======================

backup_file /etc/nginx/conf.d/panel.conf

cat > /etc/nginx/conf.d/panel.conf <<EOF
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name ${PANEL_DOMAIN};

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location ${PANEL_PATH} {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
EOF

# ====================== HTTPS Подписка ======================

backup_file /etc/nginx/conf.d/sub.conf

cat > /etc/nginx/conf.d/sub.conf <<EOF
server {
    listen 127.0.0.1:8444 ssl http2 proxy_protocol;
    server_name ${SUB_DOMAIN};

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     /etc/letsencrypt/live/${SUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SUB_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://127.0.0.1:${SUB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_buffering off;
    }
}
EOF

# ====================== Проверка и запуск ======================

echo
echo -e "${BLUE}Проверяю конфигурацию Nginx...${NC}"
if ! nginx -t; then
    echo -e "${RED}Ошибка в конфигурации Nginx!${NC}"
    echo "Бэкапы сохранены с расширением .bak.*"
    exit 1
fi

systemctl enable nginx
systemctl restart nginx

systemctl enable certbot.timer 2>/dev/null || true

log "Установка завершена успешно"
log "Panel: https://${PANEL_DOMAIN}${PANEL_PATH}"
log "Sub:   https://${SUB_DOMAIN}/"
log "REALITY SNI: ${VPN_DOMAIN}"

echo
echo -e "${GREEN}======================================================"
echo "  Готово! Всё настроено."
echo "======================================================${NC}"
echo
echo -e "Панель:       ${GREEN}https://${PANEL_DOMAIN}${PANEL_PATH}${NC}"
echo -e "Подписка:     ${GREEN}https://${SUB_DOMAIN}/${NC}"
echo -e "REALITY SNI:  ${GREEN}${VPN_DOMAIN}${NC}"
echo
echo -e "${YELLOW}Обязательно настрой в 3x-ui:${NC}"
echo "1. Панель:"
echo "   - Listen IP: 127.0.0.1"
echo "   - Port: ${PANEL_PORT}"
echo "   - Web Base Path: ${PANEL_PATH}"
echo
echo "2. Subscription:"
echo "   - Listen IP: 127.0.0.1"
echo "   - Port: ${SUB_PORT}"
echo "   - Sub URI: https://${SUB_DOMAIN}"
echo
echo "3. REALITY inbound:"
echo "   - Listen: 127.0.0.1:${REALITY_PORT}"
echo "   - SNI / serverNames: ${VPN_DOMAIN}"
echo
echo -e "${CYAN}Проверить статус: systemctl status nginx${NC}"
echo -e "${CYAN}Логи:             journalctl -u nginx -f${NC}"
echo -e "${CYAN}Лог скрипта:      ${LOG_FILE}${NC}"
echo
