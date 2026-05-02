# STB Channel Loop — NOC Display

Script Python para Raspberry Pi Zero 2 W que faz zapping contínuo de canais
numa Android TV Box (STB) via ADB over TCP, para exibição permanente no ecrã do NOC.

---

## Requisitos

- Raspberry Pi Zero 2 W com Raspberry Pi OS (Bookworm ou Bullseye)
- Python 3 (incluído por defeito no Raspberry Pi OS)
- ADB instalado no Pi
- Android TV Box com depuração ADB activada e acessível via TCP na rede local

---

## 1. Instalar ADB no Raspberry Pi Zero 2 W

```bash
sudo apt update
sudo apt install -y adb
```

Verifica a instalação:

```bash
adb version
```

---

## 2. Activar depuração ADB na STB (Android TV Box)

Os passos exactos variam consoante o firmware, mas o procedimento geral é:

1. Vai a **Definições → Sobre o dispositivo**
2. Clica 7 vezes em **Build number** para activar as opções de programador
3. Vai a **Definições → Opções de programador**
4. Activa **Depuração USB** (USB Debugging)
5. Activa **Depuração ADB por rede** (Network ADB Debugging) — nalguns dispositivos aparece como *ADB over network* ou *Remote debugging*
6. Anota o IP da STB em **Definições → Rede**

> **Nota:** Alguns dispositivos (ex: Xiaomi, NVIDIA Shield) têm a opção em menus ligeiramente diferentes. Procura por "ADB" nas definições.

---

## 3. Copiar o projecto para o Pi

```bash
# A partir do teu PC, copia a pasta para o Pi
scp -r loop/ pi@<IP_DO_PI>:~/loop

# Ou clona directamente no Pi via git (se disponível)
```

---

## 4. Configurar a ligação ao STB

Corre o wizard interactivo para gerar o `config.json`:

```bash
cd ~/loop
python3 loop.py --stb
```

Introduz o IP e a porta ADB da STB quando pedido. O ficheiro `config.json` é criado automaticamente.

Podes também editar `config.json` manualmente:

```json
{
  "stb_ip": "192.168.1.100",
  "stb_port": 5555
}
```

---

## 5. Correr o script

```bash
# Com intervalo por defeito (10 segundos entre zaps)
python3 loop.py

# Com intervalo personalizado (ex: 30 segundos)
python3 loop.py --looptime 30
```

O script reconecta automaticamente se a ligação ADB cair.  
Para terminar: **CTRL+C**

---

## 6. Configurar como serviço systemd (arranque automático)

### 6.1. Criar o ficheiro de serviço

```bash
sudo nano /etc/systemd/system/stb-loop.service
```

Conteúdo:

```ini
[Unit]
Description=STB Channel Loop NOC
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/loop
ExecStart=/usr/bin/python3 /home/pi/loop/loop.py --looptime 10
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

> Ajusta `--looptime` e o caminho `/home/pi/loop/` conforme necessário.

### 6.2. Activar e iniciar o serviço

```bash
sudo systemctl daemon-reload
sudo systemctl enable stb-loop.service
sudo systemctl start stb-loop.service
```

### 6.3. Verificar estado e logs

```bash
# Estado do serviço
sudo systemctl status stb-loop.service

# Logs em tempo real
journalctl -u stb-loop.service -f
```

### 6.4. Parar ou desactivar

```bash
sudo systemctl stop stb-loop.service
sudo systemctl disable stb-loop.service
```

---

## Estrutura do projecto

```
loop/
  loop.py       — script principal
  config.json   — configuração da STB (gerado pelo --stb wizard)
  README.md     — este ficheiro
```

---

## Referência rápida de comandos

| Acção | Comando |
|---|---|
| Configurar STB | `python3 loop.py --stb` |
| Correr (10s default) | `python3 loop.py` |
| Correr (30s) | `python3 loop.py --looptime 30` |
| Ver logs do serviço | `journalctl -u stb-loop.service -f` |
| Reiniciar serviço | `sudo systemctl restart stb-loop.service` |

---

## Resolução de problemas

**`adb: command not found`**  
→ `sudo apt install -y adb`

**`Connection refused` ao ligar ao STB**  
→ Confirma que a depuração ADB por rede está activa na STB e que o IP/porta estão correctos no `config.json`.

**STB pede confirmação de ligação ADB**  
→ Liga um ecrã à STB, aceita a autorização de depuração e marca "Confiar sempre neste computador".

**Script liga mas o canal não muda**  
→ Confirma que a STB está numa app de TV em directo que suporte `KEYCODE_CHANNEL_UP`. Em algumas apps de streaming o keycode não tem efeito.
