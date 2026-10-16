#!/bin/bash

# Cloudflare WARP Socks5 Manager (Force IP Rotation & Gemini Check)
# Optimized for Ubuntu VPS

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT_FILE="/etc/warp_socks_port"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Please run this script as root.${NC}"
    exit 1
fi

get_current_port() {
    if [ -f "$PORT_FILE" ]; then
        cat "$PORT_FILE"
    else
        echo "40000"
    fi
}

check_gemini() {
    local port=$1
    echo -e "${CYAN}[*] Testing connection to Gemini API via Socks5...${NC}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --socks5 127.0.0.1:"$port" --max-time 7 "https://generativelanguage.googleapis.com/")
    
    if [ "$code" == "200" ] || [ "$code" == "404" ] || [ "$code" == "400" ]; then
        echo -e "${GREEN}[+] SUCCESS: Clean IP! Gemini is reachable (HTTP $code).${NC}"
        return 0
    elif [ "$code" == "403" ]; then
        echo -e "${RED}[-] FAILED: Dirty IP (HTTP 403 Forbidden). Google blocked this IP.${NC}"
        echo -e "${YELLOW}[!] Use Option 2 to rotate/change WARP IP.${NC}"
        return 1
    else
        echo -e "${YELLOW}[!] Timeout or unexpected response (HTTP $code).${NC}"
        return 2
    fi
}

show_status() {
    local port
    port=$(get_current_port)
    echo -e "\n${BLUE}================ WARP STATUS ================${NC}"
    
    local warp_ip warp_loc
    warp_ip=$(curl -s --socks5 127.0.0.1:"$port" --max-time 5 "https://api64.ipify.org" 2>/dev/null)
    [ -z "$warp_ip" ] && warp_ip=$(curl -s --socks5 127.0.0.1:"$port" --max-time 5 "https://icanhazip.com" | tr -d '\n' 2>/dev/null)

    if [ -n "$warp_ip" ]; then
        warp_loc=$(curl -s --socks5 127.0.0.1:"$port" --max-time 5 "https://ipwho.is/${warp_ip}" 2>/dev/null | grep -oP '"country":"\K[^"]+')
        [ -z "$warp_loc" ] && warp_loc="Cloudflare Network"
        
        echo -e "Socks5 Address : ${GREEN}127.0.0.1:${port}${NC}"
        echo -e "WARP Client IP : ${GREEN}${warp_ip}${NC}"
        echo -e "Location       : ${GREEN}${warp_loc}${NC}"
        echo -e "Proxy Mode     : ${GREEN}Active${NC}"
    else
        echo -e "${RED}[!] WARP is disconnected or port $port is not responding.${NC}"
    fi
    echo -e "${BLUE}=============================================${NC}\n"
}

install_warp() {
    echo -e "${CYAN}[*] Installing dependencies and Cloudflare repository...${NC}"
    apt update -y && apt install -y curl gpg lsb-release
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    apt update -y
    apt install -y cloudflare-warp

    local port
    port=$(shuf -i 20000-55000 -n 1)
    echo "$port" > "$PORT_FILE"

    echo -e "${YELLOW}[*] Configuring WARP proxy mode on port ${port}...${NC}"
    systemctl enable --now warp-svc
    sleep 2

    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port "$port"
    warp-cli --accept-tos connect
    sleep 4

    show_status
    check_gemini "$port"
}

change_ip() {
    local port
    port=$(get_current_port)
    
    local old_ip
    old_ip=$(curl -s --socks5 127.0.0.1:"$port" --max-time 4 "https://api64.ipify.org" 2>/dev/null)
    echo -e "${YELLOW}[*] Current WARP IP: ${old_ip:-Unknown}${NC}"
    echo -e "${YELLOW}[*] Forcing IP rotation (Requesting new route)...${NC}"

    local attempt=1
    local max_attempts=5
    local new_ip=""

    # لیست اندپوینت‌های مختلف کلودفلر برای اجبار به تغییر نود خروجی
    local endpoints=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.1" "188.114.97.1")

    while [ $attempt -le $max_attempts ]; do
        echo -e "${CYAN}[*] Attempt $attempt/$max_attempts...${NC}"
        
        warp-cli --accept-tos disconnect >/dev/null 2>&1
        systemctl stop warp-svc
        
        # پاک‌سازی کامل سشن و ساخت کلاینت جدید
        rm -rf /var/lib/cloudflare-warp/reg.json
        rm -rf /var/lib/cloudflare-warp/identity.json
        rm -rf /var/lib/cloudflare-warp/settings.json
        
        systemctl start warp-svc
        sleep 2

        warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null
        warp-cli --accept-tos mode proxy >/dev/null 2>&1
        warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1
        
        # چرخش پورت یا اندپوینت مقصد
        local random_ep=${endpoints[$RANDOM % ${#endpoints[@]}]}
        warp-cli --accept-tos tunnel endpoint set "${random_ep}:2408" 2>/dev/null || true

        warp-cli --accept-tos connect >/dev/null 2>&1
        sleep 4

        new_ip=$(curl -s --socks5 127.0.0.1:"$port" --max-time 5 "https://api64.ipify.org" 2>/dev/null)
        
        if [ -n "$new_ip" ] && [ "$new_ip" != "$old_ip" ]; then
            echo -e "${GREEN}[+] Success! IP rotated from $old_ip to $new_ip${NC}"
            break
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    show_status
    check_gemini "$port"
}

uninstall_warp() {
    echo -e "${RED}[*] Completely uninstalling WARP...${NC}"
    warp-cli --accept-tos disconnect >/dev/null 2>&1
    systemctl stop warp-svc 2>/dev/null
    systemctl disable warp-svc 2>/dev/null
    apt purge -y cloudflare-warp
    rm -rf /var/lib/cloudflare-warp
    rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg "$PORT_FILE"
    echo -e "${GREEN}[+] Cloudflare WARP has been removed.${NC}"
}

clear
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}     WARP Socks5 Manager (Gemini Fix)       ${NC}"
echo -e "${CYAN}============================================${NC}"
echo -e "1) ${GREEN}Install WARP (Random Port + Auto Gemini Test)${NC}"
echo -e "2) ${YELLOW}Change/Rotate WARP IP (Force New IP)${NC}"
echo -e "3) ${BLUE}Show Current IP & Port${NC}"
echo -e "4) ${CYAN}Test Gemini Connection${NC}"
echo -e "5) ${RED}Uninstall WARP${NC}"
echo -e "0) Exit"
echo -e "${CYAN}--------------------------------------------${NC}"
read -rp "Select an option [0-5]: " c

case $c in
    1) install_warp ;;
    2) change_ip ;;
    3) show_status ;;
    4) check_gemini "$(get_current_port)" ;;
    5) uninstall_warp ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid option!${NC}" ;;
esac
