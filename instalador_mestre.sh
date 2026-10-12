#!/bin/bash
# Instalador mestre: acesso remoto (SSH, RustDesk), espelhamento (scrcpy) e servidor RustDesk no GCP.
#
# Parte local (PC):   status | enable | disable
# Parte nuvem (GCP):  gcp-status | gcp-enable | gcp-disable --confirm-delete
set -uo pipefail

# Cores para logs
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$TARGET_HOME/.local/state}/lubuntu-optimize}"
UFW_STATE="$STATE_DIR/espelhar-ufw-added"
APP_DIR="${APP_DIR:-$TARGET_HOME/.local/share/applications}"
LAUNCHER="$APP_DIR/espelhar_auto.desktop"
MIRROR_SCRIPT="$SCRIPT_DIR/espelhar_auto.sh"
RUSTDESK_VERSION="${RUSTDESK_VERSION:-1.4.4}"
RUSTDESK_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-x86_64.deb"
PACKAGES=(openssh-server ufw adb wget)
# regra ufw (argumento de "ufw allow")
UFW_RULES=("22/tcp" "5555/tcp" "1714:1764/udp" "1714:1764/tcp" "21115:21119/tcp" "21116/udp")

GCP_KEY_FILE="${GCP_KEY_FILE:-$SCRIPT_DIR/gemini-gcloud-key.json}"
GCP_INSTANCE="${GCP_INSTANCE:-rustdesk-server}"
GCP_ZONE="${GCP_ZONE:-us-central1-f}"   # zona elegível para free tier
GCP_FIREWALL_RULE="allow-rustdesk"

STATUS_FAIL=0

usage() {
    cat <<EOF
Uso:
  $SCRIPT_NAME status                 confere a parte local (somente leitura)
  $SCRIPT_NAME enable                 instala e habilita o que faltar na parte local
  $SCRIPT_NAME disable                desabilita SSH/RustDesk que este script habilitou, remove o atalho e as
                                      regras de firewall que ele adicionou (pacotes são mantidos)
  $SCRIPT_NAME gcp-status             confere regra de firewall e VM do servidor RustDesk no GCP (somente leitura)
  $SCRIPT_NAME gcp-enable             cria a regra de firewall e a VM no GCP se ainda não existirem
                                      (projeto atual do gcloud ou GCP_PROJECT_ID; sem perguntas interativas)
  $SCRIPT_NAME gcp-disable --confirm-delete
                                      APAGA a VM e a regra de firewall do GCP (exige a confirmação explícita)

Sobrescritas para teste: TARGET_HOME, STATE_DIR, APP_DIR, GCP_INSTANCE, GCP_ZONE, GCP_KEY_FILE.
EOF
}

die() { printf '%b[erro]%b %s\n' "$RED" "$NC" "$1" >&2; exit 1; }
applied() { printf 'aplicado: %s\n' "$*"; }
already() { printf 'ja ok: %s\n' "$*"; }
removed() { printf 'removido: %s\n' "$*"; }
already_off() { printf 'ja desabilitado: %s\n' "$*"; }

report() {
    if [[ "$1" == ok ]]; then
        printf '[ok] %s\n' "$2"
    else
        printf '[faltando] %s: %s\n' "$2" "$3"
        STATUS_FAIL=1
    fi
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

unit_on() {
    systemctl is-enabled --quiet "$1" 2>/dev/null && systemctl is-active --quiet "$1" 2>/dev/null
}

unit_any() {
    systemctl is-enabled --quiet "$1" 2>/dev/null || systemctl is-active --quiet "$1" 2>/dev/null
}

# ssh pode se chamar ssh ou sshd conforme a distribuição
ssh_unit() {
    if systemctl list-unit-files ssh.service >/dev/null 2>&1 && systemctl list-unit-files ssh.service | grep -q ssh.service; then
        printf 'ssh\n'
    else
        printf 'sshd\n'
    fi
}

gen_launcher() {
    cat <<EOF
[Desktop Entry]
Type=Application
Name=Espelhar Celular (Auto)
Exec=$MIRROR_SCRIPT
Icon=phone
Terminal=true
Categories=Utility;Mobile;
Comment=Alterna automaticamente entre USB (HD) e Wi-Fi (Leve)
EOF
}

launcher_ok() { [[ -f "$LAUNCHER" ]] && gen_launcher | cmp -s - "$LAUNCHER"; }

# Regras ufw já adicionadas (ufw show added precisa de root; vazio se indisponível).
ufw_added_rules() {
    sudo -n ufw show added 2>/dev/null | sed -n 's/^ufw allow //p' || true
}

ufw_has_rule() { printf '%s\n' "$1" | grep -qxF "$2"; }

# ---------------------------------------------------------------------------
# Parte local
# ---------------------------------------------------------------------------

do_enable() {
    local missing=() pkg rule added newly_added=()

    for pkg in "${PACKAGES[@]}"; do
        package_installed "$pkg" || missing+=("$pkg")
    done
    if ((${#missing[@]} == 0)); then
        already "pacotes (${PACKAGES[*]})"
    else
        sudo apt update && sudo apt install -y "${missing[@]}" || die "falha ao instalar ${missing[*]}"
        applied "pacotes instalados: ${missing[*]}"
    fi

    local ssh
    ssh="$(ssh_unit)"
    if unit_on "$ssh"; then
        already "SSH ($ssh) habilitado e ativo"
    else
        sudo systemctl enable --now "$ssh" && applied "SSH ($ssh) habilitado e ativo"
    fi

    # Firewall: só as regras que faltam; as adicionadas aqui ficam registradas para o disable.
    added="$(sudo ufw show added 2>/dev/null | sed -n 's/^ufw allow //p' || true)"
    mkdir -p "$STATE_DIR"
    for rule in "${UFW_RULES[@]}"; do
        if ufw_has_rule "$added" "$rule"; then
            already "ufw allow $rule"
        else
            sudo ufw allow "$rule" >/dev/null && applied "ufw allow $rule"
            printf '%s\n' "$rule" >> "$UFW_STATE"
            newly_added+=("$rule")
        fi
    done
    if ((${#newly_added[@]} > 0)); then
        sudo ufw reload >/dev/null || true
    fi

    # RustDesk (pacote .deb do GitHub) e serviço
    if package_installed rustdesk; then
        already "pacote rustdesk"
    else
        local deb="$STATE_DIR/downloads/rustdesk-${RUSTDESK_VERSION}.deb"
        mkdir -p "$(dirname "$deb")"
        wget -q -O "$deb" "$RUSTDESK_URL" || die "falha ao baixar $RUSTDESK_URL"
        sudo apt install -y "$deb" || die "falha ao instalar o RustDesk"
        rm -f "$deb"
        applied "pacote rustdesk ${RUSTDESK_VERSION}"
    fi
    if unit_on rustdesk; then
        already "serviço rustdesk habilitado e ativo"
    else
        sudo systemctl enable --now rustdesk && applied "serviço rustdesk habilitado e ativo"
    fi

    # scrcpy (snap)
    if snap list scrcpy >/dev/null 2>&1; then
        already "scrcpy (snap)"
    else
        sudo snap install scrcpy && applied "scrcpy (snap)"
    fi

    # Script de espelhamento: fonte única é espelhar_auto.sh, versionado ao lado deste instalador.
    [[ -x "$MIRROR_SCRIPT" ]] || die "$MIRROR_SCRIPT ausente ou sem permissão de execução"
    already "script de espelhamento ($MIRROR_SCRIPT)"

    if launcher_ok; then
        already "atalho no menu ($LAUNCHER)"
    else
        mkdir -p "$APP_DIR"
        gen_launcher > "$LAUNCHER"
        update-desktop-database "$APP_DIR" 2>/dev/null || true
        applied "atalho no menu ($LAUNCHER)"
    fi
}

do_disable() {
    local ssh rule remaining=""

    ssh="$(ssh_unit)"
    if unit_any rustdesk; then
        sudo systemctl disable --now rustdesk
        removed "serviço rustdesk parado e desabilitado"
    else
        already_off "serviço rustdesk"
    fi

    # SSH pode ter sido habilitado antes deste script e ser usado por outras coisas: não é desabilitado.
    printf 'mantido: SSH (%s) (pode ser usado fora deste instalador; desabilite à mão se quiser)\n' "$ssh"

    if [[ -f "$UFW_STATE" ]]; then
        while IFS= read -r rule; do
            [[ -n "$rule" ]] || continue
            if sudo ufw delete allow "$rule" >/dev/null 2>&1; then
                removed "ufw allow $rule"
            else
                remaining="$remaining$rule"$'\n'
                printf 'aviso: não consegui remover ufw allow %s (rode de novo com sudo disponível)\n' "$rule" >&2
            fi
        done < "$UFW_STATE"
        if [[ -n "$remaining" ]]; then
            printf '%s' "$remaining" > "$UFW_STATE"
        else
            rm -f "$UFW_STATE"
        fi
    else
        already_off "regras de firewall adicionadas por este script"
    fi

    if [[ -e "$LAUNCHER" ]]; then
        rm -f "$LAUNCHER"
        update-desktop-database "$APP_DIR" 2>/dev/null || true
        removed "atalho no menu"
    else
        already_off "atalho no menu"
    fi
}

do_status() {
    local pkg ssh rule added

    for pkg in "${PACKAGES[@]}"; do
        if package_installed "$pkg"; then report ok "pacote $pkg"; else report faltando "pacote $pkg" "não instalado"; fi
    done
    ssh="$(ssh_unit)"
    if unit_on "$ssh"; then report ok "SSH ($ssh) habilitado e ativo"; else report faltando "SSH ($ssh)" "desabilitado ou inativo"; fi

    added="$(ufw_added_rules)"
    if [[ -z "$added" ]]; then
        report faltando "regras ufw" "não verificável sem sudo sem senha (rode: sudo ufw show added)"
    else
        for rule in "${UFW_RULES[@]}"; do
            if ufw_has_rule "$added" "$rule"; then report ok "ufw allow $rule"; else report faltando "ufw allow $rule" "ausente"; fi
        done
    fi

    if package_installed rustdesk; then report ok "pacote rustdesk"; else report faltando "pacote rustdesk" "não instalado"; fi
    if unit_on rustdesk; then report ok "serviço rustdesk habilitado e ativo"; else report faltando "serviço rustdesk" "desabilitado ou inativo"; fi
    if snap list scrcpy >/dev/null 2>&1; then report ok "scrcpy (snap)"; else report faltando "scrcpy (snap)" "não instalado"; fi
    if [[ -x "$MIRROR_SCRIPT" ]]; then report ok "script de espelhamento"; else report faltando "script de espelhamento" "$MIRROR_SCRIPT ausente ou sem execução"; fi
    if launcher_ok; then report ok "atalho no menu"; else report faltando "atalho no menu" "$LAUNCHER ausente ou diferente"; fi
    return "$STATUS_FAIL"
}

# ---------------------------------------------------------------------------
# Parte nuvem (GCP): sem perguntas; o projeto vem do gcloud ou de GCP_PROJECT_ID
# ---------------------------------------------------------------------------

gcp_project() {
    local project
    project="$(gcloud config get-value project 2>/dev/null || true)"
    printf '%s\n' "${project:-${GCP_PROJECT_ID:-}}"
}

gcp_firewall_exists() { gcloud compute firewall-rules describe "$GCP_FIREWALL_RULE" >/dev/null 2>&1; }
gcp_vm_exists() { gcloud compute instances describe "$GCP_INSTANCE" --zone="$GCP_ZONE" >/dev/null 2>&1; }
gcp_vm_ip() { gcloud compute instances describe "$GCP_INSTANCE" --zone="$GCP_ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null; }

gcp_require_gcloud() {
    command -v gcloud >/dev/null 2>&1 || die "gcloud CLI não encontrado (instale com: sudo snap install google-cloud-cli --classic)"
}

gcp_ensure_auth() {
    if [[ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ]]; then
        already "gcloud autenticado"
        return
    fi
    if [[ -f "$GCP_KEY_FILE" ]]; then
        gcloud auth activate-service-account --key-file="$GCP_KEY_FILE" || die "falha ao autenticar com $GCP_KEY_FILE"
        applied "gcloud autenticado com a chave de serviço"
    else
        die "gcloud sem conta ativa e sem chave em $GCP_KEY_FILE; rode: gcloud auth login"
    fi
}

gcp_do_status() {
    gcp_require_gcloud
    local project
    project="$(gcp_project)"
    if [[ -n "$project" ]]; then report ok "projeto GCP: $project"; else report faltando "projeto GCP" "nenhum selecionado (gcloud config set project ID ou GCP_PROJECT_ID)"; fi
    if gcp_firewall_exists; then report ok "regra de firewall $GCP_FIREWALL_RULE"; else report faltando "regra de firewall $GCP_FIREWALL_RULE" "ausente"; fi
    if gcp_vm_exists; then report ok "VM $GCP_INSTANCE ($GCP_ZONE)"; else report faltando "VM $GCP_INSTANCE" "ausente"; fi
    return "$STATUS_FAIL"
}

gcp_do_enable() {
    gcp_require_gcloud
    gcp_ensure_auth

    local project
    project="$(gcp_project)"
    [[ -n "$project" ]] || die "nenhum projeto GCP selecionado: use gcloud config set project ID ou GCP_PROJECT_ID=ID"
    if [[ "$(gcloud config get-value project 2>/dev/null || true)" != "$project" ]]; then
        gcloud config set project "$project" >/dev/null
        applied "projeto GCP: $project"
    else
        already "projeto GCP: $project"
    fi

    if gcp_firewall_exists; then
        already "regra de firewall $GCP_FIREWALL_RULE"
    else
        gcloud compute firewall-rules create "$GCP_FIREWALL_RULE" \
            --allow tcp:21115-21119,udp:21116 \
            --description="Permitir portas do RustDesk" \
            --direction=INGRESS || die "falha ao criar a regra de firewall"
        applied "regra de firewall $GCP_FIREWALL_RULE"
    fi

    if gcp_vm_exists; then
        already "VM $GCP_INSTANCE ($GCP_ZONE)"
    else
        # Script de inicialização que instala o RustDesk Server (hbbs/hbbr) automaticamente
        local startup_script='#! /bin/bash
wget https://raw.githubusercontent.com/techahold/rustdesk-install/master/install.sh
chmod +x install.sh
./install.sh
'
        gcloud compute instances create "$GCP_INSTANCE" \
            --project="$project" \
            --zone="$GCP_ZONE" \
            --machine-type=e2-micro \
            --network-interface=network-tier=PREMIUM,subnet=default \
            --metadata=startup-script="$startup_script" \
            --tags=http-server,https-server \
            --image-family=ubuntu-2204-lts \
            --image-project=ubuntu-os-cloud \
            --boot-disk-size=30GB \
            --boot-disk-type=pd-standard || die "falha ao criar a VM"
        applied "VM $GCP_INSTANCE ($GCP_ZONE) criada; a instalação do servidor leva 2-3 minutos"
    fi

    local ip
    ip="$(gcp_vm_ip)"
    printf 'Servidor de ID e Relay: %s (API Server: deixe vazio)\n' "${ip:-indisponível}"
    printf 'Chave pública, depois de 1 a 2 minutos:\n'
    printf "  gcloud compute ssh %s --zone=%s --command='cat /opt/rustdesk/hbbs/id_ed25519.pub'\n" "$GCP_INSTANCE" "$GCP_ZONE"
}

gcp_do_disable() {
    gcp_require_gcloud
    if [[ "${1:-}" != "--confirm-delete" ]]; then
        die "gcp-disable APAGA a VM $GCP_INSTANCE e a regra $GCP_FIREWALL_RULE no GCP; repita com --confirm-delete"
    fi

    if gcp_vm_exists; then
        gcloud compute instances delete "$GCP_INSTANCE" --zone="$GCP_ZONE" --quiet && removed "VM $GCP_INSTANCE"
    else
        already_off "VM $GCP_INSTANCE"
    fi
    if gcp_firewall_exists; then
        gcloud compute firewall-rules delete "$GCP_FIREWALL_RULE" --quiet && removed "regra de firewall $GCP_FIREWALL_RULE"
    else
        already_off "regra de firewall $GCP_FIREWALL_RULE"
    fi
}

case "${1:-help}" in
    status) do_status ;;
    enable) do_enable ;;
    disable) do_disable ;;
    gcp-status) gcp_do_status ;;
    gcp-enable) gcp_do_enable ;;
    gcp-disable) shift; gcp_do_disable "${1:-}" ;;
    help|-h|--help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
