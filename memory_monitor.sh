#!/bin/bash

#===============================================================================
# Memory Monitoring Script for Bimser Synergy (Ubuntu 24.04)
# Amaç: Memory leak, cache buildup, session birikimi tespiti
#===============================================================================

LOG_DIR="/var/log/memory_monitor"
LOG_FILE="$LOG_DIR/memory_$(date +%Y%m%d).log"
ALERT_THRESHOLD=80  # Memory kullanımı % uyarı eşiği
TOP_PROCESSES=10    # En çok memory kullanan process sayısı

# Renk kodları
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Log dizini oluştur
#-------------------------------------------------------------------------------
setup() {
    if [[ ! -d "$LOG_DIR" ]]; then
        sudo mkdir -p "$LOG_DIR"
        sudo chown $USER:$USER "$LOG_DIR"
    fi
}

#-------------------------------------------------------------------------------
# Başlık yazdır
#-------------------------------------------------------------------------------
print_header() {
    echo "==============================================================================="
    echo " MEMORY MONITORING REPORT - $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Hostname: $(hostname) | Uptime: $(uptime -p)"
    echo "==============================================================================="
}

#-------------------------------------------------------------------------------
# 1. Genel Memory Durumu
#-------------------------------------------------------------------------------
check_memory_overview() {
    echo -e "\n${GREEN}[1] GENEL MEMORY DURUMU${NC}"
    echo "-------------------------------------------------------------------------------"
    free -h
    echo ""
    
    # Yüzdelik kullanım
    local total=$(free | awk '/^Mem:/{print $2}')
    local used=$(free | awk '/^Mem:/{print $3}')
    local percent=$((used * 100 / total))
    
    if [[ $percent -ge $ALERT_THRESHOLD ]]; then
        echo -e "${RED}⚠ UYARI: Memory kullanımı %${percent} (Eşik: %${ALERT_THRESHOLD})${NC}"
    else
        echo -e "${GREEN}✓ Memory kullanımı: %${percent}${NC}"
    fi
}

#-------------------------------------------------------------------------------
# 2. Memory Leak Tespiti - Process Bazlı Artış
#-------------------------------------------------------------------------------
check_memory_leak() {
    echo -e "\n${GREEN}[2] MEMORY LEAK ANALİZİ - EN ÇOK MEMORY KULLANAN PROCESSLER${NC}"
    echo "-------------------------------------------------------------------------------"
    printf "%-10s %-8s %-12s %-10s %s\n" "PID" "%MEM" "RSS (MB)" "RUNTIME" "COMMAND"
    echo "-------------------------------------------------------------------------------"
    
    ps aux --sort=-%mem | awk 'NR>1 && NR<=11 {
        # Runtime hesapla
        cmd = "ps -o etime= -p " $2 " 2>/dev/null"
        cmd | getline runtime
        close(cmd)
        if (runtime == "") runtime = "N/A"
        
        # RSS'i MB'a çevir
        rss_mb = $6 / 1024
        
        # Command'ı kısalt
        command = $11
        if (length(command) > 40) command = substr(command, 1, 40) "..."
        
        printf "%-10s %-8s %-12.1f %-10s %s\n", $2, $4"%", rss_mb, runtime, command
    }'
    
    echo ""
    echo "Not: Uzun süre çalışan ve memory'si sürekli artan processler leak göstergesi olabilir."
}

#-------------------------------------------------------------------------------
# 3. Process Memory Geçmişi (Karşılaştırma için)
#-------------------------------------------------------------------------------
track_process_memory() {
    local tracking_file="$LOG_DIR/process_tracking.csv"
    
    echo -e "\n${GREEN}[3] PROCESS MEMORY TAKİBİ${NC}"
    echo "-------------------------------------------------------------------------------"
    
    # Header yoksa oluştur
    if [[ ! -f "$tracking_file" ]]; then
        echo "timestamp,pid,process,rss_kb,vsz_kb" > "$tracking_file"
    fi
    
    # Mevcut durumu kaydet
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    ps aux --sort=-%mem | awk -v ts="$timestamp" 'NR>1 && NR<=6 {
        gsub(/,/, ";", $11)  # CSV için virgülleri temizle
        print ts "," $2 "," $11 "," $6 "," $5
    }' >> "$tracking_file"
    
    echo "Top 5 process memory durumu kaydedildi: $tracking_file"
    
    # Son 24 saatteki değişimi göster (eğer yeterli veri varsa)
    local line_count=$(wc -l < "$tracking_file")
    if [[ $line_count -gt 10 ]]; then
        echo ""
        echo "Son kayıtlar (memory artışı kontrolü için):"
        tail -20 "$tracking_file" | column -t -s','
    fi
}

#-------------------------------------------------------------------------------
# 4. Cache ve Buffer Durumu
#-------------------------------------------------------------------------------
check_cache_status() {
    echo -e "\n${GREEN}[4] CACHE VE BUFFER DURUMU${NC}"
    echo "-------------------------------------------------------------------------------"
    
    # /proc/meminfo'dan detaylı bilgi
    echo "Detaylı Memory Bilgisi:"
    awk '
    /^MemTotal:|^MemFree:|^MemAvailable:|^Buffers:|^Cached:|^SwapCached:|^Active:|^Inactive:|^Dirty:|^Slab:/ {
        # Değeri GB'a çevir
        val_gb = $2 / 1024 / 1024
        printf "  %-20s %10.2f GB\n", $1, val_gb
    }
    ' /proc/meminfo
    
    echo ""
    
    # Slab detayı (kernel cache)
    echo "En büyük Slab cache'leri (Kernel memory):"
    if [[ -r /proc/slabinfo ]]; then
        sudo cat /proc/slabinfo 2>/dev/null | awk 'NR>2 {print $1, $3*$4/1024/1024 " MB"}' | sort -k2 -rn | head -5
    else
        echo "  (slabinfo okunamadı - root yetkisi gerekebilir)"
    fi
}

#-------------------------------------------------------------------------------
# 5. Open File Descriptors (Memory Leak Göstergesi)
#-------------------------------------------------------------------------------
check_file_descriptors() {
    echo -e "\n${GREEN}[5] OPEN FILE DESCRIPTOR ANALİZİ${NC}"
    echo "-------------------------------------------------------------------------------"
    
    # Sistem limitleri
    local max_fd=$(cat /proc/sys/fs/file-max)
    local current_fd=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
    local percent=$((current_fd * 100 / max_fd))
    
    echo "Sistem geneli:"
    echo "  Açık FD sayısı: $current_fd / $max_fd (%$percent)"
    
    echo ""
    echo "En çok FD kullanan processler:"
    printf "%-10s %-8s %-40s\n" "PID" "FD Count" "COMMAND"
    echo "-------------------------------------------------------------------------------"
    
    for pid in $(ps aux --sort=-%mem | awk 'NR>1 && NR<=11 {print $2}'); do
        if [[ -d /proc/$pid/fd ]]; then
            fd_count=$(ls -1 /proc/$pid/fd 2>/dev/null | wc -l)
            cmd=$(ps -p $pid -o comm= 2>/dev/null | head -c 40)
            if [[ -n "$cmd" ]]; then
                printf "%-10s %-8s %-40s\n" "$pid" "$fd_count" "$cmd"
            fi
        fi
    done
    
    echo ""
    echo "Not: FD sayısı sürekli artan processler leak göstergesi olabilir."
}

#-------------------------------------------------------------------------------
# 6. Network Bağlantıları ve Session Durumu
#-------------------------------------------------------------------------------
check_sessions() {
    echo -e "\n${GREEN}[6] NETWORK BAĞLANTILARI VE SESSION DURUMU${NC}"
    echo "-------------------------------------------------------------------------------"
    
    echo "TCP bağlantı durumları:"
    ss -tan | awk 'NR>1 {state[$1]++} END {for (s in state) printf "  %-15s %d\n", s, state[s]}' | sort -k2 -rn
    
    echo ""
    echo "Dinleyen portlar (Synergy servisleri):"
    ss -tlnp 2>/dev/null | grep -E ':(80|443|8080|8443|1433|5432)' | awk '{print "  " $4, $6}' | head -10
    
    echo ""
    echo "TIME_WAIT bağlantı sayısı (yüksekse sorun olabilir):"
    local timewait=$(ss -tan | grep -c TIME-WAIT)
    if [[ $timewait -gt 1000 ]]; then
        echo -e "  ${YELLOW}⚠ TIME_WAIT: $timewait (yüksek)${NC}"
    else
        echo -e "  ${GREEN}✓ TIME_WAIT: $timewait${NC}"
    fi
    
    echo ""
    echo "ESTABLISHED bağlantı sayısı:"
    local established=$(ss -tan | grep -c ESTAB)
    echo "  ESTABLISHED: $established"
}

#-------------------------------------------------------------------------------
# 7. Swap Kullanımı (Memory Pressure Göstergesi)
#-------------------------------------------------------------------------------
check_swap() {
    echo -e "\n${GREEN}[7] SWAP KULLANIMI${NC}"
    echo "-------------------------------------------------------------------------------"
    
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    local swap_used=$(free | awk '/^Swap:/{print $3}')
    
    if [[ $swap_total -eq 0 ]]; then
        echo "  Swap tanımlı değil"
    else
        local percent=$((swap_used * 100 / swap_total))
        free -h | grep Swap
        
        if [[ $percent -gt 50 ]]; then
            echo -e "  ${RED}⚠ UYARI: Swap kullanımı yüksek (%$percent) - Memory yetersiz olabilir${NC}"
        else
            echo -e "  ${GREEN}✓ Swap kullanımı normal (%$percent)${NC}"
        fi
    fi
    
    # Hangi processler swap kullanıyor
    echo ""
    echo "En çok swap kullanan processler:"
    for pid in /proc/[0-9]*; do
        pid_num=$(basename $pid)
        if [[ -f "$pid/smaps" ]]; then
            swap=$(awk '/^Swap:/{sum+=$2} END {print sum}' "$pid/smaps" 2>/dev/null)
            if [[ -n "$swap" && "$swap" -gt 0 ]]; then
                cmd=$(cat "$pid/comm" 2>/dev/null)
                echo "$swap $pid_num $cmd"
            fi
        fi
    done 2>/dev/null | sort -rn | head -5 | awk '{printf "  %d KB - PID %s - %s\n", $1, $2, $3}'
}

#-------------------------------------------------------------------------------
# 8. Java/.NET Process Analizi (Synergy için)
#-------------------------------------------------------------------------------
check_app_specific() {
    echo -e "\n${GREEN}[8] UYGULAMA SPESİFİK ANALİZ${NC}"
    echo "-------------------------------------------------------------------------------"
    
    # Java processler (eğer varsa)
    if pgrep -x java > /dev/null; then
        echo "Java Processler:"
        ps aux | grep -E '[j]ava' | awk '{printf "  PID: %s | MEM: %s%% | RSS: %.1f MB | %s\n", $2, $4, $6/1024, $11}'
        
        # GC logları varsa kontrol et
        echo ""
    else
        echo "  Java process bulunamadı"
    fi
    
    echo ""
    
    # .NET Core processler (eğer varsa)
    if pgrep -f dotnet > /dev/null; then
        echo ".NET Core Processler:"
        ps aux | grep -E '[d]otnet' | awk '{printf "  PID: %s | MEM: %s%% | RSS: %.1f MB | %s\n", $2, $4, $6/1024, $11}'
    else
        echo "  .NET Core process bulunamadı"
    fi
    
    echo ""
    
    # Web server processler
    echo "Web Server Processler (nginx/apache):"
    ps aux | grep -E '[n]ginx|[a]pache|[h]ttpd' | awk '{printf "  PID: %s | MEM: %s%% | %s\n", $2, $4, $11}' | head -5
    if [[ $(ps aux | grep -cE '[n]ginx|[a]pache|[h]ttpd') -eq 0 ]]; then
        echo "  Web server process bulunamadı"
    fi
}

#-------------------------------------------------------------------------------
# 9. Memory Trend Analizi
#-------------------------------------------------------------------------------
analyze_trends() {
    local tracking_file="$LOG_DIR/process_tracking.csv"
    
    echo -e "\n${GREEN}[9] MEMORY TREND ANALİZİ${NC}"
    echo "-------------------------------------------------------------------------------"
    
    if [[ ! -f "$tracking_file" ]] || [[ $(wc -l < "$tracking_file") -lt 10 ]]; then
        echo "  Yeterli veri yok. Script'i birkaç kez çalıştırın veya cron'a ekleyin."
        echo "  Örnek cron (her 5 dakikada): */5 * * * * $0 --quiet"
        return
    fi
    
    echo "Process bazlı memory değişimi (son kayıtlar):"
    echo ""
    
    # Her process için ilk ve son değeri karşılaştır
    awk -F',' 'NR>1 {
        proc[$3]["first"] = (proc[$3]["first"] == "" ? $4 : proc[$3]["first"])
        proc[$3]["last"] = $4
        proc[$3]["count"]++
    }
    END {
        printf "%-30s %12s %12s %12s\n", "Process", "İlk (KB)", "Son (KB)", "Değişim"
        print "-------------------------------------------------------------------------------"
        for (p in proc) {
            if (proc[p]["count"] > 1) {
                diff = proc[p]["last"] - proc[p]["first"]
                pct = (proc[p]["first"] > 0) ? (diff * 100 / proc[p]["first"]) : 0
                if (diff > 10240) {  # 10MB'dan fazla artış varsa göster
                    printf "%-30s %12d %12d %+12d (%+.1f%%)\n", 
                        substr(p, 1, 30), proc[p]["first"], proc[p]["last"], diff, pct
                }
            }
        }
    }' "$tracking_file"
}

#-------------------------------------------------------------------------------
# 10. Özet ve Öneriler
#-------------------------------------------------------------------------------
print_summary() {
    echo -e "\n${GREEN}[10] ÖZET VE ÖNERİLER${NC}"
    echo "==============================================================================="
    
    local total=$(free | awk '/^Mem:/{print $2}')
    local used=$(free | awk '/^Mem:/{print $3}')
    local available=$(free | awk '/^Mem:/{print $7}')
    local percent=$((used * 100 / total))
    local available_gb=$(awk "BEGIN {printf \"%.1f\", $available/1024/1024}")
    
    echo "Memory Durumu: %$percent kullanımda, $available_gb GB kullanılabilir"
    echo ""
    
    # Otomatik öneriler
    echo "Kontrol Edilmesi Gerekenler:"
    
    # Swap kontrolü
    local swap_used=$(free | awk '/^Swap:/{print $3}')
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    if [[ $swap_total -gt 0 && $swap_used -gt $((swap_total / 2)) ]]; then
        echo "  ⚠ Swap kullanımı yüksek - Memory artırımı gerekebilir"
    fi
    
    # TIME_WAIT kontrolü
    local timewait=$(ss -tan 2>/dev/null | grep -c TIME-WAIT)
    if [[ $timewait -gt 1000 ]]; then
        echo "  ⚠ TIME_WAIT bağlantısı yüksek ($timewait) - Connection pooling kontrol edin"
    fi
    
    # Memory yüzdesi kontrolü
    if [[ $percent -gt 80 ]]; then
        echo "  ⚠ Memory kullanımı %80 üzerinde"
    fi
    
    # Genel durum
    if [[ $percent -lt 70 && $timewait -lt 1000 ]]; then
        echo -e "  ${GREEN}✓ Sistem genel olarak sağlıklı görünüyor${NC}"
    fi
    
    echo ""
    echo "Düzenli izleme için cron önerisi:"
    echo "  */5 * * * * $(readlink -f $0) --log-only >> /var/log/memory_monitor/cron.log 2>&1"
}

#-------------------------------------------------------------------------------
# Ana çalışma
#-------------------------------------------------------------------------------
main() {
    setup
    
    # --quiet veya --log-only parametresi varsa sadece log'a yaz
    if [[ "$1" == "--log-only" ]]; then
        {
            print_header
            check_memory_overview
            check_memory_leak
            track_process_memory
        } >> "$LOG_FILE"
        echo "Log kaydedildi: $LOG_FILE"
        exit 0
    fi
    
    # Normal çalışma - hem ekrana hem log'a
    print_header | tee -a "$LOG_FILE"
    check_memory_overview | tee -a "$LOG_FILE"
    check_memory_leak | tee -a "$LOG_FILE"
    track_process_memory | tee -a "$LOG_FILE"
    check_cache_status | tee -a "$LOG_FILE"
    check_file_descriptors | tee -a "$LOG_FILE"
    check_sessions | tee -a "$LOG_FILE"
    check_swap | tee -a "$LOG_FILE"
    check_app_specific | tee -a "$LOG_FILE"
    analyze_trends | tee -a "$LOG_FILE"
    print_summary | tee -a "$LOG_FILE"
    
    echo ""
    echo "Log dosyası: $LOG_FILE"
}

main "$@"
