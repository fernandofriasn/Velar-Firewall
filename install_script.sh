#!/usr/bin/env bash
# =============================================================================
# Velar Router — Install Script
# Debian 12 (Bookworm) — Fresh install
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}✓${NC} $1"; }
info()   { echo -e "${CYAN}▶${NC} $1"; }
warn()   { echo -e "${YELLOW}⚠${NC} $1"; }
die()    { echo -e "${RED}✗ ERROR:${NC} $1"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}"; }

# ── Root check ────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Este script debe ejecutarse como root"
[[ ! -f /etc/debian_version ]] && die "Solo Debian 12 (Bookworm) es soportado"
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
[[ "$DEBIAN_VERSION" != "12" ]] && die "Se requiere Debian 12, detectado: $DEBIAN_VERSION"

echo -e "${BOLD}"
cat << 'BANNER'
 __   __   _
 \ \ / /__| | __ _ _ _
  \ V / -_) |/ _` | '_|
   \_/\___|_|\__,_|_|

  Router Management Panel
BANNER
echo -e "${NC}"
echo "  Instalador para Debian 12 (Bookworm)"
echo "  ─────────────────────────────────────"
echo

# ── Configuración interactiva ─────────────────────────────
header "Configuración de red"

read -p "  Interfaz WAN (ej: eth0, ens18): " WAN_IFACE < /dev/tty
read -p "  Interfaz LAN (ej: eth1, ens19): " LAN_IFACE < /dev/tty
read -p "  Subred VPN WireGuard (ej: 10.255.255.0/24): " WG_SUBNET < /dev/tty
WG_SERVER_IP=$(python3 -c "import ipaddress; net=ipaddress.ip_network('$WG_SUBNET',strict=False); print(str(list(net.hosts())[0]))")
WG_PREFIX=$(python3 -c "import ipaddress; net=ipaddress.ip_network('$WG_SUBNET',strict=False); print(net.prefixlen)")

header "Configuración del panel"

read -p "  Usuario administrador [admin]: " ADMIN_USER < /dev/tty
ADMIN_USER=${ADMIN_USER:-admin}
read -s -p "  Contraseña administrador: " ADMIN_PASS < /dev/tty
echo
read -s -p "  Confirmar contraseña: " ADMIN_PASS2 < /dev/tty
echo
[[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]] && die "Las contraseñas no coinciden"

read -p "  Contraseña para MariaDB root: " DB_ROOT_PASS < /dev/tty
read -p "  Puerto API (default: 8000): " API_PORT < /dev/tty
API_PORT=${API_PORT:-8000}

INSTALL_DIR="/opt/velar"
API_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
WG_KEY=$(python3 -c "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")

echo
info "Iniciando instalación..."
echo "  WAN: $WAN_IFACE | LAN: $LAN_IFACE | VPN: $WG_SUBNET"
echo "  WireGuard IP servidor: ${WG_SERVER_IP}/${WG_PREFIX}"
echo "  Directorio: $INSTALL_DIR"
echo
read -p "¿Continuar? [s/N]: " CONFIRM < /dev/tty
[[ "${CONFIRM,,}" != "s" ]] && die "Instalación cancelada"

LOG="/var/log/velar-install.log"
exec > >(tee -a "$LOG") 2>&1
echo "Instalación iniciada: $(date)"

# ═════════════════════════════════════════════════════════
header "0. Descargando Velar desde GitHub"
# ═════════════════════════════════════════════════════════

VELAR_REPO_USER="fernandofriasn"
VELAR_REPO_NAME="Velar-Firewall"
VELAR_BRANCH="main"
VELAR_SRC="/tmp/velar-src"

command -v curl &>/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }

info "Descargando código fuente desde GitHub (${VELAR_REPO_USER}/${VELAR_REPO_NAME})..."
rm -rf "$VELAR_SRC" /tmp/velar-src.tar.gz
mkdir -p "$VELAR_SRC"

if curl -fsSL "https://github.com/${VELAR_REPO_USER}/${VELAR_REPO_NAME}/archive/refs/heads/${VELAR_BRANCH}.tar.gz" \
    -o /tmp/velar-src.tar.gz; then
    tar xzf /tmp/velar-src.tar.gz -C "$VELAR_SRC" --strip-components=1
    rm -f /tmp/velar-src.tar.gz
    ok "Código descargado desde GitHub (rama ${VELAR_BRANCH})"
else
    die "No se pudo descargar el repositorio. Verifica tu conexión a internet."
fi

# ═════════════════════════════════════════════════════════
header "1. Paquetes del sistema"
# ═════════════════════════════════════════════════════════

apt-get update -qq
apt-get install -y -qq \
    curl wget gnupg2 ca-certificates lsb-release \
    python3 python3-pip python3-venv python3-dev python3-psutil \
    build-essential git autoconf automake libtool pkg-config cmake \
    nftables \
    wireguard wireguard-tools \
    unbound \
    squid \
    vnstat \
    qrencode \
    mariadb-server mariadb-client \
    python3-pymysql \
    net-tools iproute2 iputils-ping \
    tcpdump nmap dnsutils bind9-dnsutils \
    nginx \
    openssh-server \
    snmp snmpd \
    vlan \
    jq htop vim rsync \
    logrotate \
    qemu-guest-agent \
    linux-headers-$(uname -r) 2>/dev/null || true
ok "Paquetes base instalados"

# ═════════════════════════════════════════════════════════
header "4. KEA DHCP 2.4.x (repositorio ISC)"
# ═════════════════════════════════════════════════════════

KEA_SVC="isc-kea-dhcp4-server"

if ! dpkg -l isc-kea-dhcp4 &>/dev/null; then
    curl -fsSL https://dl.cloudsmith.io/public/isc/kea-2-4/gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/isc-kea.gpg
    echo "deb [signed-by=/usr/share/keyrings/isc-kea.gpg] https://dl.cloudsmith.io/public/isc/kea-2-4/deb/debian bookworm main" \
        > /etc/apt/sources.list.d/isc-kea.list
    apt-get update -qq
    apt-get install -y -qq isc-kea-dhcp4 isc-kea-common isc-kea-admin
    ok "KEA DHCP instalado"
else
    ok "KEA DHCP ya instalado"
fi

if systemctl list-unit-files | grep -q "isc-kea-dhcp4-server.service"; then
    KEA_SVC="isc-kea-dhcp4-server"
elif systemctl list-unit-files | grep -q "^isc-kea-dhcp4.service"; then
    KEA_SVC="isc-kea-dhcp4"
fi
info "Servicio KEA detectado: $KEA_SVC"

# ═════════════════════════════════════════════════════════
header "5. Rust (requerido para Suricata 8.x)"
# ═════════════════════════════════════════════════════════

export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

if [[ ! -f /usr/local/cargo/bin/rustc ]]; then
    info "Instalando Rust via rustup (~300MB)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y \
            --default-toolchain stable \
            --no-modify-path \
            --profile minimal 2>&1
    ok "Rust $(/usr/local/cargo/bin/rustc --version) instalado"
else
    ok "Rust ya instalado: $(/usr/local/cargo/bin/rustc --version)"
fi

export PATH="/usr/local/cargo/bin:$PATH"
info "Rust version: $(/usr/local/cargo/bin/rustc --version)"

# ═════════════════════════════════════════════════════════
header "6. Suricata 8.0.3 (compilación desde fuente)"
# ═════════════════════════════════════════════════════════

if ! command -v suricata &>/dev/null; then
    info "Instalando dependencias de compilación..."
    apt-get install -y -qq \
        libpcre3-dev libpcre2-dev zlib1g-dev libyaml-dev \
        libjansson-dev libcap-ng-dev libmagic-dev libnetfilter-queue-dev \
        libpcap-dev liblz4-dev libluajit-5.1-dev libnss3-dev \
        libnspr4-dev cbindgen

    SURICATA_VER="8.0.3"
    cd /tmp

    if [[ ! -f "suricata-${SURICATA_VER}.tar.gz" ]]; then
        info "Descargando Suricata ${SURICATA_VER}..."
        wget -q "https://www.openinfosecfoundation.org/download/suricata-${SURICATA_VER}.tar.gz"
    fi

    [[ -d "suricata-${SURICATA_VER}" ]] && rm -rf "suricata-${SURICATA_VER}"
    tar xzf "suricata-${SURICATA_VER}.tar.gz"
    cd "suricata-${SURICATA_VER}"

    info "Configurando Suricata..."
    PATH="/usr/local/cargo/bin:$PATH" \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    ./configure \
        --prefix=/usr/local \
        --sysconfdir=/usr/local/etc \
        --localstatedir=/usr/local/var \
        --enable-nfqueue \
        --enable-lua \
        --disable-gccprotect \
        --disable-pie \
        > /tmp/suricata-configure.log 2>&1 || {
            tail -5 /tmp/suricata-configure.log
            die "Suricata configure falló — ver /tmp/suricata-configure.log"
        }
    ok "Configure completado"

    info "Compilando Suricata (~10-15 minutos)..."
    PATH="/usr/local/cargo/bin:$PATH" \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    make -j$(nproc) > /tmp/suricata-make.log 2>&1 || {
        tail -10 /tmp/suricata-make.log
        die "Suricata make falló — ver /tmp/suricata-make.log"
    }

    make install > /tmp/suricata-install.log 2>&1
    make install-conf >> /tmp/suricata-install.log 2>&1
    ldconfig

    cd /tmp && rm -rf "suricata-${SURICATA_VER}" "suricata-${SURICATA_VER}.tar.gz"
    ok "Suricata ${SURICATA_VER} instalado"
else
    ok "Suricata ya instalado: $(suricata -V 2>/dev/null | head -1)"
fi

info "Descargando reglas Emerging Threats..."
mkdir -p /usr/local/etc/suricata/rules /usr/local/var/log/suricata /usr/local/var/run
suricata-update update-sources --no-reload 2>/dev/null || true
suricata-update --no-reload 2>/dev/null || true
ok "Reglas descargadas"

cat > /etc/systemd/system/suricata.service << 'SUREOF'
[Unit]
Description=Suricata IDS/IPS
After=network.target nftables.service

[Service]
Type=forking
ExecStart=/usr/local/bin/suricata -c /usr/local/etc/suricata/suricata.yaml --af-packet -D -l /usr/local/var/log/suricata/
ExecReload=/bin/kill -USR2 $MAINPID
PIDFile=/usr/local/var/run/suricata.pid
Restart=on-failure
RestartSec=10s
StartLimitBurst=3
StartLimitIntervalSec=60s

[Install]
WantedBy=multi-user.target
SUREOF
ok "Servicio Suricata creado"

SURI_CONF="/usr/local/etc/suricata/suricata.yaml"
cp "$SURI_CONF" "${SURI_CONF}.bak.$(date +%s)"
sed -i "s/interface: eth0/interface: ${WAN_IFACE}/g" "$SURI_CONF"
sed -i "s/interface: eth1/interface: ${LAN_IFACE}/g" "$SURI_CONF"
sed -i "s/interface: default/interface: ${WAN_IFACE}/g" "$SURI_CONF"
ok "Suricata configurado para ${WAN_IFACE} y ${LAN_IFACE}"

# ═════════════════════════════════════════════════════════
header "7. nDPI 5.0 (Application Control)"
# ═════════════════════════════════════════════════════════

if ! command -v ndpiReader &>/dev/null; then
    info "Instalando dependencias de nDPI..."
    apt-get install -y -qq \
        libpcap-dev libgcrypt20-dev libjson-c-dev libmaxminddb-dev

    info "Clonando nDPI 5.0 desde GitHub..."
    cd /tmp
    rm -rf nDPI
    git clone --branch 5.0 --depth 1 https://github.com/ntop/nDPI.git 2>/dev/null
    cd nDPI

    info "Compilando nDPI (~5 minutos)..."
    ./autogen.sh > /tmp/ndpi-autogen.log 2>&1 || {
        tail -5 /tmp/ndpi-autogen.log
        die "nDPI autogen falló"
    }
    ./configure --prefix=/usr/local > /tmp/ndpi-configure.log 2>&1 || {
        tail -5 /tmp/ndpi-configure.log
        die "nDPI configure falló"
    }
    make -j$(nproc) > /tmp/ndpi-make.log 2>&1 || {
        tail -10 /tmp/ndpi-make.log
        die "nDPI make falló"
    }
    make install > /tmp/ndpi-install.log 2>&1
    ldconfig
    cd /tmp && rm -rf nDPI
    ok "nDPI 5.0 instalado: $(ndpiReader --version 2>/dev/null | head -1)"
else
    ok "nDPI ya instalado: $(ndpiReader --version 2>/dev/null | head -1)"
fi

python3 -c "import netfilterqueue" 2>/dev/null || \
    pip3 install NetfilterQueue --break-system-packages -q

mkdir -p /etc/velar /var/lib/velar/appcontrol
[[ ! -f /etc/velar/appcontrol.json ]] && \
    printf '{"enabled": true, "vlans": {}}\n' > /etc/velar/appcontrol.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$VELAR_SRC/ndpi_inspector.py" ]]; then
    cp "$VELAR_SRC/ndpi_inspector.py" /usr/local/bin/
    chmod +x /usr/local/bin/ndpi_inspector.py
    ok "ndpi_inspector.py copiado (desde GitHub)"
elif [[ -f "$SCRIPT_DIR/ndpi_inspector.py" ]]; then
    cp "$SCRIPT_DIR/ndpi_inspector.py" /usr/local/bin/
    chmod +x /usr/local/bin/ndpi_inspector.py
    ok "ndpi_inspector.py copiado"
elif [[ -f "/root/ndpi_inspector.py" ]]; then
    cp /root/ndpi_inspector.py /usr/local/bin/
    chmod +x /usr/local/bin/ndpi_inspector.py
    ok "ndpi_inspector.py copiado"
else
    warn "ndpi_inspector.py no encontrado — cópialo manualmente a /usr/local/bin/"
fi

cat > /etc/systemd/system/velar-appcontrol.service << 'ACEOF'
[Unit]
Description=Velar Application Control (nDPI Inspector)
After=network.target nftables.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ndpi_inspector.py --queue-num 10 --rules /etc/velar/appcontrol.json
Restart=on-failure
RestartSec=5s
StartLimitBurst=5
StartLimitIntervalSec=60s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ndpi-inspector

[Install]
WantedBy=multi-user.target
ACEOF

systemctl daemon-reload
systemctl enable velar-appcontrol
ok "Servicio velar-appcontrol creado"

# ═════════════════════════════════════════════════════════
header "8. SSH keys para terminal web"
# ═════════════════════════════════════════════════════════

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ ! -f /root/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
    ok "Llave SSH generada"
else
    ok "Llave SSH ya existe"
fi

if ! grep -qf /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys 2>/dev/null; then
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    ok "Llave autorizada para login local"
else
    ok "Llave ya autorizada"
fi

ssh -i /root/.ssh/id_rsa \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    root@127.0.0.1 "echo OK" < /dev/null &>/dev/null && \
    ok "SSH local funciona" || \
    warn "SSH local no responde — verifica sshd"

# ═════════════════════════════════════════════════════════
header "9. MariaDB — configuración"
# ═════════════════════════════════════════════════════════

systemctl enable mariadb
systemctl start mariadb

if mysql -u root -e "SELECT 1" < /dev/null &>/dev/null 2>&1; then
    mysql -u root << SQLEOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQLEOF
elif mysql -u root -p"${DB_ROOT_PASS}" -e "SELECT 1" < /dev/null &>/dev/null 2>&1; then
    info "MariaDB ya tiene esa contraseña"
else
    die "No se puede conectar a MariaDB"
fi

mysql -u root -p"${DB_ROOT_PASS}" << SQLEOF
CREATE DATABASE IF NOT EXISTS router_admin CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS kea CHARACTER SET utf8mb4;
FLUSH PRIVILEGES;
SQLEOF
ok "Bases de datos creadas"

ADMIN_PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${ADMIN_PASS}'.encode()).hexdigest())")

mysql -u root -p"${DB_ROOT_PASS}" router_admin << SQLEOF
CREATE TABLE IF NOT EXISTS users (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(64) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role          ENUM('admin','viewer','readonly') DEFAULT 'admin',
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_login    DATETIME
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS sessions (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    user_id    INT NOT NULL,
    token      VARCHAR(255) NOT NULL UNIQUE,
    expires_at DATETIME NOT NULL,
    ip         VARCHAR(45),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS audit_log (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    user_id    INT,
    username   VARCHAR(64),
    action     VARCHAR(255) NOT NULL,
    detail     TEXT,
    ip         VARCHAR(45),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS traffic_stats (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    iface       VARCHAR(32) NOT NULL,
    period_type ENUM('fiveminute','hour','day','month') NOT NULL,
    period_at   DATETIME NOT NULL,
    rx_bytes    BIGINT UNSIGNED DEFAULT 0,
    tx_bytes    BIGINT UNSIGNED DEFAULT 0,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_iface_period (iface, period_type, period_at),
    INDEX idx_iface_type_at (iface, period_type, period_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS suricata_daily_stats (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    date     DATE NOT NULL,
    category VARCHAR(128) NOT NULL,
    severity TINYINT NOT NULL,
    count    INT DEFAULT 1,
    UNIQUE KEY uq_date_cat_sev (date, category, severity),
    INDEX idx_date (date)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS service_events (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    service     VARCHAR(64) NOT NULL,
    event       ENUM('start','stop','restart','fail') NOT NULL,
    status      ENUM('running','stopped','failed') NOT NULL,
    detail      TEXT,
    occurred_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_service  (service),
    INDEX idx_occurred (occurred_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS login_attempts (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    ip         VARCHAR(45) NOT NULL,
    username   VARCHAR(64) NOT NULL DEFAULT '',
    success    TINYINT(1)  NOT NULL DEFAULT 0,
    created_at DATETIME    NOT NULL DEFAULT current_timestamp(),
    INDEX idx_ip_time   (ip, created_at),
    INDEX idx_user_time (username, created_at)
) ENGINE=InnoDB;

-- Columnas 2FA y seguridad en users
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS totp_secret     VARCHAR(32)  NULL DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS totp_enabled    TINYINT(1)   NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS failed_attempts INT          NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS locked_until    DATETIME     NULL DEFAULT NULL;

INSERT IGNORE INTO users (username, password_hash, role)
VALUES ('${ADMIN_USER}', '${ADMIN_PASS_HASH}', 'admin');
SQLEOF
ok "Schema de router_admin creado"

kea-admin db-init mysql -u root -p "${DB_ROOT_PASS}" -n kea < /dev/null 2>/dev/null || \
    warn "KEA schema ya existe — continuando"
ok "Schema de KEA inicializado"

# ═════════════════════════════════════════════════════════
header "10. WireGuard"
# ═════════════════════════════════════════════════════════

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    WG_PRIV=$(wg genkey)
    WG_PUB=$(echo "$WG_PRIV" | wg pubkey)
    printf "[Interface]\nAddress = %s/%s\nListenPort = 51820\nPrivateKey = %s\nSaveConfig = false\n" \
        "$WG_SERVER_IP" "$WG_PREFIX" "$WG_PRIV" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable wg-quick@wg0
    ok "WireGuard wg0 configurado (${WG_SERVER_IP}/${WG_PREFIX})"
else
    ok "WireGuard wg0 ya configurado"
fi

# Override para wg-quick — restart automático si el tunnel cae
mkdir -p /etc/systemd/system/wg-quick@.service.d
cat > /etc/systemd/system/wg-quick@.service.d/override.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=10s
StartLimitBurst=3
StartLimitIntervalSec=60s
EOF
ok "WireGuard restart automático configurado"

# ═════════════════════════════════════════════════════════
header "11. vnstat"
# ═════════════════════════════════════════════════════════

systemctl enable vnstat
systemctl start vnstat
sleep 2
vnstat --add -i "$WAN_IFACE" 2>/dev/null || true
vnstat --add -i "$LAN_IFACE" 2>/dev/null || true
vnstat --add -i "wg0" 2>/dev/null || true
ok "vnstat configurado"

# ═════════════════════════════════════════════════════════
header "12. Unbound DNS"
# ═════════════════════════════════════════════════════════

mkdir -p /etc/unbound/unbound.conf.d

# CRÍTICO: NO incluir 127.0.0.1 en velar.conf — ya está en unbound.conf base
# Duplicarlo causa "interface present twice" y Unbound no arranca
printf "server:\n  verbosity: 1\n  port: 53\n  do-ip4: yes\n  do-ip6: no\n  do-udp: yes\n  do-tcp: yes\n  access-control: 127.0.0.0/8 allow\n  access-control: %s allow\n  prefetch: yes\n  hide-identity: yes\n  hide-version: yes\n\nforward-zone:\n  name: \".\"\n  forward-addr: 1.1.1.1\n  forward-addr: 8.8.8.8\n" \
    "$WG_SUBNET" > /etc/unbound/unbound.conf.d/velar.conf

# Override Unbound — restart si falla, sin tocar network-online.target
mkdir -p /etc/systemd/system/unbound.service.d
cat > /etc/systemd/system/unbound.service.d/override.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=5s
StartLimitBurst=5
StartLimitIntervalSec=60s
EOF

if systemctl is-active systemd-resolved &>/dev/null; then
    systemctl disable --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

unbound-checkconf && systemctl enable unbound && \
    systemctl restart unbound && ok "Unbound DNS configurado" || \
    warn "Unbound no pudo iniciar — revisa la config"

# ═════════════════════════════════════════════════════════
header "13. nftables"
# ═════════════════════════════════════════════════════════

printf '#!/usr/sbin/nft -f\n\nflush ruleset\n\ntable inet filter {\n    chain input {\n        type filter hook input priority filter; policy drop;\n        ct state established,related accept\n        iifname "lo" accept\n        tcp dport 22 accept\n        tcp dport 80 accept\n        iifname "%s" tcp dport %s accept\n        iifname "%s.*" tcp dport %s accept\n        udp dport 53 accept\n        udp dport 51820 accept\n        iifname "%s" udp dport 67 accept\n    }\n\n    chain forward {\n        type filter hook forward priority filter; policy drop;\n        ct state established,related accept\n        iifname "%s" oifname "%s" accept\n        iifname "%s.*" oifname "%s" accept\n        iifname "wg0" oifname "%s" accept\n    }\n\n    chain output {\n        type filter hook output priority filter; policy accept;\n    }\n}\n\ntable ip nat {\n    chain postrouting {\n        type nat hook postrouting priority srcnat; policy accept;\n        oifname "%s" masquerade\n    }\n}\n' \
    "$LAN_IFACE" "$API_PORT" \
    "$LAN_IFACE" "$API_PORT" \
    "$LAN_IFACE" \
    "$LAN_IFACE" "$WAN_IFACE" \
    "$LAN_IFACE" "$WAN_IFACE" \
    "$WAN_IFACE" \
    "$WAN_IFACE" > /etc/nftables.conf

systemctl enable nftables
systemctl restart nftables
ok "nftables configurado"

printf "net.ipv4.ip_forward=1\nnet.netfilter.nf_conntrack_max=1048576\n" \
    > /etc/sysctl.d/99-velar.conf
sysctl -p /etc/sysctl.d/99-velar.conf > /dev/null
ok "IP forwarding habilitado"

# Conntrack: 1M+ conexiones concurrentes. El hashsize se fija aparte
# porque no es un sysctl real — vive en /sys/module o se carga via modprobe.d
cat > /etc/modprobe.d/nf_conntrack.conf << 'CTEOF'
options nf_conntrack hashsize=262144
CTEOF

# Aplicar de inmediato si el módulo ya está cargado (no requiere reboot)
if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
fi
ok "Conntrack configurado para 1M+ conexiones concurrentes"

# ═════════════════════════════════════════════════════════
header "14. KEA DHCP — configuración"
# ═════════════════════════════════════════════════════════

mkdir -p /etc/kea /var/log/kea

printf '{\n  "Dhcp4": {\n    "interfaces-config": {\n      "interfaces": ["%s"]\n    },\n    "valid-lifetime": 28800,\n    "renew-timer": 14400,\n    "rebind-timer": 25200,\n    "lease-database": {\n      "type": "mysql",\n      "name": "kea",\n      "host": "127.0.0.1",\n      "port": 3306,\n      "user": "root",\n      "password": "%s"\n    },\n    "subnet4": [],\n    "loggers": [{\n      "name": "kea-dhcp4",\n      "output_options": [{"output": "/var/log/kea/kea-dhcp4.log"}],\n      "severity": "WARN"\n    }]\n  }\n}\n' \
    "$LAN_IFACE" "$DB_ROOT_PASS" > /etc/kea/kea-dhcp4.conf

# Override KEA — restart si falla (VLANs pueden no existir al primer boot)
mkdir -p /etc/systemd/system/${KEA_SVC}.service.d
cat > /etc/systemd/system/${KEA_SVC}.service.d/override.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=10s
StartLimitBurst=5
StartLimitIntervalSec=120s
EOF

systemctl enable "$KEA_SVC"
ok "KEA DHCP configurado (servicio: $KEA_SVC)"

# ═════════════════════════════════════════════════════════
header "15. Squid Web Proxy"
# ═════════════════════════════════════════════════════════

cat > /etc/squid/squid.conf << 'SQUIDEOF'
# Velar — Squid basic config
acl localnet src 10.0.0.0/8
acl localnet src 172.16.0.0/12
acl localnet src 192.168.0.0/16
acl SSL_ports port 443
acl Safe_ports port 80 443 21 70 210 280 488 591 777 1025-65535
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access deny all

http_port 3128
coredump_dir /var/spool/squid
SQUIDEOF

systemctl enable squid
ok "Squid configurado"

# ═════════════════════════════════════════════════════════
header "16. SNMP"
# ═════════════════════════════════════════════════════════

cat > /etc/snmp/snmpd.conf << 'SNMPEOF'
agentAddress udp:161,udp6:[::1]:161
view   systemonly  included   .1.3.6.1.2.1.1
view   systemonly  included   .1.3.6.1.2.1.25.1
rocommunity  public  default    -V systemonly
sysLocation    Router
sysContact     admin@velar
SNMPEOF

systemctl enable snmpd
ok "SNMP configurado"

# ═════════════════════════════════════════════════════════
header "17. Velar API (FastAPI)"
# ═════════════════════════════════════════════════════════

mkdir -p "$INSTALL_DIR/api"
info "Buscando paquete pre-compilado del backend (dist-api)..."

if [[ -d "$VELAR_SRC/dist-api" ]]; then
    SOURCE_DIR="$VELAR_SRC/dist-api"
elif [[ -d "$SCRIPT_DIR/dist-api" ]]; then
    SOURCE_DIR="$SCRIPT_DIR/dist-api"
elif [[ -d "/root/dist-api" ]]; then
    SOURCE_DIR="/root/dist-api"
else
    read -p "  Ruta completa al directorio dist-api: " SOURCE_DIR < /dev/tty
    [[ ! -d "$SOURCE_DIR" ]] && die "Directorio no encontrado: $SOURCE_DIR"
fi

ok "Backend (ofuscado) encontrado en: $SOURCE_DIR"
cp -r "$SOURCE_DIR/." "$INSTALL_DIR/api/"

# Recrear venv siempre limpio para evitar permisos corruptos
rm -rf "$INSTALL_DIR/api/venv"
python3 -m venv "$INSTALL_DIR/api/venv"
"$INSTALL_DIR/api/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/api/venv/bin/pip" install -q -r "$INSTALL_DIR/api/requirements.txt"
"$INSTALL_DIR/api/venv/bin/pip" install -q cryptography pymysql
ok "Dependencias Python instaladas (código del backend ya viene ofuscado)"

printf "API_TOKEN=%s\nHOST=0.0.0.0\nPORT=%s\nWAN_IFACE=%s\nLAN_IFACE=%s\nWG_IFACE=wg0\nWG_CONFIG=/etc/wireguard/wg0.conf\nWG_KEY_ENCRYPT=%s\nWG_DNS=1.1.1.1\nKEA_CTRL_SOCKET=/run/kea/kea4-ctrl-socket\nUNBOUND_LOCAL_ZONES=/etc/unbound/unbound.conf.d/local-zones.conf\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_USER=root\nDB_PASS=%s\nDB_NAME=router_admin\n" \
    "$API_TOKEN" "$API_PORT" "$WAN_IFACE" "$LAN_IFACE" "$WG_KEY" "$DB_ROOT_PASS" \
    > "$INSTALL_DIR/api/.env"
chmod 600 "$INSTALL_DIR/api/.env"
ok ".env creado"

# velar-api.service con restart automático
cat > /etc/systemd/system/velar-api.service << SVCEOF
[Unit]
Description=Velar Router API (FastAPI)
After=network.target mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/api
ExecStart=${INSTALL_DIR}/api/venv/bin/python main.py
Restart=on-failure
RestartSec=5s
StartLimitBurst=5
StartLimitIntervalSec=60s
EnvironmentFile=${INSTALL_DIR}/api/.env
StandardOutput=journal
StandardError=journal
SyslogIdentifier=velar-api

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable velar-api
ok "Servicio velar-api creado"

# ═════════════════════════════════════════════════════════
header "18. Frontend (Vue 3 + nginx)"
# ═════════════════════════════════════════════════════════

info "Buscando paquete pre-compilado del frontend (dist-ui)..."
if [[ -d "$VELAR_SRC/dist-ui" ]]; then
    UI_DIR="$VELAR_SRC/dist-ui"
elif [[ -d "$SCRIPT_DIR/dist-ui" ]]; then
    UI_DIR="$SCRIPT_DIR/dist-ui"
elif [[ -d "/root/dist-ui" ]]; then
    UI_DIR="/root/dist-ui"
else
    read -p "  Ruta completa al directorio dist-ui: " UI_DIR < /dev/tty
    [[ ! -d "$UI_DIR" ]] && die "Directorio no encontrado: $UI_DIR"
fi
ok "Frontend (compilado) encontrado en: $UI_DIR"

mkdir -p /opt/velar/ui
cp -r "$UI_DIR/." /opt/velar/ui/
ok "Frontend copiado a /opt/velar/ui (ya viene compilado, sin código Vue fuente)"

# nginx con soporte WebSocket para terminal
cat > /etc/nginx/sites-available/velar << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    root /opt/velar/ui;
    index index.html;

    location = /index.html {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        expires 0;
    }

    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
        expires 1y;
    }

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        expires 0;
    }

    # WebSocket para terminal SSH
    location /api/terminal/ws {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 3600;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 300;
        add_header Cache-Control "no-store";
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/velar /etc/nginx/sites-enabled/velar
rm -f /etc/nginx/sites-enabled/default
nginx -t && ok "nginx configurado" || warn "nginx config tiene errores"
systemctl enable nginx

# ═════════════════════════════════════════════════════════
header "19. Watchdog — KEA y API health check"
# ═════════════════════════════════════════════════════════

cat > /usr/local/bin/velar-watchdog.sh << 'WATCHEOF'
#!/bin/bash
LOG=/var/log/velar-watchdog.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

[ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ] && \
    mv "$LOG" "${LOG}.1"

if systemctl is-active velar-api --quiet 2>/dev/null; then
    API_TOKEN=$(grep ^API_TOKEN "$INSTALL_DIR/api/.env" 2>/dev/null | cut -d= -f2)
    if ! curl -sf --max-time 3 -H "X-API-Token: ${API_TOKEN}" http://localhost:8000/api/system/status &>/dev/null; then
        log "WARN velar-api no responde HTTP — reiniciando"
        systemctl restart velar-api
        sleep 3
        systemctl is-active velar-api --quiet 2>/dev/null && \
            log "OK velar-api reiniciado" || log "ERROR velar-api no arrancó"
    fi
fi

KEA_SVC=$(systemctl list-units --type=service 2>/dev/null | \
    grep -oE "isc-kea-dhcp4[a-z-]*\.service" | head -1 | sed 's/\.service//')
KEA_SVC=${KEA_SVC:-isc-kea-dhcp4-server}

if ! systemctl is-active "$KEA_SVC" --quiet 2>/dev/null; then
    python3 - << 'PYEOF' >> "$LOG" 2>&1
import json, subprocess
from pathlib import Path
p = Path('/etc/kea/kea-dhcp4.conf')
if not p.exists(): exit()
try:
    c = json.loads(p.read_text())
    r = subprocess.run(['ip','link','show'], capture_output=True, text=True)
    existing = {l.split(':')[1].strip().split('@')[0]
                for l in r.stdout.splitlines()
                if ': ' in l and not l.startswith(' ')}
    old = c['Dhcp4']['interfaces-config']['interfaces']
    new = [i for i in old if i in existing or '.' not in i]
    if old != new:
        c['Dhcp4']['interfaces-config']['interfaces'] = new
        p.write_text(json.dumps(c, indent=4))
        print(f"Limpiadas interfaces huérfanas: {set(old)-set(new)}")
except Exception as e:
    print(f"Error limpiando KEA config: {e}")
PYEOF
    if kea-dhcp4 -t /etc/kea/kea-dhcp4.conf &>/dev/null; then
        log "INFO $KEA_SVC caído con config válido — reiniciando"
        systemctl start "$KEA_SVC"
        sleep 3
        systemctl is-active "$KEA_SVC" --quiet 2>/dev/null && \
            log "OK $KEA_SVC reiniciado" || log "ERROR $KEA_SVC no arrancó"
    fi
fi
WATCHEOF
chmod +x /usr/local/bin/velar-watchdog.sh

cat > /etc/systemd/system/velar-watchdog.service << 'WSVCEOF'
[Unit]
Description=Velar Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/velar-watchdog.sh
StandardOutput=journal
StandardError=journal
WSVCEOF

cat > /etc/systemd/system/velar-watchdog.timer << 'WTMREOF'
[Unit]
Description=Velar Watchdog — cada 2 minutos

[Timer]
OnBootSec=60s
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
WTMREOF

ok "Watchdog configurado"

# ═════════════════════════════════════════════════════════
header "20. Logrotate y guard para Suricata"
# ═════════════════════════════════════════════════════════

cat > /etc/logrotate.d/suricata << 'LREOF'
/usr/local/var/log/suricata/eve.json {
    daily
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
    size 100M
}
/usr/local/var/log/suricata/fast.log {
    daily
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
    size 50M
}
/usr/local/var/log/suricata/stats.log {
    daily
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
    size 100M
}
LREOF

cat > /usr/local/bin/suricata-log-guard.sh << 'GUARDEOF'
#!/bin/bash
LOG_DIR="/usr/local/var/log/suricata"
MAX_SIZE=$((500 * 1024 * 1024))
for log in eve.json stats.log fast.log; do
    path="$LOG_DIR/$log"
    if [ -f "$path" ]; then
        size=$(stat -c%s "$path" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_SIZE" ]; then
            echo "$(date): $log demasiado grande ($(( size / 1024 / 1024 ))MB), truncando" >> /var/log/suricata-guard.log
            > "$path"
        fi
    fi
done
find "$LOG_DIR" -name "*.gz" -mtime +3 -delete 2>/dev/null
find "$LOG_DIR" -name "*.1" -mtime +3 -delete 2>/dev/null
GUARDEOF
chmod +x /usr/local/bin/suricata-log-guard.sh

cat > /etc/systemd/system/suricata-guard.service << 'GSVCEOF'
[Unit]
Description=Suricata Log Guard
[Service]
Type=oneshot
ExecStart=/usr/local/bin/suricata-log-guard.sh
GSVCEOF

cat > /etc/systemd/system/suricata-guard.timer << 'GTMREOF'
[Unit]
Description=Suricata Log Guard Timer
Requires=suricata-guard.service
[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
GTMREOF

systemctl daemon-reload
systemctl enable suricata-guard.timer
ok "Logrotate y guard configurados"

# ═════════════════════════════════════════════════════════
header "21. Iniciando servicios"
# ═════════════════════════════════════════════════════════

systemctl daemon-reload
systemctl restart mariadb
systemctl restart nftables
systemctl restart unbound        || warn "Unbound — revisa config"
systemctl start wg-quick@wg0    || warn "WireGuard — configura manualmente"
systemctl start "$KEA_SVC"      || warn "KEA — revisa la config"
systemctl start suricata         || warn "Suricata — revisa la config"
systemctl restart squid          || warn "Squid — revisa la config"
systemctl restart snmpd          || warn "SNMP — revisa la config"
systemctl start velar-api
systemctl restart nginx
systemctl enable --now velar-watchdog.timer
systemctl start suricata-guard.timer

if [[ -f /usr/local/bin/ndpi_inspector.py ]]; then
    systemctl start velar-appcontrol || warn "App Control — revisa la config"
else
    warn "App Control — ndpi_inspector.py no encontrado, servicio no iniciado"
fi

sleep 3

# ═════════════════════════════════════════════════════════
header "Verificación final"
# ═════════════════════════════════════════════════════════

check_service() {
    if systemctl is-active "$1" &>/dev/null; then
        ok "$1"
    else
        warn "$1 — no está activo"
    fi
}

check_service mariadb
check_service unbound
check_service nftables
check_service wg-quick@wg0
check_service "$KEA_SVC"
check_service suricata
check_service squid
check_service snmpd
check_service velar-api
check_service vnstat
check_service nginx
check_service docker
check_service velar-watchdog.timer
[[ -f /usr/local/bin/ndpi_inspector.py ]] && check_service velar-appcontrol

sleep 2
if curl -sf "http://localhost/api/system/status" > /dev/null 2>&1; then
    ok "Panel web accesible"
elif curl -sf "http://localhost:${API_PORT}/api/system/status" \
    -H "X-API-Token: ${API_TOKEN}" > /dev/null 2>&1; then
    ok "API respondiendo (sin frontend)"
else
    warn "API no responde — intenta: systemctl status velar-api"
fi

# ═════════════════════════════════════════════════════════
echo
echo -e "${BOLD}${GREEN}══════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Velar instalado correctamente!${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════${NC}"
echo
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "  Panel web : ${CYAN}http://${SERVER_IP}${NC}"
echo -e "  Usuario   : ${CYAN}${ADMIN_USER}${NC}"
echo -e "  Contraseña: ${CYAN}(la que ingresaste)${NC}"
echo -e "  API Token : ${CYAN}${API_TOKEN}${NC}"
echo
echo -e "  ${BOLD}Auto-restart configurado en:${NC}"
echo -e "  • velar-api   — Restart=on-failure + watchdog HTTP"
echo -e "  • KEA DHCP    — Restart=on-failure + watchdog de interfaces"
echo -e "  • Unbound     — Restart=on-failure"
echo -e "  • WireGuard   — Restart=on-failure"
echo -e "  • Suricata    — Restart=on-failure"
echo -e "  Log watchdog  : /var/log/velar-watchdog.log"
echo
echo -e "  ${YELLOW}⚠ App Control requiere ndpi_inspector.py junto al script${NC}"
echo -e "  ${YELLOW}⚠ Guarda el API Token para configuraciones avanzadas${NC}"
echo
echo "  Log completo: $LOG"
echo