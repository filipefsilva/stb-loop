# STB Channel Loop — NOC Display

Script Python para Raspberry Pi Zero W que faz zapping contínuo de canais
numa Android TV Box (STB) via ADB over TCP, para exibição permanente no ecrã do NOC.

---

## Requisitos

- Raspberry Pi Zero W com Raspberry Pi OS (Bookworm ou Bullseye)
- Python 3 (incluído por defeito no Raspberry Pi OS)
- ADB instalado no Pi
- Android TV Box com depuração ADB activada e acessível via TCP na rede local

---

## Instalação rápida (recomendada)

```bash
# Clonar o repositório
git clone https://github.com/filipefsilva/stb-loop.git
cd stb-loop

# Instalar tudo (cria utilizador, instala deps, configura serviço)
sudo ./setup.sh

# Configurar a STB
sudo python3 /opt/stb-loop/loop.py --stb
```

O serviço `stb-loop.service` fica activo e arranca automaticamente em cada boot.

Usa `LOOPTIME=30 sudo ./setup.sh` para mudar o intervalo (default: 10s).

---

## Activar depuração ADB na STB (Android TV Box)

Os passos exactos variam consoante o firmware, mas o procedimento geral é:

1. Vai a **Definições → Sobre o dispositivo**
2. Clica 7 vezes em **Build number** para activar as opções de programador
3. Vai a **Definições → Opções de programador**
4. Activa **Depuração USB** (USB Debugging)
5. Activa **Depuração ADB por rede** (Network ADB Debugging) — nalguns dispositivos aparece como *ADB over network* ou *Remote debugging*
6. Anota o IP da STB em **Definições → Rede**

> **Nota:** Alguns dispositivos (ex: Xiaomi, NVIDIA Shield) têm a opção em menus ligeiramente diferentes. Procura por "ADB" nas definições.

---

## Configurar a STB (wizard interactivo)

```bash
sudo python3 /opt/stb-loop/loop.py --stb
```

Introduz o IP e a porta ADB da STB quando pedido. O ficheiro `config.json` é criado automaticamente.

Podes também editar `/opt/stb-loop/config.json` manualmente:

```json
{
  "stb_ip": "192.168.1.100",
  "stb_port": 5555
}
```

---

## Correr manualmente (sem serviço)

```bash
# Com intervalo por defeito (10 segundos entre zaps)
python3 /opt/stb-loop/loop.py

# Com intervalo personalizado (ex: 30 segundos)
python3 /opt/stb-loop/loop.py --looptime 30
```

O script reconecta automaticamente se a ligação ADB cair.  
Para terminar: **CTRL+C**

---

## Gerir o serviço systemd

O `setup.sh` já configura e activa o serviço. Comandos para gestão:

```bash
# Estado do serviço
sudo systemctl status stb-loop.service

# Logs em tempo real
journalctl -u stb-loop.service -f

# Reiniciar
sudo systemctl restart stb-loop.service

# Parar / desactivar
sudo systemctl stop stb-loop.service
sudo systemctl disable stb-loop.service
```

### Ficheiro de serviço (criado automaticamente pelo setup.sh)

```ini
[Unit]
Description=STB Channel Loop — NOC Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=stb-loop
WorkingDirectory=/opt/stb-loop
ExecStart=/usr/bin/python3 /opt/stb-loop/loop.py --looptime 10
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Segurança
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/stb-loop
ReadOnlyPaths=/usr/bin/adb

[Install]
WantedBy=multi-user.target
```

---

## Estrutura do projecto

```
stb-loop/
  loop.py          — script principal
  setup.sh         — script de instalação completa
  requirements.txt — dependências Python
  config.json      — configuração da STB (gerado pelo --stb wizard)
  README.md        — este ficheiro
```

---

## Referência rápida de comandos

| Acção | Comando |
|---|---|
| Instalar tudo | `sudo ./setup.sh` |
| Instalar (30s) | `LOOPTIME=30 sudo ./setup.sh` |
| Configurar STB | `sudo python3 /opt/stb-loop/loop.py --stb` |
| Correr manual (10s) | `python3 /opt/stb-loop/loop.py` |
| Correr manual (30s) | `python3 /opt/stb-loop/loop.py --looptime 30` |
| Estado do serviço | `sudo systemctl status stb-loop.service` |
| Logs em direto | `journalctl -u stb-loop.service -f` |
| Reiniciar serviço | `sudo systemctl restart stb-loop.service` |

---

## Resolução de problemas

**`adb: command not found`**  
→ O `setup.sh` instala-o automaticamente. Manualmente: `sudo apt install -y adb`

**`Connection refused` ao ligar ao STB**  
→ Confirma que a depuração ADB por rede está activa na STB e que o IP/porta estão correctos no `config.json`.

**STB pede confirmação de ligação ADB**  
→ Liga um ecrã à STB, aceita a autorização de depuração e marca "Confiar sempre neste computador".

**Script liga mas o canal não muda**  
→ Confirma que a STB está numa app de TV em directo que suporte `KEYCODE_CHANNEL_UP`. Em algumas apps de streaming o keycode não tem efeito.

**Serviço não arranca**  
→ Verifica os logs: `journalctl -u stb-loop.service -f`. Confirma que o `config.json` existe em `/opt/stb-loop/`.

---

## Desinstalar

```bash
sudo systemctl disable --now stb-loop.service
sudo rm -rf /opt/stb-loop
sudo userdel stb-loop
```
