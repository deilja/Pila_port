#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# Pila_port — 3X-UI SNI Router
# TCP :443 -> SNI preread -> panel/sub/reality backends.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
LOG_FILE=/var/log/setup-3xui-sni.log
NGINX_CONF=/etc/nginx/nginx.conf
STREAM_DIR=/etc/nginx/stream.d
STREAM_CONF=$STREAM_DIR/sni-router.conf
PANEL_CONF=/etc/nginx/conf.d/pila-panel.conf
SUB_CONF=/etc/nginx/conf.d/pila-sub.conf
ACME_ROOT=/var/www/pila-port-acme
ACME_CONF=/etc/nginx/conf.d/zz-pila-port-acme.conf
BACKUPS=()
CREATED=()
NGINX_BACKUP_DIR=/var/backups/pila-port
NGINX_FULL_BACKUP=''
ACTIVE_STREAM_CONF=''
ACTIVE_STREAM_MAP_VAR=''
ACTIVE_STREAM_PROXY_PROTOCOL=off

log(){ echo "[$(date '+%F %T')] $*" >>"$LOG_FILE" 2>/dev/null || true; }
rollback(){
  local x f b
  for x in "${BACKUPS[@]}"; do f=${x%%|*}; b=${x#*|}; [[ -f "$b" ]] && cp -a "$b" "$f" || true; done
  for f in "${CREATED[@]}"; do rm -f "$f" || true; done
}
on_error(){ local rc=$?; echo -e "${RED}✗ Ошибка (код $rc), изменения откатываются.${NC}"; log "ERROR rc=$rc line=${BASH_LINENO[0]}"; rollback; if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null && nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || true; fi; exit "$rc"; }
trap on_error ERR

need(){ command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}✗ Не найдена команда: $1${NC}"; exit 1; }; }

ask_domain(){
  local p=$1 v
  while true; do
    read -rp "$(echo -e "${CYAN}${p}: ${NC}")" v
    v=$(tr -d '[:space:]' <<<"$v" | tr '[:upper:]' '[:lower:]')
    [[ "$v" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && { printf '%s\n' "$v"; return; }
    echo -e "${RED}Некорректный домен.${NC}"
  done
}
ask_port(){
  local p=$1 d=$2 v
  while true; do
    read -rp "$(echo -e "${CYAN}${p} [${d}]: ${NC}")" v; v=${v:-$d}
    [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1&&v<=65535)) && { printf '%s\n' "$v"; return; }
    echo -e "${RED}Порт: 1-65535.${NC}"
  done
}
ask_path(){
  local p=$1 d=$2 v
  while true; do
    read -rp "$(echo -e "${CYAN}${p} [${d}]: ${NC}")" v; v=${v:-$d}; [[ "$v" == /* ]] || v="/$v"; [[ "$v" == */ ]] || v="$v/"
    [[ "$v" =~ ^/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/$ ]] && { printf '%s\n' "$v"; return; }
    echo -e "${RED}Путь должен быть вида /panel/.${NC}"
  done
}
ask_email(){
  local v; read -rp "$(echo -e "${CYAN}Email Let's Encrypt (необязательно): ${NC}")" v
  [[ -z "$v" ]] || [[ "$v" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo -e "${YELLOW}⚠ Некорректный email — продолжу без него.${NC}" >&2; v=''; }
  printf '%s\n' "$v"
}

backup(){
  local f=$1 b
  if [[ -f "$f" ]]; then b="${f}.bak.$(date +%Y%m%d_%H%M%S_$$)"; cp -a "$f" "$b"; BACKUPS+=("$f|$b"); echo -e "${GREEN}✓ Бэкап: $b${NC}"; else CREATED+=("$f"); fi
}
backup_nginx_full(){
  local ts archive
  mkdir -p "$NGINX_BACKUP_DIR"; ts=$(date +%Y%m%d_%H%M%S)
  archive="$NGINX_BACKUP_DIR/nginx-$ts-$$.tar.gz"; tar -C / -czf "$archive" etc/nginx
  NGINX_FULL_BACKUP="$archive"; echo -e "${GREEN}✓ Полный бэкап Nginx: $archive${NC}"
  cat > /usr/local/sbin/pila-port-restore <<'EOF_RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP_DIR=/var/backups/pila-port
archive="${1:-}"
[[ -n "$archive" ]] || archive=$(ls -1t "$BACKUP_DIR"/nginx-*.tar.gz 2>/dev/null | head -1 || true)
[[ -n "$archive" && -f "$archive" ]] || { echo "Бэкап Nginx не найден: $archive" >&2; exit 1; }
tar -xzf "$archive" -C /
nginx -t
systemctl reload nginx
echo "Nginx восстановлен из $archive"
EOF_RESTORE
  chmod 0755 /usr/local/sbin/pila-port-restore
}
discover_existing_stream(){
  local dump f mapline
  ACTIVE_STREAM_CONF=''; ACTIVE_STREAM_MAP_VAR=''; ACTIVE_STREAM_PROXY_PROTOCOL=off
  dump=$(nginx -T 2>&1 || true)
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -Eq '^[[:space:]]*listen[[:space:]]+(443|[0-9.]+:443|\[::\]:443)[[:space:]]*;' "$f" || continue
    grep -Eq '^[[:space:]]*ssl_preread[[:space:]]+on[[:space:]]*;' "$f" || continue
    grep -Fq "configuration file $f:" <<<"$dump" || continue
    ACTIVE_STREAM_CONF="$f"; break
  done < <(grep -RIl --include='*.conf' --include='nginx.conf' 'ssl_preread' /etc/nginx 2>/dev/null | sort -u)
  if [[ -n "$ACTIVE_STREAM_CONF" ]]; then
    mapline=$(grep -E '^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$[A-Za-z0-9_]+' "$ACTIVE_STREAM_CONF" | head -1 || true)
    [[ -n "$mapline" ]] && ACTIVE_STREAM_MAP_VAR=$(sed -n 's/^[[:space:]]*map[[:space:]]*\$ssl_preread_server_name[[:space:]]*\$\([A-Za-z0-9_]*\).*/\1/p' <<<"$mapline")
    grep -Eq '^[[:space:]]*proxy_protocol[[:space:]]+(on|v2)[[:space:]]*;' "$ACTIVE_STREAM_CONF" && ACTIVE_STREAM_PROXY_PROTOCOL=on
    echo -e "${GREEN}✓ Найден активный SNI-router: ${ACTIVE_STREAM_CONF}${NC}"
  fi
}
integrate_existing_stream(){
  local f="$ACTIVE_STREAM_CONF" tmp
  [[ -n "$f" && -n "$ACTIVE_STREAM_MAP_VAR" ]] || return 1
  tmp=$(mktemp)
  awk -v panel="$PANEL_DOMAIN" -v sub="$SUB_DOMAIN" -v reality="$VPN_DOMAIN" -v rport="$REALITY_PORT" '
    BEGIN { inmap=0; have_panel=0; have_sub=0; have_reality=0 }
    /^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$/ { inmap=1; print; next }
    inmap && $0 ~ /^[[:space:]]*}/ {
      if (!have_panel) print "    " panel_domain " 127.0.0.1:8443;"
      if (!have_sub) print "    " sub_domain " 127.0.0.1:8444;"
      if (!have_reality) print "    " reality_domain " 127.0.0.1:" rport ";"
      print; inmap=0; next
    }
    inmap { if ($1 == panel_domain) have_panel=1; if ($1 == sub_domain) have_sub=1; if ($1 == reality_domain) have_reality=1 }
    { print }
  ' "$f" > "$tmp"
  backup "$f"; cat "$tmp" > "$f"; rm -f "$tmp"
  echo -e "${GREEN}✓ Existing SNI-router extended; public :443 preserved${NC}"
}

listeners(){ ss -ltnpH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$"'; }
port_free(){ [[ -z "$(listeners "$1")" ]]; }

check_backend(){
  local port=$1 label=$2 out
  out=$(listeners "$port")
  [[ -z "$out" ]] && { echo -e "${YELLOW}⚠ $label :$port не слушает — настрой его после установки.${NC}"; return 0; }
  if awk -v p=":$port" '$4 ~ p"$" && $4 !~ /^(127\.0\.0\.1|\[::1\]):/ {ok=1} END{exit(ok?0:1)}' <<<"$out"; then
    echo -e "${YELLOW}⚠ $label :$port слушает не только loopback — прямой доступ к порту остаётся возможен:${NC}"; echo "$out"; return 0
  fi
  echo -e "${GREEN}✓ $label :$port → loopback${NC}"
}

check_dns(){
  local d=$1 ip=$2 r; r=$(dig +short A "$d" 2>/dev/null | awk 'NF{print;exit}')
  [[ -n "$r" && "$r" == "$ip" ]] && { echo -e "${GREEN}✓ DNS A: $d → $r${NC}"; return 0; }
  echo -e "${YELLOW}⚠ DNS A: $d → ${r:-не найден} (ожидался ${ip:-unknown})${NC}"; return 1
}

ensure_stream(){
  # Existing active SNI stream already owns :443; do not create a second stream block.
  [[ -n "$ACTIVE_STREAM_CONF" ]] && return 0
  mkdir -p "$STREAM_DIR"
  if grep -Fq 'include /etc/nginx/stream.d/*.conf;' "$NGINX_CONF"; then return; fi
  if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$NGINX_CONF"; then
    echo -e "${RED}✗ В nginx.conf уже есть stream-блок без Pila_port include.${NC}"
    echo "Добавь внутрь него: include /etc/nginx/stream.d/*.conf;"; exit 1
  fi
  backup "$NGINX_CONF"
  cat >>"$NGINX_CONF" <<'EOF_STREAM_ROOT'

# Pila_port SNI router
stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF_STREAM_ROOT
}

write_acme(){
  mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
  backup "$ACME_CONF"
  cat >"$ACME_CONF" <<EOF_ACME
# Pila_port temporary ACME webroot
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN} ${SUB_DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF_ACME
}
obtain_cert(){
  local d=$1; local -a e=()
  [[ -n "$LE_EMAIL" ]] && e+=(--email "$LE_EMAIL") || e+=(--register-unsafely-without-email)
  certbot certonly --webroot -w "$ACME_ROOT" -d "$d" --cert-name "$d" --non-interactive --agree-tos --preferred-challenges http "${e[@]}"
}

write_stream(){
  if [[ -n "$ACTIVE_STREAM_CONF" && -n "$ACTIVE_STREAM_MAP_VAR" ]]; then
    integrate_existing_stream
    return
  fi
  local pp=''
  [[ "$PROXY_PROTOCOL" == on ]] && pp='    proxy_protocol on;'
  backup "$STREAM_CONF"
  cat >"$STREAM_CONF" <<EOF_STREAM
# Pila_port — 3X-UI SNI Router
map \$ssl_preread_server_name \$pila_backend {
    ${PANEL_DOMAIN} panel_https;
    ${SUB_DOMAIN} sub_https;
    ${VPN_DOMAIN} xray_reality;
    default reject;
}
upstream panel_https { server 127.0.0.1:8443; }
upstream sub_https { server 127.0.0.1:8444; }
upstream xray_reality { server 127.0.0.1:${REALITY_PORT}; }
upstream reject { server 127.0.0.1:9; }
server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
${pp}
    proxy_pass \$pila_backend;
}
EOF_STREAM
}

write_panel(){
  local lp='' ip='$remote_addr'
  if [[ "$PROXY_PROTOCOL" == on ]]; then lp=' proxy_protocol'; ip='$proxy_protocol_addr'; fi
  backup "$PANEL_CONF"
  cat >"$PANEL_CONF" <<EOF_PANEL
# Pila_port — 3X-UI panel
map \$http_upgrade \$pila_connection_upgrade { default upgrade; '' close; }
server {
    listen 127.0.0.1:8443 ssl${lp};
    server_name ${PANEL_DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
EOF_PANEL
  [[ "$PROXY_PROTOCOL" == on ]] && cat >>"$PANEL_CONF" <<'EOF_PANEL_PROXY'
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
EOF_PANEL_PROXY
  cat >>"$PANEL_CONF" <<EOF_PANEL2
    location ${PANEL_PATH} {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$pila_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP ${ip};
        proxy_set_header X-Forwarded-For ${ip};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
    location / { return 404; }
}
EOF_PANEL2
}

write_sub(){
  local lp='' ip='$remote_addr'
  if [[ "$PROXY_PROTOCOL" == on ]]; then lp=' proxy_protocol'; ip='$proxy_protocol_addr'; fi
  backup "$SUB_CONF"
  cat >"$SUB_CONF" <<EOF_SUB
# Pila_port — 3X-UI subscription
server {
    listen 127.0.0.1:8444 ssl${lp};
    server_name ${SUB_DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${SUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SUB_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
EOF_SUB
  [[ "$PROXY_PROTOCOL" == on ]] && cat >>"$SUB_CONF" <<'EOF_SUB_PROXY'
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
EOF_SUB_PROXY
  cat >>"$SUB_CONF" <<EOF_SUB2
    location / {
        proxy_pass http://127.0.0.1:${SUB_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP ${ip};
        proxy_set_header X-Forwarded-For ${ip};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF_SUB2
}

smoke(){ local d=$1; timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$d" -brief </dev/null >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || { echo -e "${RED}✗ Нужен root.${NC}"; exit 1; }
[[ -f /etc/os-release ]] && . /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) echo -e "${YELLOW}⚠ ОС не Debian/Ubuntu.${NC}"; read -rp 'Продолжить? (y/N): ' a; [[ "$a" =~ ^[Yy]$ ]] || exit 0;; esac
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/setup-3xui-sni.log
log 'Pila_port start'

cat <<'BANNER'
======================================================
  Pila_port — 3X-UI SNI Router
======================================================
BANNER

echo -e "${YELLOW}Домены:${NC}"
PANEL_DOMAIN=$(ask_domain 'Домен панели')
SUB_DOMAIN=$(ask_domain 'Домен подписки')
VPN_DOMAIN=$(ask_domain 'SNI для REALITY')
[[ "$PANEL_DOMAIN" != "$SUB_DOMAIN" && "$PANEL_DOMAIN" != "$VPN_DOMAIN" && "$SUB_DOMAIN" != "$VPN_DOMAIN" ]] || { echo -e "${RED}✗ Домены должны различаться.${NC}"; exit 1; }

echo -e "${YELLOW}Порты:${NC}"
PANEL_PORT=$(ask_port 'Порт панели 3x-ui' 29395)
SUB_PORT=$(ask_port 'Порт Subscription' 2096)
REALITY_PORT=$(ask_port 'Локальный порт REALITY' 4433)
PANEL_PATH=$(ask_path 'Web Base Path панели' /panel/)
LE_EMAIL=$(ask_email)
PROXY_PROTOCOL=${SNI_PROXY_PROTOCOL:-off}; [[ "$PROXY_PROTOCOL" == on ]] || PROXY_PROTOCOL=off
if [[ -n "$ACTIVE_STREAM_CONF" && "$ACTIVE_STREAM_PROXY_PROTOCOL" == on && -z "${SNI_PROXY_PROTOCOL:-}" ]]; then PROXY_PROTOCOL=on; fi

(( PANEL_PORT != SUB_PORT )) || { echo -e "${RED}✗ Panel и Subscription не могут использовать один порт.${NC}"; exit 1; }
for p in "$PANEL_PORT" "$SUB_PORT" "$REALITY_PORT"; do case "$p" in 80|443|8443|8444) echo -e "${RED}✗ Порт ${p} зарезервирован. Для REALITY используй, например, 4433.${NC}"; exit 1;; esac; done

echo -e "${BLUE}Устанавливаю зависимости...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot curl dnsutils openssl libnginx-mod-stream
need nginx; need certbot; need curl; need dig; need openssl
if ! nginx -V 2>&1 | grep -Eq -- '--with-stream_ssl_preread_module|--with-stream=dynamic'; then echo -e "${RED}✗ Nginx не содержит stream SSL preread.${NC}"; exit 1; fi

backup_nginx_full
discover_existing_stream

# Detect and preserve an existing Nginx SNI router on :443.
if [[ -n "$(listeners 443)" ]]; then
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "${RED}✗ TCP :443 занят, но Nginx не активен — автоматическая миграция невозможна.${NC}"; listeners 443; exit 1
  fi
  discover_existing_stream
  if [[ -n "$ACTIVE_STREAM_CONF" && "$ACTIVE_STREAM_PROXY_PROTOCOL" == on && -z "${SNI_PROXY_PROTOCOL:-}" ]]; then
    PROXY_PROTOCOL=on
    echo -e "${YELLOW}⚠ Existing router uses PROXY protocol; preserving it automatically.${NC}"
  fi
  if [[ -z "$ACTIVE_STREAM_CONF" || -z "$ACTIVE_STREAM_MAP_VAR" ]]; then
    echo -e "${RED}✗ :443 занят Nginx, но активный stream/ssl_preread-router не найден.${NC}"
    echo "Скрипт не будет ломать существующий HTTPS :443 автоматически."; listeners 443; exit 1
  fi
else
  echo -e "${GREEN}✓ TCP :443 свободен — создаём собственный Nginx SNI-router${NC}"
fi
for p in 8443 8444; do port_free "$p" || { echo -e "${RED}✗ Внутренний Nginx :${p} занят:${NC}"; listeners "$p"; exit 1; }; done
check_backend "$PANEL_PORT" 'Панель 3x-ui'
check_backend "$SUB_PORT" 'Subscription'

if [[ -f "$PANEL_CONF" ]] && ! grep -q Pila_port "$PANEL_CONF"; then echo -e "${RED}✗ $PANEL_CONF уже существует и не принадлежит Pila_port.${NC}"; exit 1; fi
if [[ -f "$SUB_CONF" ]] && ! grep -q Pila_port "$SUB_CONF"; then echo -e "${RED}✗ $SUB_CONF уже существует и не принадлежит Pila_port.${NC}"; exit 1; fi

IP=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
DNS_OK=true
[[ -n "$IP" ]] && check_dns "$PANEL_DOMAIN" "$IP" || DNS_OK=false
[[ -n "$IP" ]] && check_dns "$SUB_DOMAIN" "$IP" || DNS_OK=false
if [[ "$DNS_OK" == false ]]; then echo -e "${YELLOW}⚠ DNS panel/sub пока не подтверждён.${NC}"; read -rp "Продолжить? (y/N): " a; [[ "$a" =~ ^[Yy]$ ]] || exit 1; fi

echo
echo -e "${GREEN}Будет настроено:${NC}"
echo "  ${PANEL_DOMAIN} → 127.0.0.1:8443 → ${PANEL_PATH} → 3x-ui:${PANEL_PORT}"
echo "  ${SUB_DOMAIN} → 127.0.0.1:8444 → Subscription:${SUB_PORT}"
echo "  ${VPN_DOMAIN} → 127.0.0.1:${REALITY_PORT} → Xray REALITY"
echo "  public TCP :443 → Nginx SNI"
echo "  PROXY protocol → ${PROXY_PROTOCOL}"
read -rp "Продолжить? (y/N): " a; [[ "$a" =~ ^[Yy]$ ]] || exit 0

CERT1=/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem
KEY1=/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem
CERT2=/etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem
KEY2=/etc/letsencrypt/live/$SUB_DOMAIN/privkey.pem

if [[ ! -f "$CERT1" || ! -f "$KEY1" || ! -f "$CERT2" || ! -f "$KEY2" ]]; then
  if [[ -n "$(listeners 80)" ]] && ss -ltnpH 2>/dev/null | grep -Evq 'users:.*nginx'; then
    echo -e "${RED}✗ TCP :80 занят не только Nginx; webroot ACME без остановки чужого сервиса невозможен.${NC}"; listeners 80; exit 1
  fi
  write_acme
  if systemctl is-active --quiet nginx; then nginx -t; systemctl reload nginx; else nginx -t; systemctl start nginx; fi
  [[ -f "$CERT1" ]] || obtain_cert "$PANEL_DOMAIN"
  [[ -f "$CERT2" ]] || obtain_cert "$SUB_DOMAIN"
  rm -f "$ACME_CONF"
  nginx -t
  systemctl reload nginx
else
  echo -e "${GREEN}✓ Сертификаты panel/sub уже существуют${NC}"
fi
[[ -f "$CERT1" && -f "$KEY1" && -f "$CERT2" && -f "$KEY2" ]] || { echo -e "${RED}✗ Не получены оба TLS-сертификата.${NC}"; exit 1; }

ensure_stream
write_stream
write_panel
write_sub
nginx -t
systemctl enable nginx
if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi
systemctl enable certbot.timer 2>/dev/null || true

ss -ltnH | awk '$4 ~ /:443$/ {ok=1} END{exit(ok?0:1)}' || { echo -e "${RED}✗ Nginx не слушает :443.${NC}"; exit 1; }
smoke "$PANEL_DOMAIN" && echo -e "${GREEN}✓ TLS/SNI panel OK${NC}" || echo -e "${YELLOW}⚠ TLS/SNI panel не подтверждён${NC}"
smoke "$SUB_DOMAIN" && echo -e "${GREEN}✓ TLS/SNI subscription OK${NC}" || echo -e "${YELLOW}⚠ TLS/SNI subscription не подтверждён${NC}"
if listeners "$REALITY_PORT" | grep -Eq '127\.0\.0\.1:|\[::1\]:'; then echo -e "${GREEN}✓ Xray listener найден на loopback :${REALITY_PORT}${NC}"; else echo -e "${YELLOW}⚠ Xray пока не слушает :${REALITY_PORT}; настрой REALITY inbound.${NC}"; fi

log "Pila_port done panel=$PANEL_DOMAIN sub=$SUB_DOMAIN reality=$VPN_DOMAIN:$REALITY_PORT proxy_protocol=$PROXY_PROTOCOL"
cat <<EOF_DONE

${GREEN}======================================================
  Готово
======================================================${NC}
Панель:      https://${PANEL_DOMAIN}${PANEL_PATH}
Подписка:    https://${SUB_DOMAIN}/
REALITY SNI: ${VPN_DOMAIN}
Public TCP:  :443 (Nginx)
REALITY:     127.0.0.1:${REALITY_PORT}

3X-UI:
  Panel Listen: 127.0.0.1:${PANEL_PORT}
  Web Base Path: ${PANEL_PATH}
  Subscription: 127.0.0.1:${SUB_PORT}
  REALITY Listen: 127.0.0.1:${REALITY_PORT}
EOF_DONE
if [[ "$PROXY_PROTOCOL" == on ]]; then echo '  Xray: enable acceptProxyProtocol in the REALITY inbound'; else echo '  PROXY protocol: off (no extra Xray setting required)'; fi
echo "  Restore: /usr/local/sbin/pila-port-restore"
echo "  Full Nginx backup: ${NGINX_FULL_BACKUP:-${NGINX_BACKUP_DIR}}"
echo -e "${CYAN}Проверка: nginx -t${NC}"
echo -e "${CYAN}Статус: systemctl status nginx --no-pager -l${NC}"
echo -e "${CYAN}Логи: journalctl -u nginx -f${NC}"
echo -e "${CYAN}Лог установки: ${LOG_FILE}${NC}"
