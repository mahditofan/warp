#!/bin/bash

# Cloudflare WARP Socks5 Manager - Dual Stack (IPv4 & IPv6)
# Fixed Port 41950 - Direct Cloudflare Meta Sync

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FIXED_PORT=41950

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Please run this script as root.${NC}"
    exit 1
fi

get_cf_meta() {
    curl -s --socks5 127.0.0.1:${FIXED_PORT} --max-time 6 "https://speed.cloudflare.com/meta" 2>/dev/null
}

check_gemini() {
    echo -e "${CYAN}[*] Testing connection to Gemini API via Socks5...${NC}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --socks5 127.0.0.1:${FIXED_PORT} --max-time 8 "https://generativelanguage.googleapis.com/")
    
    if [ "$code" == "200" ] || [ "$code" == "404" ] || [ "$code" == "400" ]; then
        echo -e "${GREEN}[+] SUCCESS: Clean IP! Gemini is reachable (HTTP $code).${NC}"
        return 0
    elif [ "$code" == "403" ]; then
        echo -e "${RED}[-] FAILED: Dirty IP (HTTP 403 Forbidden). Google blocked this IP.${NC}"
        echo -e "${YELLOW}[!] Use Option 2 to rotate WARP IP.${NC}"
        return 1
    else
        echo -e "${YELLOW}[!] Timeout or unexpected response (HTTP $code).${NC}"
        return 2
    fi
}

show_status() {
    echo -e "\n${BLUE}================ WARP STATUS ================${NC}"
    
    local meta
    meta=$(get_cf_meta)
    
    local v4 v6 loc
    # استخراج آی‌پی‌ها دقیقاً از سورس اختصاصی کلودفلر
    v4=$(curl -s -4 --socks5 127.0.0.1:${FIXED_PORT} --max-time 5 "https://api.ipify.org" 2>/dev/null)
    [ -z "$v4" ] && v4=$(echo "$meta" | grep -oP '"clientIp":"\K[^"]+')
    
    v6=$(curl -s -6 --socks5 127.0.0.1:${FIXED_PORT} --max-time 5 "https://api64.ipify.org" 2>/dev/null)
    loc=$(echo "$meta" | grep -oP '"country":"\K[^"]+')
    [ -z "$loc" ] && loc="Cloudflare Network"

    if [ -n "$v4" ] || [ -n "$v6" ]; then
        echo -e "Socks5 Address : ${GREEN}127.0.0.1:${FIXED_PORT}${NC}"
        echo -e "WARP IPv4      : ${GREEN}${v4:-Not Detected}${NC}"
        echo -e "WARP IPv6      : ${GREEN}${v6:-Not Detected}${NC}"
        echo -e "Location       : ${GREEN}${loc}${NC}"
        echo -e "Proxy Mode     : ${GREEN}Active${NC}"
    else
        echo -e "${RED}[!] WARP is disconnected or port ${FIXED_PORT} is not responding.${NC}"
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

    echo -e "${YELLOW}[*] Configuring WARP on fixed port ${FIXED_PORT}...${NC}"
    systemctl restart warp-svc
    sleep 2

    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port "$FIXED_PORT"
    warp-cli --accept-tos connect
    sleep 3

    show_status
    check_gemini
}

change_ip() {
    echo -e "${YELLOW}[*] Purging WARP session and requesting completely new identity...${NC}"

    warp-cli --accept-tos disconnect >/dev/null 2>&1
    sleep 1
    warp-cli --accept-tos registration delete >/dev/null 2>&1
    
    # ریستارت سریع دیمن جهت حذف هرگونه کش محلی
    systemctl restart warp-svc
    sleep 2

    warp-cli --accept-tos registration new >/dev/null 2>&1 || warp-cli --accept-tos register >/dev/null 2>&1
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port "$FIXED_PORT" >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
    sleep 4

    echo -e "${GREEN}[+] New identity generated!${NC}"
    show_status
    check_gemini
}

uninstall_warp() {
    echo -e "${RED}[*] Completely uninstalling WARP...${NC}"
    warp-cli --accept-tos disconnect >/dev/null 2>&1
    systemctl stop warp-svc 2>/dev/null
    systemctl disable warp-svc 2>/dev/null
    apt purge -y cloudflare-warp
    rm -rf /var/lib/cloudflare-warp
    rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo -e "${GREEN}[+] WARP uninstalled successfully.${NC}"
}

clear
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   WARP Manager (Fixed Port ${FIXED_PORT})   ${NC}"
echo -e "${CYAN}============================================${NC}"
echo -e "1) ${GREEN}Install / Reinstall WARP${NC}"
echo -e "2) ${YELLOW}Change / Rotate WARP IP${NC}"
echo -e "3) ${BLUE}Show Current IP & Status${NC}"
echo -e "4) ${CYAN}Test Gemini Connection${NC}"
echo -e "5) ${RED}Uninstall WARP${NC}"
echo -e "0) Exit"
echo -e "${CYAN}--------------------------------------------${NC}"
read -rp "Select an option [0-5]: " c

case $c in
    1) install_warp ;;
    2) change_ip ;;
    3) show_status ;;
    4) check_gemini ;;
    5) uninstall_warp ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid option!${NC}" ;;
esac
