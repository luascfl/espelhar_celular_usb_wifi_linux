#!/bin/bash

# Cores para logs
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}   INSTALADOR MESTRE: ACESSO REMOTO & SERVIDOR (GCP)  ${NC}"
echo -e "${GREEN}======================================================${NC}"

# ==============================================================================
# PARTE 1: CONFIGURAÇÃO LOCAL (PC)
# ==============================================================================

echo -e "\n${GREEN}[PARTE 1] Configurando seu Computador Local...${NC}"

# 1. Atualizar repositórios e instalar dependências básicas
echo "Instalando dependências..."
sudo apt update
sudo apt install -y openssh-server ufw adb wget

# 2. Configurar SSH (Terminal Remoto)
echo "Configurando SSH Permanente..."
sudo systemctl enable --now ssh

# 3. Configurar Firewall (UFW)
echo "Configurando Firewall..."
# SSH
sudo ufw allow 22/tcp
# ADB (Scrcpy Wi-Fi)
sudo ufw allow 5555/tcp
# KDE Connect (caso use)
sudo ufw allow 1714:1764/udp
sudo ufw allow 1714:1764/tcp
# RustDesk (Acesso direto)
sudo ufw allow 21115:21119/tcp
sudo ufw allow 21116/udp
sudo ufw reload
echo "Regras de Firewall aplicadas."

# 4. Instalar RustDesk (Acesso Visual Permanente)
echo "Verificando RustDesk..."
if ! systemctl is-active --quiet rustdesk; then
    echo "Instalando RustDesk..."
    wget -O /tmp/rustdesk.deb https://github.com/rustdesk/rustdesk/releases/download/1.4.4/rustdesk-1.4.4-x86_64.deb
    sudo apt install -y /tmp/rustdesk.deb
    rm /tmp/rustdesk.deb
    sudo systemctl enable --now rustdesk
else
    echo "RustDesk já está instalado."
fi

# 5. Instalar Scrcpy (Snap)
echo "Verificando Scrcpy..."
if ! snap list scrcpy &> /dev/null; then
    echo "Instalando Scrcpy (Snap)..."
    sudo snap install scrcpy
else
    echo "Scrcpy já instalado."
fi

# 6. Criar Script de Espelhamento Automático (USB/Wi-Fi)
echo "Criando Script de Espelhamento Inteligente..."
SCRIPT_DIR="/home/lucas/Downloads/espelhar_celular_usb_wifi_linux"
mkdir -p "$SCRIPT_DIR"
SCRIPT_PATH="$SCRIPT_DIR/espelhar_auto.sh"

cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash

# Configurações
IP_CELULAR="192.168.0.24" # O script tenta achar o IP, mas esse é o padrão
echo "=== Monitoramento Iniciado ==="
echo "Plugue o USB para qualidade máxima. Tire para modo Wi-Fi."

PID_WIFI=""

while true; do
    # 1. Verifica se tem USB conectado (Ignora IPs de rede)
    if adb devices | grep -v "192.168" | grep -v "List" | grep -q "device$"; then
        
        # Se o Wi-Fi estiver rodando, fecha ele
        if [ -n "$PID_WIFI" ] && kill -0 "$PID_WIFI" 2>/dev/null; then
            echo "USB Detectado! Fechando janela Wi-Fi..."
            kill "$PID_WIFI"
            wait "$PID_WIFI" 2>/dev/null
            PID_WIFI=""
        fi

        # Roda o Scrcpy USB (HD) - Bloqueia o loop até fechar
        echo ">>> Abrindo USB (HD)..."
        /snap/bin/scrcpy -d --stay-awake --turn-screen-off --window-title="Scrcpy_USB_Ultra"
        
        echo "USB desconectado ou fechado."
        sleep 2

    else
        # 2. Modo Wi-Fi
        
        # Tenta conectar no ADB Wi-Fi se não estiver
        if ! adb devices | grep -q "5555"; then
             # Tenta conectar nos IPs conhecidos se o fixo falhar
             adb connect "$IP_CELULAR:5555" >/dev/null
             adb connect 192.168.0.12:5555 >/dev/null
             adb connect 192.168.0.13:5555 >/dev/null
        fi

        # Se a janela Wi-Fi NÃO estiver aberta, abre ela
        if [ -z "$PID_WIFI" ] || ! kill -0 "$PID_WIFI" 2>/dev/null; then
            echo ">>> Abrindo Wi-Fi (Leve)..."
            # Modo Otimizado: 400p, 400Kbps, 20fps, Codec H264
            /snap/bin/scrcpy -e --no-audio -m 400 -b 400K --max-fps 20 --video-codec=h264 --stay-awake --turn-screen-off --window-title="Scrcpy_WIFI_Leve" &
            PID_WIFI=$!
        fi
        
        sleep 2
    fi
done
EOF

chmod +x "$SCRIPT_PATH"

# Criar atalho no Menu de Aplicativos
echo "Criando atalho no menu..."
cat << EOF > ~/.local/share/applications/espelhar_auto.desktop
[Desktop Entry]
Type=Application
Name=Espelhar Celular (Auto)
Exec=$SCRIPT_PATH
Icon=phone
Terminal=true
Categories=Utility;Mobile;
Comment=Alterna automaticamente entre USB (HD) e Wi-Fi (Leve)
EOF

sudo update-desktop-database

echo -e "${GREEN}Configuração Local Concluída!${NC}"


# ==============================================================================
# PARTE 2: SERVIDOR RUSTDESK NA NUVEM (GCP)
# ==============================================================================

echo -e "\n${GREEN}[PARTE 2] Servidor RustDesk Próprio (Google Cloud)${NC}"
read -p "Deseja configurar seu servidor próprio na nuvem agora? (s/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Instalação finalizada. Aproveite seu PC configurado!"
    exit 0
fi

# 1. Verificar GCloud SDK
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Erro: gcloud CLI não encontrado.${NC}"
    echo "Instalando gcloud..."
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
    sudo apt update && sudo apt install google-cloud-cli -y
fi

# 2. Autenticação
KEY_FILE="$SCRIPT_DIR/gemini-gcloud-key.json"
if [ -f "$KEY_FILE" ]; then
    echo "Autenticando com chave JSON encontrada..."
    gcloud auth activate-service-account --key-file="$KEY_FILE"
else
    echo "Chave não encontrada em $KEY_FILE."
    echo "Por favor, faça login manualmente:"
    gcloud auth login
fi

# Selecionar Projeto
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}Nenhum projeto selecionado.${NC}"
    read -p "Digite o ID do seu Projeto Google Cloud: " PROJECT_ID
    gcloud config set project "$PROJECT_ID"
fi

echo -e "${GREEN}Usando Projeto: $PROJECT_ID${NC}"

# 3. Criar Regras de Firewall
echo "Configurando Firewall no GCP..."
gcloud compute firewall-rules create allow-rustdesk \
    --allow tcp:21115-21119,udp:21116 \
    --description="Permitir portas do RustDesk" \
    --direction=INGRESS 2>/dev/null || echo "Regra de firewall já existe."

# 4. Criar VM (e2-micro - Grátis nos EUA)
INSTANCE_NAME="rustdesk-server"
ZONE="us-central1-f" # Zona elegível para free tier

echo "Criando Máquina Virtual ($INSTANCE_NAME)..."
# Script de inicialização que instala o RustDesk Server (hbbs/hbbr) automaticamente
STARTUP_SCRIPT='#! /bin/bash
wget https://raw.githubusercontent.com/techahold/rustdesk-install/master/install.sh
chmod +x install.sh
./install.sh
'

gcloud compute instances create "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --network-interface=network-tier=PREMIUM,subnet=default \
    --metadata=startup-script="$STARTUP_SCRIPT" \
    --tags=http-server,https-server \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=30GB \
    --boot-disk-type=pd-standard \
    2>/dev/null || echo "VM já existe ou erro na criação."

# 5. Pegar Informações
echo -e "${GREEN}Aguardando a VM iniciar e instalar (pode levar 2-3 minutos)...${NC}"
sleep 10

EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo -e "${GREEN}=== INSTALAÇÃO CONCLUÍDA! ===${NC}"
echo ""
echo "Seu Servidor RustDesk está rodando!"
echo "-------------------------------------------------------"
echo "ID Server (Servidor de ID):  $EXTERNAL_IP"
echo "Relay Server (Servidor Relay): $EXTERNAL_IP"
echo "API Server:                  (deixe vazio)"
echo "-------------------------------------------------------"

echo ""
echo "Aguarde mais 1 minuto e rode este comando para pegar sua KEY (Chave):"
echo "gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --command='cat /opt/rustdesk/hbbs/id_ed25519.pub'"

