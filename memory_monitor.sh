#!/bin/bash

#===============================================================================
# Memory Monitoring Script for Linux (Ubuntu/Debian)
# Amac: Memory leak, cache buildup, session birikimi tespiti
#===============================================================================

LOG_DIR="/var/log/memory_monitor"
LOG_FILE="$LOG_DIR/memory_$(date +%Y%m%d).log"
ALERT_THRESHOLD=80
TOP_PROCESSES=10

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

setup() {
    if [[ ! -d "$LOG_DIR" ]]; then
        sudo mkdir -p "$LOG_DIR"
        sudo chown $USER:$USER "$LOG_DIR"
    fi
}

print_header() {
    echo "==============================================================================="
    echo " MEMORY MONITORING REPORT - $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Hostname: $(hostname) | Uptime: $(uptime -p)"
    echo "==============================================================================="
}

check_memory_overview() {
    echo -e "\n${GREEN}[1] GENEL MEMORY DURUMU${NC}"
    echo "-------------------------------------------------------------------------------"
    free -h
    echo ""
    
    local total=$(free | awk '/^Mem:/{print $2}')
    local used=$(free | awk '/^Mem:/{print $3}')
    local percent=$((used * 100 / total))
    
    if [[ $percent -ge $ALERT_THRESHOLD ]]; then
        echo -e "${RED}UYARI: Memory kullanimi %${percent} (Esik: %${ALERT_THRESHOLD})${NC}"
    else
        echo -e "${GREEN}Memory kullanimi: %${percent}${NC}"
    fi
}

check_memory_leak() {
    echo -e "\n${GREEN}[2] MEMORY LEAK ANALIZI - EN COK MEMORY KULLANAN PROCESSLER${NC}"
    echo "-------------------------------------------------------------------------------"
    printf "%-10s %-8s %-12s %-10s %s\n" "PID" "%MEM" "RSS (MB)" "RUNTIME" "COMMAND"
    echo "-------------------------------------------------------------------------------"
    
    ps aux --sort=-%mem | head -11 | tail -10 | while read user pid cpu mem vsz rss tty stat start time command; do
        runtime=$(ps -o etime= -p "$pid" 2>/dev/null || echo "N/A")
        rss_mb=$(echo "scale=1; $rss / 1024" | bc)
        cmd_short=$(echo "$command" | cut -c1-40)
        printf "%-10s %-8s %-12s %-10s %s\n" "$pid" "${mem}%" "$rss_mb" "$runtime" "$cmd_short"
    done
    
    echo ""
    echo "Not: Uzun sure calisan ve memorysi surekli artan processler leak gostergesi olabilir."
}

track_process_memory() {
    local tracking_file="$LOG_DIR/process_tracking.csv"
    
    echo -e "\n${GREEN}[3] PROCESS MEMORY TAKIBI${NC}"
    echo "-------------------------------------------------------------------------------"
    
    if [[ ! -f "$tracking_file" ]]; then
        echo "timestamp,pid,process,rss_kb,vsz_kb" > "$tracking_file"
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    ps aux --sort=-%mem | head -6 | tail -5 | while read user pid cpu mem vsz rss tty stat start time command; do
        proc=$(echo "$command" | cut -d' ' -f1 | tr ',' ';')
        echo "$timestamp,$pid,$proc,$rss,$vsz" >> "$tracking_file"
    done
    
    echo "Top 5 process memory durumu kaydedildi: $tracking_file"
    
    local line_count=$(wc -l < "$tracking_file")
    if [[ $line_count -gt 10 ]]; then
        echo ""
        echo "Son kayitlar (memory artisi kontrolu icin):"
        tail -20 "$tracking_file" | column -t -s','
    fi
}

check_cache_status() {
    echo -e "\n${GREEN}[4] CACHE VE BUFFER DURUMU${NC}"
    echo "-------------------------------------------------------------------------------"
    
    echo "Detayli Memory Bilgisi:"
    awk '/^MemTotal:|^MemFree:|^MemAvailable:|^Buffers:|^Cached:|^SwapCached:|^Active:|^Inactive:|^Dirty:|^Slab:/ {
        val_gb = $2 / 1024 / 1024
        printf "  %-20s %10.2f GB\n", $1, val_gb
    }' /proc/meminfo
    
    echo ""
    echo "En buyuk Slab cacheleri (Kernel memory):"
    if [[ -r /proc/slabinfo ]]; then
        sudo cat /proc/slabinfo 2>/dev/null | awk 'NR>2 {print $1, $3*$4/1024/1024 " MB"}' | sort -k2 -rn | head -5
    else
        echo "  (slabinfo okunamadi - root yetkisi gerekebilir)"
    fi
}

check_file_descriptors() {
    echo -e "\n${GREEN}[5] OPEN FILE DESCRIPTOR ANALIZI${NC}"
    echo "-------------------------------------------------------------------------------"
    
    local max_fd=$(cat /proc/sys/fs/file-max)
    local current_fd=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
    local percent=$((current_fd * 100 / max_fd))
    
    echo "Sistem geneli:"
    echo "  Acik FD sayisi: $current_fd / $max_fd (%$percent)"
    
    echo ""
    echo "En cok FD kullanan processler:"
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
    echo "Not: FD sayisi surekli artan processler leak gostergesi olabilir."
}

check_sessions() {
    echo -e "\n${GREEN}[6] NETWORK BAGLANTILARI VE SESSION DURUMU${NC}"
    echo "-------------------------------------------------------------------------------"
    
    echo "TCP baglanti durumlari:"
    ss -tan | awk 'NR>1 {state[$1]++} END {for (s in state) printf "  %-15s %d\n", s, state[s]}' | sort -k2 -rn
    
    echo ""
    echo "Dinleyen portlar:"
    ss -tlnp 2>/dev/null | awk 'NR>1 {print "  " $4}' | head -10
    
    echo ""
    local timewait=$(ss -tan | grep -c TIME-WAIT)
    if [[ $timewait -gt 1000 ]]; then
        echo -e "${YELLOW}UYARI: TIME_WAIT: $timewait (yuksek)${NC}"
    else
        echo -e "${GREEN}TIME_WAIT: $timewait${NC}"
    fi
    
    echo ""
    local established=$(ss -tan | grep -c ESTAB)
    echo "ESTABLISHED baglanti sayisi: $established"
}

check_swap() {
    echo -e "\n${GREEN}[7] SWAP KULLANIMI${NC}"
    echo "-------------------------------------------------------------------------------"
    
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    local swap_used=$(free | awk '/^Swap:/{print $3}')
    
    if [[ $swap_total -eq 0 ]]; then
        echo "  Swap tanimli degil"
    else
        local percent=$((swap_used * 100 / swap_total))
        free -h | grep Swap
        
        if [[ $percent -gt 50 ]]; then
            echo -e "${RED}UYARI: Swap kullanimi yuksek (%$percent)${NC}"
        else
            echo -e "${GREEN}Swap kullanimi normal (%$percent)${NC}"
        fi
    fi
    
    echo ""
    echo "En cok swap kullanan processler:"
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

check_app_specific() {
    echo -e "\n${GREEN}[8] UYGULAMA SPESIFIK ANALIZ${NC}"
    echo "-------------------------------------------------------------------------------"
    
    if pgrep -x java > /dev/null; then
        echo "Java Processler:"
        ps aux | grep '[j]ava' | awk '{printf "  PID: %s | MEM: %s%% | RSS: %.1f MB\n", $2, $4, $6/1024}'
    else
        echo "  Java process bulunamadi"
    fi
    
    echo ""
    
    if pgrep -f dotnet > /dev/null; then
        echo ".NET Core Processler:"
        ps aux | grep '[d]otnet' | awk '{printf "  PID: %s | MEM: %s%% | RSS: %.1f MB\n", $2, $4, $6/1024}'
    else
        echo "  .NET Core process bulunamadi"
    fi
    
    echo ""
    
    echo "Web Server Processler (nginx/apache):"
    ps aux | grep -E '[n]ginx|[a]pache|[h]ttpd' | awk '{printf "  PID: %s | MEM: %s%%\n", $2, $4}' | head -5
    if [[ $(ps aux | grep -cE '[n]ginx|[a]pache|[h]ttpd') -eq 0 ]]; then
        echo "  Web server process bulunamadi"
    fi
}

analyze_trends() {
    local tracking_file="$LOG_DIR/process_tracking.csv"
    
    echo -e "\n${GREEN}[9] MEMORY TREND ANALIZI${NC}"
    echo "-------------------------------------------------------------------------------"
    
    if [[ ! -f "$tracking_file" ]] || [[ $(wc -l < "$tracking_file") -lt 10 ]]; then
        echo "  Yeterli veri yok. Scripti birkac kez calistirin veya crona ekleyin."
        echo "  Ornek cron (her 5 dakikada): */5 * * * * $0 --quiet"
        return
    fi
    
    echo "Process bazli memory degisimi (son kayitlar):"
    echo ""
    
    awk -F',' 'NR>1 {
        proc[$3]["first"] = (proc[$3]["first"] == "" ? $4 : proc[$3]["first"])
        proc[$3]["last"] = $4
        proc[$3]["count"]++
    }
    END {
        printf "%-30s %12s %12s %12s\n", "Process", "Ilk (KB)", "Son (KB)", "Degisim"
        print "-------------------------------------------------------------------------------"
        for (p in proc) {
            if (proc[p]["count"] > 1) {
                diff = proc[p]["last"] - proc[p]["first"]
                pct = (proc[p]["first"] > 0) ? (diff * 100 / proc[p]["first"]) : 0
                if (diff > 10240) {
                    printf "%-30s %12d %12d %+12d (%+.1f%%)\n", 
                        substr(p, 1, 30), proc[p]["first"], proc[p]["last"], diff, pct
                }
            }
        }
    }' "$tracking_file"
}

print_summary() {
    echo -e "\n${GREEN}[10] OZET VE ONERILER${NC}"
    echo "==============================================================================="
    
    local total=$(free | awk '/^Mem:/{print $2}')
    local used=$(free | awk '/^Mem:/{print $3}')
    local available=$(free | awk '/^Mem:/{print $7}')
    local percent=$((used * 100 / total))
    local available_gb=$(awk "BEGIN {printf \"%.1f\", $available/1024/1024}")
    
    echo "Memory Durumu: %$percent kulanimda, $available_gb GB kullanilabilir"
    echo ""
    
    echo "Kontrol Edilmesi Gerekenler:"
    
    local swap_used=$(free | awk '/^Swap:/{print $3}')
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    if [[ $swap_total -gt 0 && $swap_used -gt $((swap_total / 2)) ]]; then
        echo "  - Swap kullanimi yuksek - Memory artirimi gerekebilir"
    fi
    
    local timewait=$(ss -tan 2>/dev/null | grep -c TIME-WAIT)
    if [[ $timewait -gt 1000 ]]; then
        echo "  - TIME_WAIT baglantisi yuksek ($timewait) - Connection pooling kontrol edin"
    fi
    
    if [[ $percent -gt 80 ]]; then
        echo "  - Memory kullanimi %80 uzerinde"
    fi
    
    if [[ $percent -lt 70 && $timewait -lt 1000 ]]; then
        echo -e "  ${GREEN}Sistem genel olarak saglikli gorunuyor${NC}"
    fi
    
    echo ""
    echo "Duzenli izleme icin cron onerisi:"
    echo "  */5 * * * * $(readlink -f $0) --log-only >> /var/log/memory_monitor/cron.log 2>&1"
}

main() {
    setup
    
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
    echo "Log dosyasi: $LOG_FILE"
}

main "$@"
