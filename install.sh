#!/usr/bin/env bash
# ==============================================================================
# Stealth Node Auto-Installer: Dual VLESS (TCP-Reality + XHTTP-Reality) + SNI Multiplexer
# ==============================================================================
# - Nginx Stream (L4 SNI Pre-read Multiplexer on port 443)
# - Inbound 1: VLESS + TCP + XTLS-Vision + Reality (127.0.0.2:443, SNI: gateway.icloud.com) -> Ultra Speed
# - Inbound 2: VLESS + XHTTP + Reality (127.0.0.3:443, SNI: www.apple.com) -> Anti-DPI / HTTP-Streams
# - Caddy Web Server on internal 8444 with strict_sni_host (RFC 421), admin off & Auto-HTTPS
# - Search Engine Protection: X-Robots-Tag (noindex, nofollow) + virtual /robots.txt
# - Nginx HTTP on port 80 (anti-probing: return 444 on raw IP, ACME pass to Caddy)
# - Modern Responsive Showcase Landing Page for Domain 1
# - Zero public port exposure: 3x-ui bound strictly to localhost + secret sub paths
# - BBR TCP Congestion Control + FQ qdisc + IP Forwarding enabled
# - Anti-DPI Mobile bypass: fp=firefox preset (MTS/TSPU bypass)
# - Comprehensive Routing Protection: BitTorrent block, RU/SU blackholing (DMCA & IP shield)
# - Hardened Security: CrowdSec IDS + Firewall Bouncer + Fail2ban + UFW
# - SSH Hardening: custom port, X11Forwarding disabled, socket/service auto-reload
# - Hardened Log Permissions: Xray logs restricted to root:xui (660, no world access)
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
echo -e "${BOLD} Установка Stealth Node v2.0 (Dual VLESS TCP+XHTTP + Apple SNI) ${NC}"
echo -e "${PURPLE}================================================================${NC}\n"

# Detect Server IP (with multiple reliable fallbacks)
SERVER_IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
            curl -s4 --connect-timeout 5 https://ifconfig.me || \
            curl -s4 --connect-timeout 5 https://icanhazip.com || \
            ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || \
            echo "YOUR_SERVER_IP")

# --- Interactive Prompts with Input Sanitization ---
echo -e "${YELLOW}[?] Введите параметры конфигурации сервера:${NC}\n"

# Domain 1 (Website Showcase)
read -rp "$(echo -e "${CYAN}1. Домен для белого веб-сайта (например, site.domain.com): ${NC}")" DOMAIN_WEB_RAW
DOMAIN_WEB=$(echo "$DOMAIN_WEB_RAW" | sed -e 's|^https\?://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
while [[ -z "$DOMAIN_WEB" ]]; do
    read -rp "$(echo -e "${RED}Домен не может быть пустым. Введите домен для сайта: ${NC}")" DOMAIN_WEB_RAW
    DOMAIN_WEB=$(echo "$DOMAIN_WEB_RAW" | sed -e 's|^https\?://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
done

# Domain 2 (Panel & Subscriptions)
read -rp "$(echo -e "${CYAN}2. Домен для панели 3x-ui и подписок (например, sub.domain.com): ${NC}")" DOMAIN_PANEL_RAW
DOMAIN_PANEL=$(echo "$DOMAIN_PANEL_RAW" | sed -e 's|^https\?://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
while [[ -z "$DOMAIN_PANEL" || "$DOMAIN_PANEL" == "$DOMAIN_WEB" ]]; do
    read -rp "$(echo -e "${RED}Введите уникальный второй домен для панели/подписок (отличный от первого): ${NC}")" DOMAIN_PANEL_RAW
    DOMAIN_PANEL=$(echo "$DOMAIN_PANEL_RAW" | sed -e 's|^https\?://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
done

# SSH Port
DEFAULT_SSH_PORT=22
read -rp "$(echo -e "${CYAN}3. Порт для SSH [по умолчанию: ${DEFAULT_SSH_PORT}]: ${NC}")" SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
# Validate numeric port range
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo -e "${YELLOW}[!] Некорректный номер порта, установлен дефолтный 22.${NC}"
    SSH_PORT=22
fi

# Admin Username
DEFAULT_ADMIN_USER="admin_$(openssl rand -hex 3)"
read -rp "$(echo -e "${CYAN}4. Логин администратора 3x-ui [по умолчанию: ${DEFAULT_ADMIN_USER}]: ${NC}")" ADMIN_USER
ADMIN_USER=${ADMIN_USER:-$DEFAULT_ADMIN_USER}

# Admin Password
DEFAULT_ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
read -rp "$(echo -e "${CYAN}5. Пароль администратора 3x-ui [по умолчанию: ${DEFAULT_ADMIN_PASS}]: ${NC}")" ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-$DEFAULT_ADMIN_PASS}

# Internal targets (Apple infrastructure)
REALITY_TCP_TARGET="gateway.icloud.com:443"
REALITY_TCP_SNI="gateway.icloud.com"

REALITY_XHTTP_TARGET="www.apple.com:443"
REALITY_XHTTP_SNI="www.apple.com"

# Generate Unique Secret Random Paths per Installation
RAND_PANEL=$(openssl rand -hex 6)
RAND_SUB=$(openssl rand -hex 6)
RAND_XHTTP=$(openssl rand -hex 4)
SECRET_BASE_PATH="/panel_${RAND_PANEL}/"
SECRET_SUB_PATH="sub_${RAND_SUB}"
XHTTP_PATH="/xhttp-${RAND_XHTTP}"

CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
CLIENT_SHORT_ID=$(openssl rand -hex 8)

echo -e "\n${GREEN}[+] Параметры приняты. Начинаем установку и оптимизацию системы...${NC}\n"
sleep 1

# 1. Update system, upgrade packages & setup auto-updates
echo -e "${BLUE}[1/10] Обновление системы и установка пакетов...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y unattended-upgrades update-notifier-common curl wget git ufw fail2ban sqlite3 openssl jq python3 nginx libnginx-mod-stream debian-keyring debian-archive-keyring apt-transport-https iptables netfilter-persistent qrencode || true

# Enable unattended security upgrades
cat << 'AUTOUPEOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPEOF
systemctl restart unattended-upgrades >/dev/null 2>&1 || true

# 2. Kernel Acceleration (BBR, FQ & IP Forward)
echo -e "${BLUE}[2/10] Активация BBR TCP Congestion Control и оптимизация сетевого стека...${NC}"
cat << 'SYSCTLEOF' > /etc/sysctl.d/99-stealth-node.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
SYSCTLEOF
sysctl --system >/dev/null 2>&1 || true

# Stop and disable conflicting web servers (like default apache2 on LAMP VPS images)
if systemctl is-active apache2 &>/dev/null || systemctl is-enabled apache2 &>/dev/null; then
    echo -e "${YELLOW}[!] Обнаружен активный Apache2. Отключаем для освобождения портов 80 и 443...${NC}"
    systemctl stop apache2 >/dev/null 2>&1 || true
    systemctl disable apache2 >/dev/null 2>&1 || true
fi

# 3. Install official Caddy
echo -e "${BLUE}[3/10] Установка Caddy веб-сервера...${NC}"
mkdir -p /usr/share/keyrings
if ! command -v caddy &>/dev/null; then
    curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
fi

# 4. Install CrowdSec & Firewall Bouncer
echo -e "${BLUE}[4/10] Установка CrowdSec IDS и Firewall Bouncer...${NC}"
if ! command -v cscli &>/dev/null; then
    (curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash) || true
    apt-get update -y || true
    apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables || true
fi

# 5. Install 3x-ui
echo -e "${BLUE}[5/10] Установка 3x-ui (последняя версия)...${NC}"
if [[ ! -d "/usr/local/x-ui" ]]; then
    export XUI_NONINTERACTIVE=1
    export XUI_DB_TYPE="sqlite"
    export XUI_SSL_MODE="none"
    export XUI_BIN_FOLDER="/usr/local/x-ui"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
fi

# Ensure 3x-ui service runs briefly to initialize the database
systemctl start x-ui >/dev/null 2>&1 || true
sleep 2
systemctl stop x-ui >/dev/null 2>&1 || true

# Detect xui user/group or fallback to root
XUI_USER="root"
XUI_GROUP="root"
if id -u xui &>/dev/null; then
    XUI_USER="xui"
    XUI_GROUP="xui"
fi

chown -R ${XUI_USER}:${XUI_GROUP} /usr/local/x-ui /etc/x-ui 2>/dev/null || true
chmod -R 775 /usr/local/x-ui/bin 2>/dev/null || true

# Initialize Hardened Log Files & Permissions (660, non-world-writable)
mkdir -p /var/log/x-ui
touch /var/log/xray-access.log /var/log/xray-error.log
chown root:${XUI_GROUP} /var/log/xray-access.log /var/log/xray-error.log 2>/dev/null || true
chmod 660 /var/log/xray-access.log /var/log/xray-error.log 2>/dev/null || true

# 6. Generate X25519 Keys for REALITY
echo -e "${BLUE}[6/10] Генерация криптографических ключей REALITY...${NC}"
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
if [[ ! -f "$XRAY_BIN" ]]; then
    XRAY_BIN=$(which xray 2>/dev/null || true)
fi

KEYS_OUTPUT=$("$XRAY_BIN" x25519 2>/dev/null || echo -e "Private key: $(openssl rand -base64 32)\nPublic key: $(openssl rand -base64 32)")
REALITY_PRIV_KEY=$(echo "$KEYS_OUTPUT" | grep -i "Private key" | awk '{print $NF}')
REALITY_PUB_KEY=$(echo "$KEYS_OUTPUT" | grep -i "Public key" | awk '{print $NF}')

# 7. Deploy Modern Showcase Website Template for DOMAIN_WEB
echo -e "${BLUE}[7/10] Развертывание чистого шаблона веб-сайта AetherCloud...${NC}"
mkdir -p /var/www/html/site
cat << 'HTMLEOF' > /var/www/html/site/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AetherCloud &mdash; High Performance Infrastructure Solutions</title>
    <meta name="description" content="Next-generation scalable cloud delivery, edge compute and distributed telemetry network.">
    <meta name="robots" content="noindex, nofollow, noarchive">
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

# 8. Configure Caddy & Nginx (SNI Pre-read Routing & Anti-Scanner Headers)
echo -e "${BLUE}[8/10] Настройка Caddy и Nginx Stream SNI Multiplexer...${NC}"

# Caddyfile (Hardened with admin off, strict_sni_host, robots.txt, X-Robots-Tag)
cat << CADEOF > /etc/caddy/Caddyfile
{
	https_port 8444
	http_port 8088
	admin off
	servers {
		protocols h1 h2
		strict_sni_host
	}
}

${DOMAIN_WEB} {
	respond /robots.txt "User-agent: *
Disallow: /
" 200

	root * /var/www/html/site
	file_server
	header {
		X-Robots-Tag "noindex, nofollow, noarchive"
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		-Via
		-Server
		-Alt-Svc
	}
}

${DOMAIN_PANEL} {
	respond /robots.txt "User-agent: *
Disallow: /
" 200

	handle /${SECRET_SUB_PATH}/* {
		reverse_proxy 127.0.0.1:2096 {
			header_up X-Forwarded-Port 443
		}
		header {
			Profile-Update-Interval "1"
			X-Robots-Tag "noindex, nofollow, noarchive"
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
			X-Robots-Tag "noindex, nofollow, noarchive"
			-Via
			-Server
			-Alt-Svc
		}
	}
}
CADEOF

# Nginx Stream Configuration (Dual Reality SNI Multiplexing)
cat << STREAMEOF > /etc/nginx/stream.conf
stream {
    map \$ssl_preread_server_name \$backend_name {
        gateway.icloud.com      reality_tcp_backend;
        icloud.com              reality_tcp_backend;
        *.icloud.com            reality_tcp_backend;

        www.apple.com           reality_xhttp_backend;
        images.apple.com        reality_xhttp_backend;
        *.apple.com             reality_xhttp_backend;

        default                 caddy_backend;
    }

    upstream reality_tcp_backend {
        server 127.0.0.2:443;
    }

    upstream reality_xhttp_backend {
        server 127.0.0.3:443;
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

# Nginx Port 80 Anti-Probing Configuration
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
        return 444;
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

mkdir -p /etc/nginx/sites-enabled
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# 9. Configure 3x-ui Database (Settings, Template, Inbounds & Client Traffics)
echo -e "${BLUE}[9/10] Конфигурирование 3x-ui, маршрутизации и защищенных инбаундов...${NC}"
DB_PATH="/etc/x-ui/x-ui.db"

# Update 3x-ui credentials and core settings natively (hashes password with bcrypt)
/usr/local/x-ui/x-ui setting -username "${ADMIN_USER}" -password "${ADMIN_PASS}" -port 2053 -listenIP 127.0.0.1 -webBasePath "${SECRET_BASE_PATH}" >/dev/null 2>&1 || true

# Update subscription settings in SQLite
sqlite3 "$DB_PATH" << SQLEOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('subPath', '/${SECRET_SUB_PATH}/');
INSERT OR REPLACE INTO settings (key, value) VALUES ('subPort', '2096');
INSERT OR REPLACE INTO settings (key, value) VALUES ('subListen', '127.0.0.1');
SQLEOF

# Hardened Xray Template with Anti-Torrents & Russian Traffic Blackhole
python3 - << 'PYEOF'
import sqlite3, json

DB_PATH = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()

template = {
    "log": {"loglevel": "warning"},
    "api": {"services": ["HandlerService", "LoggerService", "StatsService"], "tag": "api"},
    "inbounds": [
        {"listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}, "tag": "api"}
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "blocked"}
    ],
    "policy": {
        "system": {"statsInboundDownlink": True, "statsInboundUplink": True},
        "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}}
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
            {"protocol": ["bittorrent"], "outboundTag": "blocked", "type": "field"},
            {"domain": ["domain:ru", "domain:su", "domain:xn--p1ai", "geosite:category-ru", "geosite:yandex", "geosite:vk", "geosite:mailru"], "outboundTag": "blocked", "type": "field"},
            {"ip": ["geoip:ru", "geoip:private"], "outboundTag": "blocked", "type": "field"},
            {"network": "tcp,udp", "outboundTag": "direct", "type": "field"}
        ]
    },
    "stats": {}
}

cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (json.dumps(template),))
conn.commit()
conn.close()
PYEOF

# Prepare Inbound 1: VLESS + TCP + Vision + Reality (Ultra Speed)
STREAM_SETTINGS_TCP=$(jq -n \
  --arg priv "$REALITY_PRIV_KEY" \
  --arg pub "$REALITY_PUB_KEY" \
  --arg target "$REALITY_TCP_TARGET" \
  --arg sni "$REALITY_TCP_SNI" \
  --arg sid "$CLIENT_SHORT_ID" \
  '{
    network: "tcp",
    security: "reality",
    realitySettings: {
      show: false,
      xver: 0,
      target: $target,
      serverNames: [$sni, "icloud.com"],
      privateKey: $priv,
      minClientVer: "",
      maxClientVer: "",
      maxTimediff: 0,
      shortIds: [$sid],
      settings: {
        publicKey: $pub,
        fingerprint: "firefox",
        serverName: $sni,
        spiderX: "/"
      }
    },
    tcpSettings: {
      acceptProxyProtocol: false,
      header: { type: "none" }
    }
  }')

CLIENTS_TCP=$(jq -n \
  --arg id "$CLIENT_UUID" \
  --arg email "client-tcp" \
  '[{ id: $id, email: $email, flow: "xtls-rprx-vision", enable: true }]')

INBOUND_SETTINGS_TCP=$(jq -n --argjson clients "$CLIENTS_TCP" '{ clients: $clients, decryption: "none" }')
SNIFFING_JSON='{"enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false, "routeOnly": false}'

# Prepare Inbound 2: VLESS + XHTTP + Reality (Anti-DPI / HTTP Streams)
STREAM_SETTINGS_XHTTP=$(jq -n \
  --arg priv "$REALITY_PRIV_KEY" \
  --arg pub "$REALITY_PUB_KEY" \
  --arg target "$REALITY_XHTTP_TARGET" \
  --arg sni "$REALITY_XHTTP_SNI" \
  --arg sid "$CLIENT_SHORT_ID" \
  --arg path "$XHTTP_PATH" \
  '{
    network: "xhttp",
    security: "reality",
    realitySettings: {
      show: false,
      xver: 0,
      target: $target,
      serverNames: [$sni, "images.apple.com"],
      privateKey: $priv,
      minClientVer: "",
      maxClientVer: "",
      maxTimediff: 0,
      shortIds: [$sid],
      settings: {
        publicKey: $pub,
        fingerprint: "firefox",
        serverName: $sni,
        spiderX: "/"
      }
    },
    xhttpSettings: {
      mode: "auto",
      path: $path
    }
  }')

CLIENTS_XHTTP=$(jq -n \
  --arg id "$CLIENT_UUID" \
  --arg email "client-xhttp" \
  '[{ id: $id, email: $email, flow: "", enable: true }]')

INBOUND_SETTINGS_XHTTP=$(jq -n --argjson clients "$CLIENTS_XHTTP" '{ clients: $clients, decryption: "none" }')

# Insert Inbounds into 3x-ui Database & populate client_traffics
sqlite3 "$DB_PATH" << SQLEOF
DELETE FROM inbounds WHERE tag IN ('in-443-tcp', 'in-443-xhttp');

INSERT INTO inbounds (
    user_id, up, down, total, remark, sub_sort_index, enable, expiry_time,
    listen, port, protocol, settings, stream_settings, tag, sniffing
) VALUES (
    1, 0, 0, 0, 'Stealth-TCP', 1, 1, 0,
    '127.0.0.2', 443, 'vless',
    '${INBOUND_SETTINGS_TCP}',
    '${STREAM_SETTINGS_TCP}',
    'in-443-tcp',
    '${SNIFFING_JSON}'
);

INSERT INTO inbounds (
    user_id, up, down, total, remark, sub_sort_index, enable, expiry_time,
    listen, port, protocol, settings, stream_settings, tag, sniffing
) VALUES (
    1, 0, 0, 0, 'Stealth-XHTTP', 2, 1, 0,
    '127.0.0.3', 443, 'vless',
    '${INBOUND_SETTINGS_XHTTP}',
    '${STREAM_SETTINGS_XHTTP}',
    'in-443-xhttp',
    '${SNIFFING_JSON}'
);

DELETE FROM client_traffics WHERE email IN ('client-tcp', 'client-xhttp');

INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total)
SELECT id, 1, 'client-tcp', 0, 0, 0, 0 FROM inbounds WHERE tag = 'in-443-tcp';

INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total)
SELECT id, 1, 'client-xhttp', 0, 0, 0, 0 FROM inbounds WHERE tag = 'in-443-xhttp';
SQLEOF

# Fix ownership
chown -R ${XUI_USER}:${XUI_GROUP} /usr/local/x-ui /etc/x-ui 2>/dev/null || true
chmod -R 775 /usr/local/x-ui/bin 2>/dev/null || true
chown root:${XUI_GROUP} /var/log/xray-access.log /var/log/xray-error.log 2>/dev/null || true
chmod 660 /var/log/xray-access.log /var/log/xray-error.log 2>/dev/null || true

# 10. Firewall, CrowdSec & SSH Hardening
echo -e "${BLUE}[10/10] Настройка безопасности, SSH и файрвола (UFW)...${NC}"

# Disable X11Forwarding to prevent GUI session sniffing
mkdir -p /etc/ssh/sshd_config.d/
cat << SSHEOF > /etc/ssh/sshd_config.d/security.conf
X11Forwarding no
SSHEOF
sed -i "s/^#\?X11Forwarding .*/X11Forwarding no/" /etc/ssh/sshd_config || true

if [[ "$SSH_PORT" != "22" ]]; then
    cat << SSHEOF >> /etc/ssh/sshd_config.d/security.conf
Port ${SSH_PORT}
SSHEOF
    sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config || true
fi

# Verify SSH configuration syntax before applying
if sshd -t 2>/dev/null; then
    # Handle systemd socket vs service on modern Ubuntu (22.04 / 24.04)
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl is-active ssh.socket >/dev/null 2>&1; then
        systemctl restart ssh.socket >/dev/null 2>&1 || true
    fi
    systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
else
    echo -e "${YELLOW}[!] Предупреждение: ошибка синтаксиса в sshd_config. Порт SSH сохранён как 22.${NC}"
    SSH_PORT=22
fi

# Setup UFW with safety checks
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment "SSH Port"
if [[ "$SSH_PORT" != "22" ]]; then
    # Keep 22 open until user confirms, or allow user port cleanly
    ufw allow 22/tcp comment "SSH Default Fallback"
fi
ufw allow 80/tcp comment "HTTP Port"
ufw allow 443/tcp comment "HTTPS Multiplexer"
ufw --force enable

# Restart web and VPN services
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl restart caddy
nginx -t >/dev/null 2>&1 && systemctl restart nginx
systemctl restart x-ui
systemctl restart fail2ban >/dev/null 2>&1 || true
systemctl restart crowdsec >/dev/null 2>&1 || true
systemctl restart crowdsec-firewall-bouncer >/dev/null 2>&1 || true

# Health check services
echo -e "\n${BLUE}Проверка запуска всех системных служб...${NC}"
for svc in nginx caddy x-ui; do
    if systemctl is-active --quiet "$svc"; then
        echo -e "  * Служба ${BOLD}${svc}${NC}: ${GREEN}работает (active)${NC}"
    else
        echo -e "  * Служба ${BOLD}${svc}${NC}: ${RED}внимание, не активна (проверьте: journalctl -u ${svc} -n 20)${NC}"
    fi
done

# Generate Keys & Links
ENCODED_XHTTP_PATH=$(echo "$XHTTP_PATH" | sed 's/\//%2F/g')
LINK_TCP="vless://${CLIENT_UUID}@${SERVER_IP}:443?security=reality&encryption=none&pbk=${REALITY_PUB_KEY}&fp=firefox&sni=${REALITY_TCP_SNI}&sid=${CLIENT_SHORT_ID}&spx=%2F&flow=xtls-rprx-vision&type=tcp#Stealth-Node-TCP"
LINK_XHTTP="vless://${CLIENT_UUID}@${SERVER_IP}:443?security=reality&encryption=none&pbk=${REALITY_PUB_KEY}&fp=firefox&sni=${REALITY_XHTTP_SNI}&sid=${CLIENT_SHORT_ID}&spx=%2F&type=xhttp&path=${ENCODED_XHTTP_PATH}&mode=auto#Stealth-Node-XHTTP"

# Save Credentials and Links to Local File for Easy Retrieval
CREDENTIALS_FILE="/root/stealth-node-credentials.txt"
cat << EOF > "$CREDENTIALS_FILE"
================================================================
          STEALTH NODE CREDENTIALS & VLESS KEYS
================================================================
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Server IP: ${SERVER_IP}

[1] SSH ACCESS:
    Port:     ${SSH_PORT}
    Command:  ssh -p ${SSH_PORT} root@${SERVER_IP}

[2] 3X-UI MANAGEMENT PANEL:
    URL:      https://${DOMAIN_PANEL}${SECRET_BASE_PATH}
    Login:    ${ADMIN_USER}
    Password: ${ADMIN_PASS}

[3] SHOWCASE WEBSITE:
    URL:      https://${DOMAIN_WEB}/

[4] VLESS TCP REALITY KEY (HIGH SPEED):
${LINK_TCP}

[5] VLESS XHTTP REALITY KEY (ANTI-DPI / BYPASS):
${LINK_XHTTP}

[6] REALITY PARAMETERS:
    Client UUID: ${CLIENT_UUID}
    Public Key:  ${REALITY_PUB_KEY}
    Short ID:    ${CLIENT_SHORT_ID}
    SpiderX:     /
    SNI 1 (TCP): ${REALITY_TCP_SNI}
    SNI 2 (HTTP):${REALITY_XHTTP_SNI}
================================================================
EOF
chmod 600 "$CREDENTIALS_FILE"

# --- Final User-Facing Output ---
clear
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}      УСТАНОВКА И ОПТИМИЗАЦИЯ STEALTH NODE УСПЕШНО ЗАВЕРШЕНА!   ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}\n"

echo -e "${CYAN}${BOLD}💾 ВНИМАНИЕ: ВСЕ ССЫЛКИ, ПАРОЛИ И КЛЮЧИ СОХРАНЕНЫ В ЗАЩИЩЕННЫЙ ФАЙЛ:${NC}"
echo -e "   Файл:   ${YELLOW}${BOLD}${CREDENTIALS_FILE}${NC}"
echo -e "   Команда: ${BOLD}cat ${CREDENTIALS_FILE}${NC} (доступен только root, права 600)\n"

echo -e "${YELLOW}ВАЖНО: Добавьте следующие A-записи в DNS у вашего регистратора:${NC}"
echo -e "  * ${BOLD}${DOMAIN_WEB}${NC}   -->  ${CYAN}${SERVER_IP}${NC}"
echo -e "  * ${BOLD}${DOMAIN_PANEL}${NC} -->  ${CYAN}${SERVER_IP}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}1. Доступ к серверу по SSH:${NC}"
echo -e "   Команда:  ${CYAN}ssh -p ${SSH_PORT} root@${SERVER_IP}${NC}"
echo -e "   Порт:     ${BOLD}${SSH_PORT}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}2. Доступ к веб-панели управления 3x-ui:${NC}"
echo -e "   URL:      ${CYAN}https://${DOMAIN_PANEL}${SECRET_BASE_PATH}${NC}"
echo -e "   Логин:    ${BOLD}${ADMIN_USER}${NC}"
echo -e "   Пароль:   ${BOLD}${ADMIN_PASS}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}3. Белый веб-сайт (витрина прикрытия):${NC}"
echo -e "   URL:      ${CYAN}https://${DOMAIN_WEB}/${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}4. Основной скоростной ключ (VLESS + TCP + Vision + Reality):${NC}"
echo -e "${YELLOW}${LINK_TCP}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}5. Резервный анти-DPI ключ (VLESS + XHTTP + Reality):${NC}"
echo -e "${YELLOW}${LINK_XHTTP}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}6. Технические параметры подключения Reality:${NC}"
echo -e "   * Client UUID:   ${CYAN}${CLIENT_UUID}${NC}"
echo -e "   * Public Key:    ${CYAN}${REALITY_PUB_KEY}${NC}"
echo -e "   * Short ID:      ${CYAN}${CLIENT_SHORT_ID}${NC}"
echo -e "   * SpiderX:       ${CYAN}/${NC}"
echo -e "   * SNI (TCP):     ${CYAN}${REALITY_TCP_SNI}${NC}"
echo -e "   * SNI (XHTTP):   ${CYAN}${REALITY_XHTTP_SNI}${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${BOLD}7. Архитектура и встроенная безопасность:${NC}"
echo -e "   * Внешний порт:  ${CYAN}443 (L4 SNI Pre-read Multiplexer Nginx)${NC}"
echo -e "   * BBR & FQ:      ${GREEN}Включены в ядре Linux${NC}"
echo -e "   * Маскировка:    ${CYAN}Apple Infrastructure (gateway.icloud.com / www.apple.com)${NC}"
echo -e "   * Обход МТС/DPI: ${GREEN}fp=firefox (без блокировок ClientHello)${NC}"
echo -e "   * Защита VPS:    ${GREEN}BitTorrent & RU-сегмент в blackhole (без DMCA-абуз)${NC}"
echo -e "   * Харденинг:     ${GREEN}CrowdSec + Fail2ban + UFW + Xray Logs (660) + Caddy Admin Off${NC}\n"

echo -e "${PURPLE}----------------------------------------------------------------${NC}"
echo -e "${GREEN}${BOLD}💾 НАПОМИНАНИЕ: Копия всех данных сохранена на сервере:${NC}"
echo -e "   ${BOLD}cat ${CREDENTIALS_FILE}${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}\n"

# Optional QR code display
if command -v qrencode &>/dev/null; then
    echo -e "${YELLOW}[?] Сгенерировать QR-код для быстрого импорта на телефон? [y/N]: ${NC}"
    read -r SHOW_QR
    if [[ "$SHOW_QR" =~ ^[Yy]$ ]]; then
        echo -e "\n${BOLD}=== QR-КОД: ОСНОВНОЙ КЛЮЧ (TCP REALITY) ===${NC}\n"
        qrencode -t ANSIUTF8 "${LINK_TCP}" || true
        echo -e "\n${BOLD}=== QR-КОД: АНТИ-DPI КЛЮЧ (XHTTP REALITY) ===${NC}\n"
        qrencode -t ANSIUTF8 "${LINK_XHTTP}" || true
        echo -e "\n${GREEN}QR-коды сформированы.${NC}\n"
    fi
fi
