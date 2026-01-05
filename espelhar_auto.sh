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
