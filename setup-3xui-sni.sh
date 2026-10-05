#!/bin/bash

# ============================================================
#  3X-UI SNI Router + Separate Subscription Domain
#  Nginx Stream (SNI) + HTTPS для панели и подписки
# ============================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}"
echo "======================================================"
echo "  3X-UI SNI Router + Separate Subscription"
echo "  (Nginx Stream + HTTPS)"
echo "======================================================"
echo -e "${NC}"

# ====================== Функции ======================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: запускай скрипт от root (sudo ./setup-3xui-sni.sh)${NC}"
        exit 1
    fi
}

check_port() {
    local port=$1
    local name=$2
    if ss -tuln | grep -qE ":${port}\\s"; then
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
    if ss -tuln | grep -qE ":${port}\\s"; then
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
        if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,}$ ]]; then
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

# ====================== Старт ======================

check_root

echo -e "${YELLOW}Введи домены (без https:// и без слэшей):${NC}"
PANEL_DOMAIN=$(ask_domain "Домен панели (например panel.example.com)")
SUB_DOMAIN=$(ask_domain "Домен подписки (например sub.example.com)")
VPN_DOMAIN=$(ask_domain "Домен REALITY / VPN (например vpn.example.com)")

echo
echo -e "${YELLOW}Порты 3x-ui (оставь по умолчанию, если не менял):${NC}"
PANEL_PORT=$(ask_port "Порт панели 3x-ui" "29395")
SUB_PORT=$(ask_port "Порт Subscription" "2096")
REALITY_PORT=$(ask_port "Локальный порт REALITY (Xray)" "443")

echo
echo -e "${BLUE}Проверяю порты...${NC}"

PORTS_OK=true

# Внешний порт 443 должен быть свободен (мы его займём)
check_port 443 "внешний HTTPS/SNI" || PORTS_OK=false

# Внутренние порты Nginx HTTPS
check_port 8443 "Nginx HTTPS панели" || PORTS_OK=false
check_port 8444 "Nginx HTTPS подписки" || PORTS_OK=false

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
echo -e "${GREEN}Домены:${NC}"
echo "  Панель:      $PANEL_DOMAIN"
echo "  Подписка:    $SUB_DOMAIN"
echo "  REALITY:     $VPN_DOMAIN"
echo
echo -e "${GREEN}Порты:${NC}"
echo "  Панель:      $PANEL_PORT"
echo "  Subscription:$SUB_PORT"
echo "  REALITY:     $REALITY_PORT"
echo
read -rp "Всё верно? Продолжить установку? (y/n): " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

# ====================== Установка пакетов ======================

echo
echo -e "${BLUE}Устанавливаю Nginx + certbot...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot python3-certbot-nginx curl

# Включаем stream модуль
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    # Добавляем include stream в конец nginx.conf
    if ! grep -q "include /etc/nginx/stream.d" /etc/nginx/nginx.conf; then
        cat >> /etc/nginx/nginx.conf <<'EOF'

# Stream (SNI router)
stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
    fi
fi

mkdir -p /etc/nginx/stream.d
mkdir -p /etc/nginx/conf.d

# ====================== Сертификаты ======================

echo
echo -e "${BLUE}Получаю SSL-сертификаты (Let's Encrypt)...${NC}"
echo -e "${YELLOW}Убедись, что DNS A-записи доменов уже указывают на этот сервер!${NC}"

systemctl stop nginx 2>/dev/null || true

# Панель
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

# Подписка
if ! certbot certonly --standalone \
    -d "$SUB_DOMAIN" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --preferred-challenges http; then
    echo -e "${RED}Ошибка получения сертификата для $SUB_DOMAIN${NC}"
    exit 1
fi

# ====================== Stream (SNI Router) ======================

echo
echo -e "${BLUE}Создаю SNI-роутер...${NC}"

cat > /etc/nginx/stream.d/sni-router.conf <<EOF
# SNI Router для 3X-UI
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

cat > /etc/nginx/conf.d/panel.conf <<EOF
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name ${PANEL_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Панель 3x-ui
    location /panel/ {
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

cat > /etc/nginx/conf.d/sub.conf <<EOF
server {
    listen 127.0.0.1:8444 ssl http2 proxy_protocol;
    server_name ${SUB_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${SUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SUB_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

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
    exit 1
fi

systemctl enable nginx
systemctl restart nginx

# Автопродление сертификатов
systemctl enable certbot.timer 2>/dev/null || true

echo
echo -e "${GREEN}======================================================"
echo "  Готово! Всё настроено."
echo "======================================================${NC}"
echo
echo -e "Панель:       ${GREEN}https://${PANEL_DOMAIN}/panel/${NC}"
echo -e "Подписка:     ${GREEN}https://${SUB_DOMAIN}/${NC}"
echo -e "REALITY SNI:  ${GREEN}${VPN_DOMAIN}${NC}"
echo
echo -e "${YELLOW}Обязательно настрой в 3x-ui:${NC}"
echo "1. Панель:"
echo "   - Listen IP: 127.0.0.1"
echo "   - Port: ${PANEL_PORT}"
echo "   - Web Base Path: /panel/"
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
echo