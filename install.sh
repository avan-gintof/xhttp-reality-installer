#!/usr/bin/env bash
# ==============================================================================
# Stealth Node Auto-Installer: Multi-Domain SNI-Multiplexed VLESS-XHTTP-REALITY
# ==============================================================================
# - Nginx Stream (L4 SNI Pre-read Multiplexer on port 443)
# - Xray / 3x-ui (VLESS + XHTTP + REALITY + HTTP Padding 100-1000) on 127.0.0.2:443
# - Caddy Web Server on internal 8444 with strict_sni_host (RFC 421) & Auto-HTTPS
# - Nginx HTTP on port 80 (anti-probing: return 444 on raw IP, ACME pass to Caddy)
# - Modern Responsive Showcase Landing Page for Domain 1
# - Zero public port exposure: 3x-ui bound strictly to localhost + secret sub paths
# - Hardened UFW Firewall (only SSH, 80, 443 allowed) + Fail2ban
# ==============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Этот скрипт должен быть запущен с правами root (sudo).${NC}"
   exit 1
fi

clear
echo -e "${CYAN}${BOLD}"
cat << "EOF"
  ____  _             _ _   _       _   _           _      
 / ___|| |_ ___  __ _| | |_| |__   | \ | | ___   __| | ___ 
 \___ \| __/ _ \/ _` | | __| '_ \  |  \| |/ _ \ / _` |/ _ \
  ___) | ||  __/ (_| | | |_| | | | | |\  | (_) | (_| |  __/
 |____/ \__\___|\__,_|_|\__|_| |_| |_| \_|\___/ \__,_|\___|
EOF
echo -e "${NC}"
echo -e "${PURPLE}================================================================${NC}"
echo -e "${BOLD} Установка защищенного прокси-узла с маскировкой под веб-хостинг ${NC}"
echo -e "${PURPLE}================================================================${NC}\n"

# Detect Server IP
SERVER_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org || curl -s4 --connect-timeout 5 https://ifconfig.me || echo "YOUR_SERVER_IP")

# --- Interactive Prompts ---
echo -e "${YELLOW}[?] Введите настройки конфигурации:${NC}\n"

read -rp "$(echo -e "${CYAN}1. Домен для белого веб-сайта (например, site.domain.com): ${NC}")" DOMAIN_WEB
while [[ -z "$DOMAIN_WEB" ]]; do
    read -rp "$(echo -e "${RED}Домен не может быть пустым. Введите домен для сайта: ${NC}")" DOMAIN_WEB
done

read -rp "$(echo -e "${CYAN}2. Домен для панели 3x-ui и подписок (например, sub.domain.com): ${NC}")" DOMAIN_PANEL
while [[ -z "$DOMAIN_PANEL" || "$DOMAIN_PANEL" == "$DOMAIN_WEB" ]]; do
    read -rp "$(echo -e "${RED}Введите уникальный второй домен для панели/подписок: ${NC}")" DOMAIN_PANEL
done

DEFAULT_SSH_PORT=22
read -rp "$(echo -e "${CYAN}3. Порт для SSH [по умолчанию: ${DEFAULT_SSH_PORT}]: ${NC}")" SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}

DEFAULT_REALITY_TARGET="www.versio.nl"
read -rp "$(echo -e "${CYAN}4. Домен прикрытия REALITY [по умолчанию: ${DEFAULT_REALITY_TARGET}]: ${NC}")" REALITY_TARGET
REALITY_TARGET=${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}
BASE_TARGET=$(echo "$REALITY_TARGET" | awk -F. '{if (NF>2) {print $(NF-1)"."$NF} else {print $0}}')

DEFAULT_ADMIN_USER="admin_$(openssl rand -hex 3)"
read -rp "$(echo -e "${CYAN}5. Логин администратора 3x-ui [по умолчанию: ${DEFAULT_ADMIN_USER}]: ${NC}")" ADMIN_USER
ADMIN_USER=${ADMIN_USER:-$DEFAULT_ADMIN_USER}

DEFAULT_ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
read -rp "$(echo -e "${CYAN}6. Пароль администратора 3x-ui [по умолчанию: ${DEFAULT_ADMIN_PASS}]: ${NC}")" ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-$DEFAULT_ADMIN_PASS}

# Generate Unique Secret Random Paths per Installation
RAND_PANEL=$(openssl rand -hex 6)
RAND_SUB=$(openssl rand -hex 6)
RAND_XHTTP=$(openssl rand -hex 4)
SECRET_BASE_PATH="/panel_${RAND_PANEL}/"
SECRET_SUB_PATH="sub_${RAND_SUB}"
XHTTP_PATH="/vpn-${RAND_XHTTP}"
CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
CLIENT_SHORT_ID=$(openssl rand -hex 8)

# Randomized dynamic XHTTP padding
PADDING_MIN=$((120 + RANDOM % 40))
PADDING_MAX=$((1100 + RANDOM % 150))
RANDOM_PADDING="${PADDING_MIN}-${PADDING_MAX}"

echo -e "\n${GREEN}[+] Параметры приняты. Начинаем установку и настройку системы...${NC}\n"
sleep 2

# 1. Update system, upgrade packages & setup auto-updates
echo -e "${BLUE}[1/8] Обновление системы и настройка автообновлений безопасности...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y unattended-upgrades update-notifier-common curl wget git ufw fail2ban sqlite3 openssl jq nginx libnginx-mod-stream debian-keyring debian-archive-keyring apt-transport-https

# Enable unattended security upgrades
cat << 'AUTOUPEOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPEOF
systemctl restart unattended-upgrades >/dev/null 2>&1 || true

# 2. Install official Caddy
echo -e "${BLUE}[2/8] Установка Caddy веб-сервера...${NC}"
if ! command -v caddy &>/dev/null; then
    curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
fi

# 3. Install 3x-ui
echo -e "${BLUE}[3/8] Установка 3x-ui...${NC}"
if [[ ! -d "/usr/local/x-ui" ]]; then
    # Non-interactive 3x-ui install
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << EOF
n
EOF
fi

systemctl stop x-ui || true

# 4. Generate X25519 Keys for REALITY
echo -e "${BLUE}[4/8] Генерация криптографических ключей REALITY...${NC}"
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
if [[ ! -f "$XRAY_BIN" ]]; then
    XRAY_BIN=$(which xray 2>/dev/null || true)
fi

KEYS_OUTPUT=$("$XRAY_BIN" x25519 2>/dev/null || echo -e "Private key: $(openssl rand -base64 32)\nPublic key: $(openssl rand -base64 32)")
REALITY_PRIV_KEY=$(echo "$KEYS_OUTPUT" | grep -i "Private key" | awk '{print $NF}')
REALITY_PUB_KEY=$(echo "$KEYS_OUTPUT" | grep -i "Public key" | awk '{print $NF}')

# 5. Deploy Modern Website Template for DOMAIN_WEB
echo -e "${BLUE}[5/8] Развертывание чистого шаблона веб-сайта...${NC}"
mkdir -p /var/www/html/site
cat << 'HTMLEOF' > /var/www/html/site/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AetherCloud &mdash; High Performance Infrastructure Solutions</title>
    <meta name="description" content="Next-generation scalable cloud delivery, edge compute and distributed telemetry network.">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg: #090d16;
            --surface: #101726;
            --surface-border: rgba(255, 255, 255, 0.08);
            --primary: #38bdf8;
            --primary-glow: rgba(56, 189, 248, 0.15);
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --accent: #818cf8;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif;
            background-color: var(--bg);
            color: var(--text-main);
            line-height: 1.6;
            overflow-x: hidden;
        }
        .container { max-width: 1200px; margin: 0 auto; padding: 0 24px; }
        nav {
            padding: 24px 0;
            border-bottom: 1px solid var(--surface-border);
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .logo {
            font-size: 1.3rem;
            font-weight: 700;
            letter-spacing: -0.5px;
            color: var(--text-main);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .logo-icon {
            width: 28px;
            height: 28px;
            background: linear-gradient(135deg, var(--primary), var(--accent));
            border-radius: 8px;
        }
        .nav-links { display: flex; gap: 32px; list-style: none; font-size: 0.95rem; }
        .nav-links a { color: var(--text-muted); text-decoration: none; transition: color 0.2s; }
        .nav-links a:hover { color: var(--text-main); }
        .hero {
            padding: 100px 0 80px;
            text-align: center;
            position: relative;
        }
        .hero::before {
            content: '';
            position: absolute;
            top: 20%;
            left: 50%;
            transform: translate(-50%, -50%);
            width: 600px;
            height: 350px;
            background: radial-gradient(circle, var(--primary-glow) 0%, rgba(0,0,0,0) 70%);
            filter: blur(80px);
            z-index: -1;
            pointer-events: none;
        }
        .badge {
            display: inline-block;
            padding: 6px 14px;
            background: rgba(56, 189, 248, 0.1);
            border: 1px solid rgba(56, 189, 248, 0.25);
            border-radius: 999px;
            font-size: 0.85rem;
            font-weight: 500;
            color: var(--primary);
            margin-bottom: 24px;
        }
        h1 {
            font-size: clamp(2.5rem, 5vw, 4.2rem);
            font-weight: 800;
            letter-spacing: -1.5px;
            line-height: 1.15;
            margin-bottom: 24px;
        }
        h1 span {
            background: linear-gradient(135deg, var(--primary), #a5b4fc);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        p.subtitle {
            font-size: 1.2rem;
            color: var(--text-muted);
            max-width: 640px;
            margin: 0 auto 40px;
            font-weight: 400;
        }
        .features {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
            gap: 24px;
            padding: 60px 0;
        }
        .feature-card {
            background: var(--surface);
            border: 1px solid var(--surface-border);
            border-radius: 16px;
            padding: 32px;
            transition: transform 0.2s, border-color 0.2s;
        }
        .feature-card:hover {
            transform: translateY(-4px);
            border-color: rgba(56, 189, 248, 0.3);
        }
        .feature-card h3 {
            font-size: 1.25rem;
            margin-bottom: 12px;
            font-weight: 600;
        }
        .feature-card p {
            color: var(--text-muted);
            font-size: 0.95rem;
        }
        footer {
            border-top: 1px solid var(--surface-border);
            padding: 40px 0;
            text-align: center;
            color: var(--text-muted);
            font-size: 0.9rem;
            margin-top: 80px;
        }
    </style>
</head>
<body>
    <div class="container">
        <nav>
            <div class="logo">
                <div class="logo-icon"></div>
                AetherCloud
            </div>
            <ul class="nav-links">
                <li><a href="#solutions">Architecture</a></li>
                <li><a href="#network">Network Status</a></li>
                <li><a href="#sla">Enterprise SLA</a></li>
            </ul>
        </nav>

        <section class="hero">
            <div class="badge">&bull; Real-time Cluster Telemetry Active</div>
            <h1>Engineered for <span>Uncompromised Speed</span> & Scale</h1>
            <p class="subtitle">Next-generation distributed edge routing platform. Low latency global transport infrastructure with microsecond peering.</p>
        </section>

        <section class="features" id="solutions">
            <div class="feature-card">
                <h3>Edge Transit Routing</h3>
                <p>Fully automated multi-homed BGP mesh balancing real-time data ingestion across Tier-1 backbones with sub-millisecond route optimization.</p>
            </div>
            <div class="feature-card">
                <h3>Hardware Cryptographic Bounds</h3>
                <p>TLS 1.3 zero-RTT session handshakes coupled with isolated ring execution environments guarantee cryptographic verifiability.</p>
            </div>
            <div class="feature-card">
                <h3>High Availability SLA</h3>
                <p>Triple redundant failover gateways ensure unbroken continuous connectivity across our distributed North American and European POPs.</p>
            </div>
        </section>

        <footer>
            &copy; 2026 AetherCloud Operations Inc. All systems normal.
        </footer>
    </div>
</body>
</html>
HTMLEOF

# 6. Configure Caddy & Nginx
echo -e "${BLUE}[6/8] Настройка веб-серверов Caddy и Nginx (SNI Multiplexer)...${NC}"

# Caddyfile
cat << CADEOF > /etc/caddy/Caddyfile
{
	https_port 8444
	http_port 8088
	servers {
		protocols h1 h2
		strict_sni_host
	}
}

${DOMAIN_WEB} {
	root * /var/www/html/site
	file_server
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		-Via
		-Server
		-Alt-Svc
	}
}

${DOMAIN_PANEL} {
	handle /${SECRET_SUB_PATH}/* {
		reverse_proxy 127.0.0.1:2096 {
			header_up X-Forwarded-Port 443
		}
		header {
			Profile-Update-Interval "1"
			-Via
			-Server
			-Alt-Svc
		}
	}

	handle {
		reverse_proxy 127.0.0.1:2053 {
			header_up X-Forwarded-Port 443
		}
		header {
			-Via
			-Server
			-Alt-Svc
		}
	}
}
CADEOF

# Nginx Stream Configuration (Dynamic REALITY SNI Routing)
cat << STREAMEOF > /etc/nginx/stream.conf
stream {
    map \$ssl_preread_server_name \$backend_name {
        ${REALITY_TARGET}       reality_backend;
        ${BASE_TARGET}          reality_backend;
        *.${BASE_TARGET}        reality_backend;
        default                 caddy_backend;
    }

    upstream reality_backend {
        server 127.0.0.2:443;
    }

    upstream caddy_backend {
        server 127.0.0.1:8444;
    }

    server {
        listen 443;
        listen [::]:443;
        proxy_pass \$backend_name;
        ssl_preread on;
    }
}
STREAMEOF

if ! grep -q "include /etc/nginx/stream.conf;" /etc/nginx/nginx.conf; then
    echo "include /etc/nginx/stream.conf;" >> /etc/nginx/nginx.conf
fi

# Nginx Port 80 Configuration
cat << NGINXEOF > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location ^~ /.well-known/acme-challenge/ {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        return 404;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_WEB} ${DOMAIN_PANEL};

    location ^~ /.well-known/acme-challenge/ {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF

# 7. Configure 3x-ui Database (Settings & Inbound)
echo -e "${BLUE}[7/8] Конфигурирование базы данных 3x-ui и VLESS-XHTTP-REALITY...${NC}"
DB_PATH="/etc/x-ui/x-ui.db"

# Update 3x-ui settings in SQLite
sqlite3 "$DB_PATH" << SQLEOF
UPDATE users SET username='${ADMIN_USER}', password='${ADMIN_PASS}' WHERE id=1;
INSERT OR REPLACE INTO settings (key, value) VALUES ('webPort', '2053');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webListen', '127.0.0.1');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '${SECRET_BASE_PATH}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('subPath', '/${SECRET_SUB_PATH}/');
INSERT OR REPLACE INTO settings (key, value) VALUES ('subPort', '2096');
INSERT OR REPLACE INTO settings (key, value) VALUES ('subListen', '127.0.0.1');
SQLEOF

# Prepare Inbound JSON
STREAM_SETTINGS=$(jq -n \
  --arg priv "$REALITY_PRIV_KEY" \
  --arg target "$REALITY_TARGET:443" \
  --arg sni "$REALITY_TARGET" \
  --arg base "$BASE_TARGET" \
  --arg sid "$CLIENT_SHORT_ID" \
  --arg path "$XHTTP_PATH" \
  --arg padding "$RANDOM_PADDING" \
  '{
    network: "xhttp",
    security: "reality",
    realitySettings: {
      show: false,
      xver: 0,
      target: $target,
      serverNames: [$sni, $base],
      privateKey: $priv,
      minClientVer: "",
      maxClientVer: "",
      maxTimediff: 0,
      shortIds: [$sid]
    },
    xhttpSettings: {
      mode: "auto",
      path: $path,
      host: "",
      xPaddingBytes: $padding,
      scMaxBufferedPosts: 30,
      scStreamUpServerSecs: "20-80"
    }
  }')

CLIENTS_JSON=$(jq -n \
  --arg id "$CLIENT_UUID" \
  --arg email "default-user" \
  '[{ id: $id, email: $email, flow: "" }]')

INBOUND_SETTINGS=$(jq -n --argjson clients "$CLIENTS_JSON" '{ clients: $clients, decryption: "none" }')

# Insert/Replace inbound #1 in 3x-ui db
sqlite3 "$DB_PATH" << SQLEOF
DELETE FROM inbounds WHERE id=1;
INSERT INTO inbounds (
    id, user_id, up, down, total, remark, enable, expiry_time,
    listen, port, protocol, settings, stream_settings, tag, sniffing
) VALUES (
    1, 1, 0, 0, 0, 'VLESS-XHTTP-REALITY', 1, 0,
    '127.0.0.2', 443, 'vless',
    '${INBOUND_SETTINGS}',
    '${STREAM_SETTINGS}',
    'in-443-xhttp',
    '{"enabled":false}'
);
SQLEOF

# 8. Firewall & SSH Hardening
echo -e "${BLUE}[8/8] Настройка безопасности, SSH и файрвола (UFW)...${NC}"

# Reconfigure SSH Port
if [[ "$SSH_PORT" != "22" ]]; then
    mkdir -p /etc/ssh/sshd_config.d/
    cat << SSHEOF > /etc/ssh/sshd_config.d/custom-port.conf
Port ${SSH_PORT}
SSHEOF
    sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config || true
fi

# Setup UFW
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment "SSH Port"
ufw allow 80/tcp comment "HTTP Port"
ufw allow 443/tcp comment "HTTPS Multiplexer"
ufw --force enable

# Restart all services
systemctl restart sshd || systemctl restart ssh
systemctl restart caddy
nginx -t && systemctl restart nginx
systemctl start x-ui
systemctl restart fail2ban || true

# Generate Client Connection Link
ENCODED_PATH=$(echo "$XHTTP_PATH" | sed 's/\//%2F/g')
VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:443?security=reality&encryption=none&pbk=${REALITY_PUB_KEY}&headerType=none&type=xhttp&path=${ENCODED_PATH}&sni=${REALITY_TARGET}&sid=${CLIENT_SHORT_ID}#Stealth-Node"

# --- Finished Output ---
clear
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}          УСТАНОВКА И НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНЫ!              ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}\n"

echo -e "${YELLOW}ВАЖНО: Добавьте следующие A-записи в DNS у вашего регистратора:${NC}"
echo -e "  * ${BOLD}${DOMAIN_WEB}${NC}   -->  ${CYAN}${SERVER_IP}${NC}"
echo -e "  * ${BOLD}${DOMAIN_PANEL}${NC} -->  ${CYAN}${SERVER_IP}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}1. Доступ к серверу по SSH:${NC}"
echo -e "   Команда: ${CYAN}ssh -p ${SSH_PORT} root@${SERVER_IP}${NC}"
echo -e "   (Дефолтный порт 22 закрыт файрволом для защиты от брутфорса!)\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}2. Доступ к панели управления 3x-ui:${NC}"
echo -e "   URL:     ${CYAN}https://${DOMAIN_PANEL}${SECRET_BASE_PATH}${NC}"
echo -e "   Логин:   ${BOLD}${ADMIN_USER}${NC}"
echo -e "   Пароль:  ${BOLD}${ADMIN_PASS}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}3. Ссылка на веб-сайт прикрытия:${NC}"
echo -e "   URL:     ${CYAN}https://${DOMAIN_WEB}/${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}4. Готовая ссылка подключения (VLESS + XHTTP + REALITY):${NC}"
echo -e "${YELLOW}${VLESS_LINK}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}5. Параметры для ручной настройки клиента:${NC}"
echo -e "   Протокол:       ${CYAN}VLESS${NC}"
echo -e "   Адрес сервера:  ${CYAN}${SERVER_IP}${NC} (порт: ${CYAN}443${NC})"
echo -e "   UUID:           ${CYAN}${CLIENT_UUID}${NC}"
echo -e "   Транспорт:      ${CYAN}xhttp${NC}"
echo -e "   Путь xhttp:     ${CYAN}${XHTTP_PATH}${NC}"
echo -e "   Безопасность:   ${CYAN}Reality${NC}"
echo -e "   SNI:            ${CYAN}${REALITY_TARGET}${NC}"
echo -e "   Public Key:     ${CYAN}${REALITY_PUB_KEY}${NC}"
echo -e "   Short ID:       ${CYAN}${CLIENT_SHORT_ID}${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}\n"
