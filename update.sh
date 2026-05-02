#!/usr/bin/env bash
#
# update.sh — Actualiza a instalação do STB Channel Loop
#
# Uso:
#   cd ~/stb-loop   (ou onde clonaste o repo)
#   git pull         (opcional — o update.sh também faz pull)
#   sudo ./update.sh
#
set -euo pipefail

APP_DIR="/opt/stb-loop"
SERVICE_NAME="stb-loop.service"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[UPDATE]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    err "Este script tem de ser executado como root:  sudo ./update.sh"
fi

if [ ! -d "${APP_DIR}" ]; then
    err "${APP_DIR} não encontrado. Corre 'sudo ./setup.sh' primeiro."
fi

log "=== STB Channel Loop — Actualização ==="

# 1. Git pull
log "1/4 A actualizar código via git …"
if git pull 2>/dev/null; then
    log "Código actualizado."
else
    warn "git pull falhou — a continuar com os ficheiros locais."
fi

# 2. Copiar ficheiros
log "2/4 A copiar ficheiros para ${APP_DIR} …"
cp loop.py "${APP_DIR}/"
cp requirements.txt "${APP_DIR}/" 2>/dev/null || true
log "Ficheiros copiados."

# 3. Instalar dependências Python
log "3/4 A instalar dependências Python …"
if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip3 install -q -r "${APP_DIR}/requirements.txt" || true
fi
log "Dependências OK."

# 4. Reiniciar serviço
log "4/4 A reiniciar serviço …"
systemctl restart "${SERVICE_NAME}"
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Serviço reiniciado com sucesso."
else
    warn "Serviço pode não ter arrancado. Verifica: journalctl -u ${SERVICE_NAME} -f"
fi

echo ""
systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
echo ""
log "Actualização concluída."
