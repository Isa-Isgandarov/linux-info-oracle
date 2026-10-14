#!/bin/bash
# =====================================================
# Server - Sistem Məlumatları Skripti
# Dəstəklənir: Oracle Linux / RHEL / Rocky / Alma / Ubuntu / Debian
# İstifadə: sudo bash sistem_melumat.sh
# =====================================================

# Rəng kodları
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

line() {
    echo -e "${CYAN}--------------------------------------------------${NC}"
}

header() {
    echo ""
    line
    echo -e "${YELLOW}$1${NC}"
    line
}

# Baytı oxunaqlı formata çevirir (məs: 1.5 GB)
human_size() {
    awk -v b="$1" 'BEGIN{
        split("B KB MB GB TB PB", u, " "); i=1;
        while (b>=1024 && i<6) { b/=1024; i++ }
        printf "%.1f %s", b, u[i]
    }'
}

# ---------------------------------------------------
# Distributiv ailəsini müəyyən edirik (Oracle Linux = RHEL ailəsi)
# ---------------------------------------------------
if [ -f /etc/redhat-release ] || [ -f /etc/oracle-release ]; then
    DISTRO_FAMILY="rhel"
elif [ -f /etc/debian_version ]; then
    DISTRO_FAMILY="debian"
else
    DISTRO_FAMILY="other"
fi

# Root yoxlanışı (ss -p, du /root və s. üçün lazımdır)
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}DİQQƏT:${NC} Skript root olmadan işləyir. Bəzi məlumatlar (proses adları, /root ölçüsü) görünməyəcək."
    echo -e "         Tam nəticə üçün: ${GREEN}sudo bash $0${NC}"
fi

# ---------------------------------------------------
header "1. ÜMUMİ SİSTEM MƏLUMATI"
echo -e "${GREEN}Hostname:${NC} $(hostname)"
echo -e "${GREEN}OS:${NC} $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f2)"
echo -e "${GREEN}Ailə:${NC} $DISTRO_FAMILY"
echo -e "${GREEN}Kernel:${NC} $(uname -r)"
echo -e "${GREEN}Arxitektura:${NC} $(uname -m)"
echo -e "${GREEN}Uptime:${NC} $(uptime -p 2>/dev/null || uptime)"

# ---------------------------------------------------
header "2. TARİX VƏ SAAT"
echo -e "${GREEN}Sistem saatı:${NC} $(date)"
if command -v timedatectl >/dev/null 2>&1; then
    TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null)
    echo -e "${GREEN}Timezone:${NC} ${TZ_NAME:-Naməlum}"
    NTP_STATUS=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    echo -e "${GREEN}NTP sinxronizasiyası:${NC} ${NTP_STATUS:-Naməlum}"
else
    echo -e "${GREEN}Timezone:${NC} $(date +%Z)"
fi

# ---------------------------------------------------
header "3. ŞƏBƏKƏ / IP MƏLUMATLARI"

# Əsas interfeys: default route-un istifadə etdiyi interfeys (ən dəqiq üsul)
MAIN_IF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

# Tapılmasa: loopback, docker, bridge, veth istisna olmaqla ilk interfeys
if [ -z "$MAIN_IF" ]; then
    MAIN_IF=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -Ev '^(lo|docker|br-|veth|virbr|cni|flannel)' | head -n1)
fi

if [ -z "$MAIN_IF" ]; then
    echo "Əsas şəbəkə interfeysi tapılmadı."
else
    IP_ADDR=$(ip -4 -o addr show dev "$MAIN_IF" 2>/dev/null | awk '{print $4}' | paste -sd' ' -)
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    echo -e "${GREEN}İnterfeys:${NC} $MAIN_IF"
    echo -e "${GREEN}IP ünvanı:${NC} ${IP_ADDR:-yoxdur}"
    echo -e "${GREEN}Gateway:${NC} ${GATEWAY:-yoxdur}"

    # Statik / Dinamik yoxlanışı (bir neçə üsulla, sırayla yoxlanılır)
    IP_METHOD=""
    IP_SOURCE=""

    # Üsul 1: NetworkManager (Oracle Linux / RHEL standartı)
    if command -v nmcli >/dev/null 2>&1; then
        CONN_NAME=$(nmcli -g GENERAL.CONNECTION device show "$MAIN_IF" 2>/dev/null)
        if [ -n "$CONN_NAME" ] && [ "$CONN_NAME" != "--" ]; then
            METHOD=$(nmcli -g ipv4.method connection show "$CONN_NAME" 2>/dev/null)
            case "$METHOD" in
                manual) IP_METHOD="STATİK"; IP_SOURCE="NetworkManager: $CONN_NAME" ;;
                auto)   IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="NetworkManager: $CONN_NAME" ;;
            esac
        fi
    fi

    # Üsul 2: Köhnə RHEL/Oracle Linux 7-8 ifcfg faylları
    if [ -z "$IP_METHOD" ] && [ -f "/etc/sysconfig/network-scripts/ifcfg-$MAIN_IF" ]; then
        BOOTPROTO=$(grep -i '^BOOTPROTO' "/etc/sysconfig/network-scripts/ifcfg-$MAIN_IF" | cut -d= -f2 | tr -d '"' | tr 'A-Z' 'a-z')
        case "$BOOTPROTO" in
            dhcp)         IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="ifcfg-$MAIN_IF" ;;
            none|static)  IP_METHOD="STATİK"; IP_SOURCE="ifcfg-$MAIN_IF" ;;
        esac
    fi

    # Üsul 3: Netplan (Ubuntu)
    if [ -z "$IP_METHOD" ] && [ -d /etc/netplan ]; then
        if grep -rq "dhcp4:\s*true" /etc/netplan/*.yaml 2>/dev/null; then
            IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="netplan"
        elif grep -rqE "addresses:" /etc/netplan/*.yaml 2>/dev/null; then
            IP_METHOD="STATİK"; IP_SOURCE="netplan"
        fi
    fi

    # Üsul 4: DHCP lease faylı axtarışı
    if [ -z "$IP_METHOD" ]; then
        if ls /var/lib/dhcp/*"$MAIN_IF"*.lease* >/dev/null 2>&1 || \
           ls /var/lib/NetworkManager/*"$MAIN_IF"*.lease >/dev/null 2>&1 || \
           ls /run/systemd/netif/leases/* >/dev/null 2>&1; then
            IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="lease faylı tapıldı"
        fi
    fi

    # Üsul 5 (son çarə): valid_lft forever varsa, adətən statikdir
    if [ -z "$IP_METHOD" ]; then
        LFT_LINE=$(ip -4 addr show "$MAIN_IF" | grep "valid_lft")
        if echo "$LFT_LINE" | grep -q "valid_lft forever"; then
            IP_METHOD="STATİK (ehtimal, valid_lft=forever əsasında)"; IP_SOURCE="ip addr çıxışı"
        elif [ -n "$LFT_LINE" ]; then
            IP_METHOD="DİNAMİK (ehtimal, DHCP lease vaxtı var)"; IP_SOURCE="ip addr çıxışı"
        else
            IP_METHOD="Naməlum"; IP_SOURCE="heç bir üsulla aşkarlanmadı"
        fi
    fi

    echo -e "${GREEN}IP tipi:${NC} $IP_METHOD  ${CYAN}(mənbə: $IP_SOURCE)${NC}"
fi

echo -e "${GREEN}DNS serverləri:${NC}"
# Oracle Linux 9-da systemd-resolved adətən işləmir, /etc/resolv.conf istifadə olunur
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    resolvectl status 2>/dev/null | grep -E "DNS Server|Current DNS" | sed 's/^/  /'
else
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
fi

# ---------------------------------------------------
header "4. KONTEYNER MƏLUMATLARI (Docker / Podman)"
CONTAINER_FOUND=0
if command -v docker >/dev/null 2>&1; then
    CONTAINER_FOUND=1
    echo -e "${GREEN}Docker quraşdırılıb.${NC} Versiya: $(docker --version 2>/dev/null)"
    if docker info >/dev/null 2>&1; then
        echo ""
        echo -e "${GREEN}İşləyən konteynerlər və portlar:${NC}"
        docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
        echo ""
        RUNNING_COUNT=$(docker ps -q 2>/dev/null | wc -l)
        TOTAL_COUNT=$(docker ps -aq 2>/dev/null | wc -l)
        echo -e "${GREEN}İşləyən:${NC} $RUNNING_COUNT   ${GREEN}Cəmi (dayandırılmış daxil):${NC} $TOTAL_COUNT"
    else
        echo -e "${RED}Docker daemon işləmir və ya icazə yoxdur.${NC}"
        echo "  Başlatmaq üçün: sudo systemctl enable --now docker"
    fi
fi
if command -v podman >/dev/null 2>&1; then
    CONTAINER_FOUND=1
    echo ""
    echo -e "${GREEN}Podman quraşdırılıb.${NC} Versiya: $(podman --version 2>/dev/null)"
    podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
fi
[ "$CONTAINER_FOUND" -eq 0 ] && echo "Docker / Podman quraşdırılmayıb."

# ---------------------------------------------------
header "5. FIREWALL STATUSU"
if command -v firewall-cmd >/dev/null 2>&1; then
    # Oracle Linux / RHEL: firewalld
    if firewall-cmd --state >/dev/null 2>&1; then
        echo -e "${GREEN}firewalld:${NC} ${GREEN}AKTİV${NC}"
        echo -e "${GREEN}Default zona:${NC} $(firewall-cmd --get-default-zone 2>/dev/null)"
        echo ""
        echo -e "${GREEN}Aktiv zonalar və qaydalar:${NC}"
        firewall-cmd --list-all 2>/dev/null | sed 's/^/  /'
    else
        echo -e "${GREEN}firewalld:${NC} ${RED}DEAKTİV (söndürülüb)${NC}"
        echo -e "  Aktiv etmək üçün: sudo systemctl enable --now firewalld"
    fi
elif command -v ufw >/dev/null 2>&1; then
    # Ubuntu: ufw
    UFW_RAW=$(ufw status 2>/dev/null | head -n1)
    if echo "$UFW_RAW" | grep -qi "inactive"; then
        echo -e "${GREEN}UFW:${NC} ${RED}DEAKTİV (söndürülüb)${NC}"
        echo -e "  Aktiv etmək üçün: sudo ufw enable"
    elif echo "$UFW_RAW" | grep -qi "active"; then
        echo -e "${GREEN}UFW:${NC} ${GREEN}AKTİV${NC}"
        echo ""
        echo -e "${GREEN}Qaydalar:${NC}"
        ufw status verbose 2>/dev/null | sed 's/^/  /'
    else
        echo -e "${GREEN}UFW:${NC} Status müəyyən edilə bilmədi (sudo ilə işlətməyi yoxlayın)"
    fi
else
    echo "firewalld/UFW tapılmadı. nftables/iptables qaydalarına baxılır:"
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset 2>/dev/null | head -n 20 | sed 's/^/  /'
    else
        iptables -L -n 2>/dev/null | head -n 15 | sed 's/^/  /'
    fi
fi

# ---------------------------------------------------
header "6. LSM (SELinux / AppArmor) STATUSU"
# Oracle Linux / RHEL-də SELinux, Ubuntu/Debian-da AppArmor istifadə olunur
if command -v getenforce >/dev/null 2>&1; then
    SE_STATE=$(getenforce 2>/dev/null)
    case "$SE_STATE" in
        Enforcing)
            echo -e "${GREEN}SELinux:${NC} ${GREEN}Enforcing (AKTİV)${NC}"
            echo -e "  Müvəqqəti permissive etmək üçün: sudo setenforce 0"
            ;;
        Permissive)
            echo -e "${GREEN}SELinux:${NC} ${YELLOW}Permissive (yalnız log yazır, bloklamır)${NC}"
            echo -e "  Enforcing etmək üçün: sudo setenforce 1"
            ;;
        *)
            echo -e "${GREEN}SELinux:${NC} ${RED}${SE_STATE:-Naməlum} (DEAKTİV)${NC}"
            echo -e "  Aktiv etmək üçün /etc/selinux/config faylında SELINUX=enforcing yazıb reboot edin"
            ;;
    esac
    if command -v sestatus >/dev/null 2>&1; then
        echo ""
        sestatus 2>/dev/null | grep -E "SELinux status|Current mode|Mode from config file|Loaded policy name" | sed 's/^/  /'
    fi
    echo -e "  Daimi dəyişiklik üçün: /etc/selinux/config faylında SELINUX=enforcing / permissive / disabled"
elif command -v aa-status >/dev/null 2>&1; then
    if aa-status --enabled >/dev/null 2>&1; then
        echo -e "${GREEN}AppArmor:${NC} ${GREEN}AKTİV${NC}"
        echo ""
        aa-status 2>/dev/null | grep -E "profiles are (loaded|in enforce|in complain)" | sed 's/^/  /'
        echo ""
        echo -e "  Deaktiv etmək üçün: sudo systemctl stop apparmor && sudo systemctl disable apparmor"
    else
        echo -e "${GREEN}AppArmor:${NC} ${RED}DEAKTİV${NC}"
        echo -e "  Aktiv etmək üçün: sudo systemctl start apparmor && sudo systemctl enable apparmor"
    fi
else
    echo "Nə SELinux, nə də AppArmor tapılmadı."
    if [ "$DISTRO_FAMILY" = "rhel" ]; then
        echo "  Quraşdırmaq üçün: sudo dnf install selinux-policy selinux-policy-targeted policycoreutils"
    else
        echo "  Quraşdırmaq üçün: sudo apt install apparmor apparmor-utils"
    fi
fi

# ---------------------------------------------------
header "7. DİNLƏNƏN PORTLAR (ss -tulpn)"
if command -v ss >/dev/null 2>&1; then
    echo -e "${GREEN}Proto  Local Address:Port         Proses${NC}"
    ss -tulpn 2>/dev/null | awk 'NR>1 {print "  " $1, $5, $7}'
else
    echo "ss əmri tapılmadı. netstat yoxlanılır:"
    netstat -tulpn 2>/dev/null | sed 's/^/  /'
fi

# ---------------------------------------------------
header "8. DİSK MƏLUMATI"

echo -e "${GREEN}Fayl sistemləri (tmpfs/overlay istisna):${NC}"
df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | sed 's/^/  /'

echo ""
echo -e "${GREEN}Əsas qovluqların yerləşdiyi disk bölmələri:${NC}"
for P in / /home /root; do
    [ -e "$P" ] || continue
    df -h --output=target,source,size,used,avail,pcent "$P" 2>/dev/null | tail -n1 | \
        awk -v p="$P" '{printf "  %-7s -> bölmə: %-22s ölçü: %-6s istifadə: %-6s boş: %-6s doluluq: %s\n", p, $2, $3, $4, $5, $6}'
done

# Doluluq xəbərdarlığı (85%-dən çox olan bölmələr)
echo ""
FULL=$(df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if ($5+0>=85) print "  " $6 " -> " $5 "% dolu"}')
if [ -n "$FULL" ]; then
    echo -e "${RED}XƏBƏRDARLIQ - 85%-dən çox dolu bölmələr:${NC}"
    echo "$FULL"
else
    echo -e "${GREEN}Heç bir bölmə 85%-dən çox dolu deyil.${NC}"
fi

echo ""
echo -e "${GREEN}Inode istifadəsi (/):${NC}"
df -i / 2>/dev/null | tail -n1 | awk '{printf "  Cəmi: %s  İstifadə: %s  Boş: %s  Doluluq: %s\n", $2, $3, $4, $5}'

echo ""
echo -e "${GREEN}Ümumi ölçülər:${NC}"
if [ -d /home ]; then
    echo -e "  /home cəmi: $(du -sh -x /home 2>/dev/null | cut -f1)"
fi
if [ -d /root ]; then
    echo -e "  /root cəmi: $(du -sh -x /root 2>/dev/null | cut -f1)"
fi

echo ""
echo -e "${GREEN}Hər istifadəçinin home qovluğu:${NC}"
if [ -d /home ] && [ -n "$(ls -A /home 2>/dev/null)" ]; then
    du -sh -x /home/* 2>/dev/null | sort -rh | awk '{printf "  %-8s %s\n", $1, $2}'
else
    echo "  /home boşdur."
fi

# Docker disk istifadəsi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo ""
    echo -e "${GREEN}Docker disk istifadəsi:${NC}"
    docker system df 2>/dev/null | sed 's/^/  /'
fi

# --- Top 5 ən böyük qovluq və fayl ---
top5_dirs() {
    local p="$1"
    du -xk --max-depth=1 "$p" 2>/dev/null | sort -rn | awk -F'\t' -v p="$p" '$2!=p' | head -n 5 | \
    while IFS=$'\t' read -r kb path; do
        printf "  %-10s %s\n" "$(human_size $((kb * 1024)))" "$path"
    done
}

top5_files() {
    local p="$1"
    find "$p" -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 5 | \
    while IFS=$'\t' read -r sz path; do
        printf "  %-10s %s\n" "$(human_size "$sz")" "$path"
    done
}

echo ""
echo -e "${CYAN}Top 5 axtarışı başlayır (böyük disklərdə bir neçə dəqiqə çəkə bilər)...${NC}"

for P in / /home /root; do
    [ -d "$P" ] || continue
    echo ""
    echo -e "${YELLOW}>>> $P daxilində ən böyük 5 qovluq:${NC}"
    OUT=$(top5_dirs "$P")
    [ -n "$OUT" ] && echo "$OUT" || echo "  (alt qovluq yoxdur və ya icazə yoxdur)"

    echo -e "${YELLOW}>>> $P daxilində ən böyük 5 fayl:${NC}"
    OUT=$(top5_files "$P")
    [ -n "$OUT" ] && echo "$OUT" || echo "  (fayl tapılmadı və ya icazə yoxdur)"
done

# ---------------------------------------------------
header "9. SİSTEM İSTİFADƏÇİLƏRİ"
echo -e "${GREEN}Login edə bilən (real) istifadəçilər:${NC}"
awk -F: '($3>=1000 && $1!="nobody") || $1=="root" {print "  - " $1 " (UID:" $3 ", Shell:" $7 ")"}' /etc/passwd

echo ""
echo -e "${GREEN}Hazırda sistemə daxil olanlar:${NC}"
who

echo ""
line
echo -e "${YELLOW}Hesabat tamamlandı.${NC}"
line
