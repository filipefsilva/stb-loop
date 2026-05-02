#!/usr/bin/env python3
"""
STB Channel Loop — NOC Display
Zapping contínuo de canais via ADB (USB ou TCP) num Android TV Box.
Suporta ligação por USB (cabo) ou por rede (TCP).
"""

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

CONFIG_FILE = Path(__file__).parent / "config.json"
DEFAULT_LOOP_TIME = 10
DEFAULT_ADB_MODE = "tcp"
ADB_PORT_DEFAULT = 5555
MAX_RETRIES = 20
RETRY_DELAY = 5


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
        stream=sys.stdout,
    )


log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config() -> dict:
    if not CONFIG_FILE.exists():
        log.error("Ficheiro de configuração não encontrado: %s", CONFIG_FILE)
        log.error("Corre primeiro:  python loop.py --stb")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        cfg = json.load(f)

    # Modo ADB (default: tcp)
    mode = cfg.get("adb_mode", DEFAULT_ADB_MODE)
    if mode not in ("tcp", "usb"):
        log.error("Campo 'adb_mode' inválido: '%s'. Usa 'tcp' ou 'usb'.", mode)
        sys.exit(1)
    cfg["adb_mode"] = mode

    # Campos obrigatórios consoante o modo
    if mode == "tcp":
        for key in ("stb_ip", "stb_port"):
            if key not in cfg:
                log.error("Campo '%s' em falta no config.json (modo TCP).", key)
                sys.exit(1)
    return cfg


def save_config(cfg: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)
    log.info("Configuração guardada em %s", CONFIG_FILE)


# ---------------------------------------------------------------------------
# Wizard interactivo
# ---------------------------------------------------------------------------

def wizard():
    print("\n=== STB Channel Loop — Configuração ===\n")

    # Escolher modo ADB
    print("Modo de ligação ADB:")
    print("  1 — TCP (rede/IP)")
    print("  2 — USB (cabo)")
    while True:
        choice = input(f"Escolhe [default: {DEFAULT_ADB_MODE}]: ").strip().lower()
        if not choice:
            choice = DEFAULT_ADB_MODE
            break
        if choice in ("1", "tcp"):
            choice = "tcp"
            break
        if choice in ("2", "usb"):
            choice = "usb"
            break
        print("Opção inválida. Escolhe 1 (TCP) ou 2 (USB).")
    mode = choice
    cfg = {"adb_mode": mode}

    if mode == "tcp":
        while True:
            ip = input("\nIP da STB (ex: 192.168.1.100): ").strip()
            if not ip:
                print("IP não pode ser vazio.")
                continue
            ip_pattern = r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"
            if not re.match(ip_pattern, ip):
                print("Formato de IP inválido. Usa o formato: 192.168.1.100")
                continue
            if not all(0 <= int(octet) <= 255 for octet in ip.split(".")):
                print("Octetos do IP fora do intervalo 0-255.")
                continue
            break
        port_str = input(f"Porta ADB [default: {ADB_PORT_DEFAULT}]: ").strip()
        port = int(port_str) if port_str else ADB_PORT_DEFAULT
        cfg["stb_ip"] = ip
        cfg["stb_port"] = port
        target_desc = f"{ip}:{port}"
    else:
        target_desc = "USB (cabo)"
        print("\nModo USB: a STB será detectada automaticamente.")
        print("Confirma que o cabo USB está ligado e a depuração USB activada.")

    save_config(cfg)
    print(f"\nConfiguração guardada: modo={mode} | {target_desc}")
    print("Podes agora correr:  python loop.py\n")


# ---------------------------------------------------------------------------
# ADB helpers
# ---------------------------------------------------------------------------

def adb(*args) -> subprocess.CompletedProcess:
    """Executa um comando adb e devolve o resultado."""
    cmd = ["adb"] + list(args)
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        log.warning("Comando ADB excedeu timeout: %s", " ".join(cmd))
        # Devolve um objecto com returncode != 0 para o chamador tratar
        return subprocess.CompletedProcess(cmd, -1, stdout="", stderr="timeout")


def adb_connect(cfg: dict) -> bool:
    """Liga ao STB. Em modo USB verifica se o dispositivo está presente."""
    if cfg["adb_mode"] == "usb":
        return adb_is_connected(cfg)  # Dispositivo USB aparece sozinho — só verifica

    target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
    log.info("A ligar ao STB %s …", target)
    result = adb("connect", target)
    output = (result.stdout + result.stderr).strip()
    log.info("adb connect: %s", output)
    return "connected" in output.lower()


def adb_is_connected(cfg: dict) -> bool:
    """Verifica se a STB está ligada via ADB."""
    result = adb("devices")
    for line in result.stdout.splitlines():
        if "device" not in line or not line.strip():
            continue
        if cfg["adb_mode"] == "usb":
            # Dispositivos USB aparecem sem ':' no serial
            if ":" not in line.split()[0]:
                return True
        else:
            target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
            if target in line:
                return True
    return False


def adb_send_keycode(cfg: dict, keycode: str) -> bool:
    """Envia um keyevent para a STB."""
    if cfg["adb_mode"] == "usb":
        result = adb("-d", "shell", "input", "keyevent", keycode)
    else:
        target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
        result = adb("-s", target, "shell", "input", "keyevent", keycode)
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Loop principal
# ---------------------------------------------------------------------------

def channel_loop(cfg: dict, loop_time: int):
    mode = cfg["adb_mode"]
    target_desc = "USB" if mode == "usb" else f"{cfg['stb_ip']}:{cfg['stb_port']}"
    keycode = "KEYCODE_CHANNEL_UP"

    log.info("Iniciando channel loop — STB: %s | Modo: %s | Intervalo: %ss",
             target_desc, mode, loop_time)
    log.info("Prima CTRL+C para terminar.")

    # Ligação inicial (modo USB é imediata)
    attempts = 0
    while not adb_connect(cfg):
        attempts += 1
        if attempts >= MAX_RETRIES:
            log.error("Falha na ligação após %d tentativas. A sair.", MAX_RETRIES)
            sys.exit(1)
        log.warning("Falha na ligação (tentativa %d/%d). Nova tentativa em %ds…",
                    attempts, MAX_RETRIES, RETRY_DELAY)
        time.sleep(RETRY_DELAY)

    zap_count = 0

    try:
        while True:
            if not adb_is_connected(cfg):
                log.warning("Ligação perdida. A reconectar…")
                connected = False
                attempts = 0
                while not connected:
                    attempts += 1
                    if attempts > MAX_RETRIES:
                        log.error("Reconexão falhou após %d tentativas. A sair.", MAX_RETRIES)
                        sys.exit(1)
                    connected = adb_connect(cfg)
                    if not connected:
                        log.warning("Reconexão falhada (tentativa %d/%d). Nova tentativa em %ds…",
                                    attempts, MAX_RETRIES, RETRY_DELAY)
                        time.sleep(RETRY_DELAY)
                log.info("Reconectado com sucesso.")

            ok = adb_send_keycode(cfg, keycode)
            zap_count += 1
            if ok:
                log.info("Zap #%d → %s enviado", zap_count, keycode)
            else:
                log.warning("Zap #%d → falha ao enviar %s", zap_count, keycode)

            time.sleep(loop_time)

    except KeyboardInterrupt:
        log.info("Interrompido pelo utilizador (CTRL+C). Total de zaps: %d", zap_count)
        sys.exit(0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    setup_logging()

    # Verifica se ADB está instalado
    if shutil.which("adb") is None:
        log.error("ADB não encontrado. Instala com: sudo apt install -y adb")
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="STB Channel Loop — zapping contínuo via ADB para NOC"
    )
    parser.add_argument(
        "--looptime",
        type=int,
        default=DEFAULT_LOOP_TIME,
        metavar="N",
        help=f"Segundos entre cada zap (default: {DEFAULT_LOOP_TIME})",
    )
    parser.add_argument(
        "--stb",
        action="store_true",
        help="Lança o wizard interactivo para configurar a ligação ao STB",
    )

    args = parser.parse_args()

    if args.stb:
        wizard()
        return

    cfg = load_config()
    channel_loop(cfg, args.looptime)


if __name__ == "__main__":
    main()
