#!/bin/bash
# macOS System Metrics Collector
# Collects ACTUAL macOS host metrics (not Docker/VM)

METRICS_FILE="./web/metrics.json"
INTERVAL=2

while true; do
    TS_MS=$(($(date +%s) * 1000))
    
    # ============ CPU ============
    CPU_PERCENT=$(top -l 1 -n 0 2>/dev/null | grep "CPU usage" | awk '{print $3}' | tr -d '%')
    CPU_PERCENT=${CPU_PERCENT:-0}
    
    # ============ LOAD AVERAGE ============
    LOAD_INFO=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
    LOAD_1M=$(echo $LOAD_INFO | awk '{print $1}')
    LOAD_5M=$(echo $LOAD_INFO | awk '{print $2}')
    LOAD_15M=$(echo $LOAD_INFO | awk '{print $3}')
    LOAD_1M=${LOAD_1M:-0}
    LOAD_5M=${LOAD_5M:-0}
    LOAD_15M=${LOAD_15M:-0}
    
    # ============ MEMORY ============
    # macOS memory via vm_stat
    PAGE_SIZE=$(sysctl -n hw.pagesize)
    VM_STAT=$(vm_stat)
    
    PAGES_FREE=$(echo "$VM_STAT" | awk '/Pages free/ {print $3}' | tr -d '.')
    PAGES_ACTIVE=$(echo "$VM_STAT" | awk '/Pages active/ {print $3}' | tr -d '.')
    PAGES_INACTIVE=$(echo "$VM_STAT" | awk '/Pages inactive/ {print $3}' | tr -d '.')
    PAGES_WIRED=$(echo "$VM_STAT" | awk '/Pages wired/ {print $4}' | tr -d '.')
    PAGES_COMPRESSED=$(echo "$VM_STAT" | awk '/Pages occupied by compressor/ {print $5}' | tr -d '.')
    
    MEM_TOTAL=$(sysctl -n hw.memsize)
    MEM_FREE=$((${PAGES_FREE:-0} * PAGE_SIZE))
    MEM_USED=$(( (${PAGES_ACTIVE:-0} + ${PAGES_WIRED:-0} + ${PAGES_COMPRESSED:-0}) * PAGE_SIZE ))
    MEM_AVAILABLE=$(( (${PAGES_FREE:-0} + ${PAGES_INACTIVE:-0}) * PAGE_SIZE ))
    
    if [ "$MEM_TOTAL" -gt 0 ]; then
        MEM_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL) * 100}")
    else
        MEM_PERCENT="0.0"
    fi
    
    # Swap
    SWAP_INFO=$(sysctl -n vm.swapusage 2>/dev/null)
    SWAP_TOTAL=$(echo "$SWAP_INFO" | awk '{print $2}' | tr -d 'M')
    SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $6}' | tr -d 'M')
    SWAP_TOTAL=$((${SWAP_TOTAL:-0} * 1024 * 1024))
    SWAP_USED=$((${SWAP_USED:-0} * 1024 * 1024))
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($SWAP_USED / $SWAP_TOTAL) * 100}")
    else
        SWAP_PERCENT="0.0"
    fi
    
    # ============ UPTIME ============
    BOOT_TIME=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')
    NOW=$(date +%s)
    UPTIME_SECONDS=$((NOW - BOOT_TIME))
    UPTIME_DAYS=$((UPTIME_SECONDS / 86400))
    UPTIME_HOURS=$(( (UPTIME_SECONDS % 86400) / 3600 ))
    UPTIME_MINS=$(( (UPTIME_SECONDS % 3600) / 60 ))
    UPTIME_STR="${UPTIME_DAYS}d ${UPTIME_HOURS}h ${UPTIME_MINS}m"
    
    # ============ DISK ============
    DISK_JSON=$(df -b 2>/dev/null | grep -E '^/dev/' | head -5 | awk '{
        if($2 > 0) pct=int(($3/$2)*100); else pct=0;
        printf "{\"mount\":\"%s\",\"used\":%s,\"total\":%s,\"available\":%s,\"percent\":%d},", $9, $3, $2, $4, pct
    }' | sed 's/,$//' || echo "")
    DISK_JSON="[${DISK_JSON}]"
    
    # Disk I/O
    IOSTAT=$(iostat -d -c 1 2>/dev/null | tail -1)
    DISK_READS=$(echo "$IOSTAT" | awk '{print $2}')
    DISK_WRITES=$(echo "$IOSTAT" | awk '{print $3}')
    DISK_IO="{\"reads\":${DISK_READS:-0},\"writes\":${DISK_WRITES:-0},\"read_bytes\":0,\"write_bytes\":0}"
    
    # ============ NETWORK ============
    NET_STAT=$(netstat -ib 2>/dev/null | grep -v "^lo" | grep -v "^Name" | head -5)
    RX_BYTES=$(echo "$NET_STAT" | awk '{sum+=$7} END {print sum+0}')
    TX_BYTES=$(echo "$NET_STAT" | awk '{sum+=$10} END {print sum+0}')
    RX_PACKETS=$(echo "$NET_STAT" | awk '{sum+=$5} END {print sum+0}')
    TX_PACKETS=$(echo "$NET_STAT" | awk '{sum+=$8} END {print sum+0}')
    RX_ERRORS=$(echo "$NET_STAT" | awk '{sum+=$6} END {print sum+0}')
    TX_ERRORS=$(echo "$NET_STAT" | awk '{sum+=$9} END {print sum+0}')
    
    NET_TRAFFIC="{\"rx_bytes\":${RX_BYTES:-0},\"tx_bytes\":${TX_BYTES:-0},\"rx_packets\":${RX_PACKETS:-0},\"tx_packets\":${TX_PACKETS:-0},\"rx_errors\":${RX_ERRORS:-0},\"tx_errors\":${TX_ERRORS:-0},\"rx_drops\":0,\"tx_drops\":0}"
    
    # Network Interfaces
    NET_IFACES=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -v "^lo" | head -5 | while read iface; do
        status="down"
        ifconfig "$iface" 2>/dev/null | grep -q "status: active" && status="up"
        printf "{\"name\":\"%s\",\"status\":\"%s\"}," "$iface" "$status"
    done | sed 's/,$//')
    NET_IFACES="[${NET_IFACES:-}]"
    
    # TCP States
    TCP_ESTAB=$(netstat -an 2>/dev/null | grep -c ESTABLISHED || echo 0)
    TCP_LISTEN=$(netstat -an 2>/dev/null | grep -c LISTEN || echo 0)
    TCP_TIMEWAIT=$(netstat -an 2>/dev/null | grep -c TIME_WAIT || echo 0)
    TCP_TOTAL=$(netstat -an 2>/dev/null | grep -c tcp || echo 0)
    TCP_STATES="{\"established\":${TCP_ESTAB},\"listen\":${TCP_LISTEN},\"time_wait\":${TCP_TIMEWAIT},\"close_wait\":0,\"total\":${TCP_TOTAL}}"
    
    # ============ PROCESSES ============
    PROC_TOTAL=$(ps aux 2>/dev/null | wc -l | tr -d ' ')
    PROC_RUNNING=$(ps aux 2>/dev/null | awk '$8 ~ /R/ {count++} END {print count+0}')
    PROC_ZOMBIE=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count+0}')
    
    # Top 5 CPU processes
    TOP_CPU=$(ps aux -r 2>/dev/null | head -6 | tail -5 | awk '{
        cmd=substr($11,1,25)
        gsub(/[^a-zA-Z0-9_\/\.-]/, "", cmd)
        printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"cmd\":\"%s\"},", $2, $1, $3, $4, cmd
    }' | sed 's/,$//' || echo "")
    TOP_CPU="[${TOP_CPU}]"
    
    # Top 5 Memory processes
    TOP_MEM=$(ps aux -m 2>/dev/null | head -6 | tail -5 | awk '{
        cmd=substr($11,1,25)
        gsub(/[^a-zA-Z0-9_\/\.-]/, "", cmd)
        printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"cmd\":\"%s\"},", $2, $1, $3, $4, cmd
    }' | sed 's/,$//' || echo "")
    TOP_MEM="[${TOP_MEM}]"
    
    # ============ SERVICES (launchd) ============
    SERVICES_JSON=$(launchctl list 2>/dev/null | grep -v "^-" | head -8 | awk 'NR>1 {
        status="running"
        if($1 == "-") status="stopped"
        printf "{\"name\":\"%s\",\"status\":\"%s\"},", $3, status
    }' | sed 's/,$//' || echo "")
    SERVICES_JSON="[${SERVICES_JSON:-}]"
    
    # ============ SECURITY ============
    LOGGED_USERS=$(who 2>/dev/null | wc -l | tr -d ' ')
    LOGGED_USERS_LIST=$(who 2>/dev/null | awk '{printf "{\"user\":\"%s\",\"tty\":\"%s\"},", $1, $2}' | sed 's/,$//' || echo "")
    LOGGED_USERS_LIST="[${LOGGED_USERS_LIST:-}]"
    
    # ============ SYSTEM INFO ============
    # CPU Temperature (macOS - requires osx-cpu-temp or similar)
    if command -v osx-cpu-temp &> /dev/null; then
        CPU_TEMP=$(osx-cpu-temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    else
        CPU_TEMP="null"
    fi
    
    CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/"/\\"/g' || echo "Apple Silicon")
    OS_NAME=$(sw_vers -productName 2>/dev/null) 
    OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
    OS_FULL="${OS_NAME} ${OS_VERSION}"
    KERNEL_VERSION=$(uname -r 2>/dev/null || echo "unknown")
    HOSTNAME=$(hostname 2>/dev/null || echo "localhost")
    
    # ============ WRITE JSON ============
    TMP_FILE="${METRICS_FILE}.tmp"
    cat > "$TMP_FILE" << EOJSON
{
  "ok": true,
  "ts_ms": $TS_MS,
  "core": {
    "cpu_percent": $CPU_PERCENT,
    "load_1m": $LOAD_1M,
    "load_5m": $LOAD_5M,
    "load_15m": $LOAD_15M,
    "memory": {
      "total": $MEM_TOTAL,
      "used": $MEM_USED,
      "free": $MEM_FREE,
      "available": $MEM_AVAILABLE,
      "percent": $MEM_PERCENT
    },
    "swap": {
      "total": $SWAP_TOTAL,
      "used": $SWAP_USED,
      "percent": $SWAP_PERCENT
    },
    "uptime": "$UPTIME_STR",
    "uptime_seconds": $UPTIME_SECONDS
  },
  "disk": {
    "partitions": $DISK_JSON,
    "inodes": [],
    "io": $DISK_IO,
    "iowait_percent": 0
  },
  "network": {
    "traffic": $NET_TRAFFIC,
    "interfaces": $NET_IFACES,
    "tcp_states": $TCP_STATES
  },
  "processes": {
    "total": $PROC_TOTAL,
    "running": $PROC_RUNNING,
    "zombie": $PROC_ZOMBIE,
    "top_cpu": $TOP_CPU,
    "top_mem": $TOP_MEM
  },
  "services": {
    "list": $SERVICES_JSON,
    "failed_count": 0
  },
  "logs": {
    "auth_failures": 0,
    "kernel_errors": 0
  },
  "security": {
    "logged_users": $LOGGED_USERS,
    "users_list": $LOGGED_USERS_LIST
  },
  "system": {
    "hostname": "$HOSTNAME",
    "os": "$OS_FULL",
    "kernel": "$KERNEL_VERSION",
    "cpu_model": "$CPU_MODEL",
    "cpu_cores": $CPU_CORES,
    "cpu_temp": $CPU_TEMP
  }
}
EOJSON
    
    mv "$TMP_FILE" "$METRICS_FILE" 2>/dev/null
    sleep $INTERVAL
done
