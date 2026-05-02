#!/usr/bin/env bash
#
# setup.sh — Instalação completa do STB Channel Loop
#
# Uso:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# O script:
#   1. Cria o utilizador de sistema 'stb-loop'
#   2. Instala dependências do SO (adb, python3)
#   3. Copia o projeto para /opt/stb-loop
#   4. Instala dependências Python
#   5. Cria e ativa o serviço systemd
#
set -euo pipefail

APP_USER="stb-loop"
APP_DIR="/opt/stb-loop"
SERVICE_NAME="stb-loop.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LOOPTIME="${LOOPTIME:-10}"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Verificações iniciais
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    err "Este script tem de ser executado como root:  sudo ./setup.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/loop.py" ]; then
    err "loop.py não encontrado em ${SCRIPT_DIR}. Corre o script a partir da pasta do projeto."
fi

log "=== STB Channel Loop — Instalação ==="
log "Utilizador : ${APP_USER}"
log "Destino    : ${APP_DIR}"
log "Looptime   : ${LOOPTIME}s"

# ---------------------------------------------------------------------------
# 1. Criar utilizador de sistema
# ---------------------------------------------------------------------------

log "1/5 A criar utilizador '${APP_USER}' …"

if id "${APP_USER}" &>/dev/null; then
    warn "Utilizador '${APP_USER}' já existe."
else
    useradd --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "STB Channel Loop service user" \
        "${APP_USER}"
    log "Utilizador '${APP_USER}' criado."
fi

# ---------------------------------------------------------------------------
# 2. Instalar dependências do SO
# ---------------------------------------------------------------------------

log "2/5 A instalar dependências do sistema …"

apt update -qq
apt install -y -qq adb python3 python3-pip

log "ADB $(adb version 2>/dev/null | head -1 || echo 'instalado')"
log "Python $(python3 --version)"

# ---------------------------------------------------------------------------
# 3. Copiar ficheiros do projeto
# ---------------------------------------------------------------------------

log "3/5 A copiar projeto para ${APP_DIR} …"

mkdir -p "${APP_DIR}"
cp "${SCRIPT_DIR}/loop.py" "${APP_DIR}/"
cp "${SCRIPT_DIR}/requirements.txt" "${APP_DIR}/" 2>/dev/null || true

# Copiar config.json se já existir (feito pelo wizard)
if [ -f "${SCRIPT_DIR}/config.json" ]; then
    cp "${SCRIPT_DIR}/config.json" "${APP_DIR}/"
    log "config.json copiado."
else
    warn "config.json não encontrado. Corre 'python3 ${APP_DIR}/loop.py --stb' depois da instalação."
fi

# ---------------------------------------------------------------------------
# 4. Instalar dependências Python
# ---------------------------------------------------------------------------

log "4/5 A instalar dependências Python …"

if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip3 install -q -r "${APP_DIR}/requirements.txt" || true
fi
log "Dependências Python OK."

# ---------------------------------------------------------------------------
# 5. Criar e ativar serviço systemd
# ---------------------------------------------------------------------------

log "5/5 A configurar serviço systemd …"

cat > "${SERVICE_FILE}" << SYSTEMD
[Unit]
Description=STB Channel Loop — NOC Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/loop.py --looptime ${LOOPTIME}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Segurança
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR}
ReadOnlyPaths=/usr/bin/adb

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

# Verificar estado
sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Serviço '${SERVICE_NAME}' ativo e a correr."
else
    warn "Serviço pode não ter arrancado. Verifica: journalctl -u ${SERVICE_NAME} -f"
fi

# ---------------------------------------------------------------------------
# Permissões finais
# ---------------------------------------------------------------------------

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
chmod 750 "${APP_DIR}"
chmod 640 "${APP_DIR}/config.json" 2>/dev/null || true
chmod 755 "${APP_DIR}/loop.py"

# Dar permissão ao user stb-loop para usar ADB
usermod -a -G plugdev "${APP_USER}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------

echo ""
log "============================================"
log " Instalação concluída!"
log "============================================"
echo ""
echo "  Comandos úteis:"
echo "  ─────────────────────────────────────────"
echo "  Configurar STB:   python3 ${APP_DIR}/loop.py --stb"
echo "  Estado serviço:   sudo systemctl status ${SERVICE_NAME}"
echo "  Logs em direto:   journalctl -u ${SERVICE_NAME} -f"
echo "  Reiniciar:        sudo systemctl restart ${SERVICE_NAME}"
echo "  Parar:            sudo systemctl stop ${SERVICE_NAME}"
echo "  Desinstalar:      sudo systemctl disable --now ${SERVICE_NAME}"
echo ""
echo "  Looptime atual:   ${LOOPTIME}s  (muda com: LOOPTIME=30 sudo ./setup.sh)"
echo ""
