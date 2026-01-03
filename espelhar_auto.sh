#!/bin/bash

IP_CELULAR="192.168.0.24"

echo "=== Monitoramento Iniciado ==="
echo "Plugue o USB para qualidade maxima. Tire para modo Wi-Fi."

PID_WIFI=""

while true; do
    # 1. Verifica se tem USB conectado (Exclui IPs e linhas de cabecalho)
    if adb devices | grep -v "192.168" | grep -v "List" | grep -q "device$"; then
        
        # Se o Wi-Fi estiver rodando, mata ele com cuidado
        if [ -n "$PID_WIFI" ] && kill -0 "$PID_WIFI" 2>/dev/null; then
            echo "USB Detectado! Fechando janela Wi-Fi..."
            kill "$PID_WIFI"
            wait "$PID_WIFI" 2>/dev/null
            PID_WIFI=""
        fi

        # Roda o Scrcpy USB (O script para aqui e espera voce fechar a janela ou tirar o cabo)
        echo ">>> Abrindo USB (HD)..."
        /snap/bin/scrcpy -d --stay-awake --turn-screen-off --window-title="Scrcpy_USB_Ultra"
        
        echo "USB desconectado ou fechado."
        sleep 2

    else
        # 2. Modo Wi-Fi
        
        # Verifica se o ADB esta conectado no IP
        if ! adb devices | grep -q "$IP_CELULAR"; then
             adb connect "$IP_CELULAR:5555" >/dev/null
        fi

        # Se a janela Wi-Fi NAO estiver aberta, abre ela em background
        if [ -z "$PID_WIFI" ] || ! kill -0 "$PID_WIFI" 2>/dev/null; then
            echo ">>> Abrindo Wi-Fi (Leve)..."
            /snap/bin/scrcpy -e --no-audio -m 400 -b 400K --max-fps 20 --video-codec=h264 --stay-awake --turn-screen-off --window-title="Scrcpy_WIFI_Leve" &
            PID_WIFI=$!
        fi
        
        sleep 2
    fi
done

