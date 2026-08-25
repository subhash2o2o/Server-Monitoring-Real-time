#!/bin/bash
# Comprehensive System Metrics Collector
# Collects all metrics using shell commands and writes to JSON

METRICS_FILE="./web/metrics.json"
INTERVAL=2

safe_int() { echo "${1:-0}" | grep -oE '^[0-9]+' || echo 0; }
safe_float() { echo "${1:-0}" | grep -oE '^[0-9]+\.?[0-9]*' || echo 0; }

while true; do
    TS_MS=$(date +%s)000
    
    # ============ CPU USAGE ============
    CPU_PERCENT=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | tr -d '%us,' || echo "0")
    CPU_PERCENT=$(safe_float "$CPU_PERCENT")
    
    # IO Wait
    IOWAIT_PERCENT=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{for(i=1;i<=NF;i++) if($i ~ /wa/) print $(i-1)}' | tr -d '%,' || echo "0")
    IOWAIT_PERCENT=$(safe_float "$IOWAIT_PERCENT")
    
    # ============ LOAD AVERAGE ============
    if [ -f /proc/loadavg ]; then
        read -r LOAD_1M LOAD_5M LOAD_15M _ < /proc/loadavg
    else
        LOAD_1M="0.00"; LOAD_5M="0.00"; LOAD_15M="0.00"
    fi
    
    # ============ MEMORY ============
    if [ -f /proc/meminfo ]; then
        MEM_TOTAL=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)
        MEM_FREE=$(awk '/MemFree/ {print $2 * 1024}' /proc/meminfo)
        MEM_AVAILABLE=$(awk '/MemAvailable/ {print $2 * 1024}' /proc/meminfo)
        MEM_BUFFERS=$(awk '/^Buffers/ {print $2 * 1024}' /proc/meminfo)
        MEM_CACHED=$(awk '/^Cached:/ {print $2 * 1024}' /proc/meminfo)
        MEM_USED=$((${MEM_TOTAL:-0} - ${MEM_FREE:-0} - ${MEM_BUFFERS:-0} - ${MEM_CACHED:-0}))
        if [ "${MEM_TOTAL:-0}" -gt 0 ]; then
            MEM_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL) * 100}")
        else
            MEM_PERCENT="0.0"
        fi
        
        SWAP_TOTAL=$(awk '/SwapTotal/ {print $2 * 1024}' /proc/meminfo)
        SWAP_FREE=$(awk '/SwapFree/ {print $2 * 1024}' /proc/meminfo)
        SWAP_USED=$((${SWAP_TOTAL:-0} - ${SWAP_FREE:-0}))
        if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
            SWAP_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($SWAP_USED / $SWAP_TOTAL) * 100}")
        else
            SWAP_PERCENT="0.0"
        fi
    else
        MEM_TOTAL=0; MEM_USED=0; MEM_FREE=0; MEM_AVAILABLE=0; MEM_PERCENT="0.0"
        SWAP_TOTAL=0; SWAP_USED=0; SWAP_PERCENT="0.0"
    fi
    
    MEM_TOTAL=$(safe_int "$MEM_TOTAL")
    MEM_USED=$(safe_int "$MEM_USED")
    MEM_FREE=$(safe_int "$MEM_FREE")
    MEM_AVAILABLE=$(safe_int "$MEM_AVAILABLE")
    SWAP_TOTAL=$(safe_int "$SWAP_TOTAL")
    SWAP_USED=$(safe_int "$SWAP_USED")
    
    # ============ UPTIME ============
    if [ -f /proc/uptime ]; then
        UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)
        UPTIME_DAYS=$((UPTIME_SECONDS / 86400))
        UPTIME_HOURS=$(( (UPTIME_SECONDS % 86400) / 3600 ))
        UPTIME_MINS=$(( (UPTIME_SECONDS % 3600) / 60 ))
        UPTIME_STR="${UPTIME_DAYS}d ${UPTIME_HOURS}h ${UPTIME_MINS}m"
    else
        UPTIME_SECONDS=0
        UPTIME_STR="0d 0h 0m"
    fi
    
    # ============ DISK USAGE ============
    DISK_JSON=$(df -B1 2>/dev/null | grep -E '^/dev/' | head -5 | awk '{
        if($2 > 0) pct=int(($3/$2)*100); else pct=0;
        printf "{\"mount\":\"%s\",\"used\":%s,\"total\":%s,\"available\":%s,\"percent\":%d},", $6, $3, $2, $4, pct
    }' | sed 's/,$//' || echo "")
    DISK_JSON="[${DISK_JSON}]"
    
    # Inode Usage
    INODE_JSON=$(df -i 2>/dev/null | grep -E '^/dev/' | head -3 | awk '{
        if($2 > 0) pct=int(($3/$2)*100); else pct=0;
        printf "{\"mount\":\"%s\",\"used\":%s,\"total\":%s,\"percent\":%d},", $6, $3, $2, pct
    }' | sed 's/,$//' || echo "")
    INODE_JSON="[${INODE_JSON}]"
    
    # Disk I/O
    if [ -f /proc/diskstats ]; then
        DISK_IO=$(awk '$3 ~ /^(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z])$/ {
            reads+=$6; writes+=$10
        } END {
            printf "{\"reads\":%d,\"writes\":%d,\"read_bytes\":%d,\"write_bytes\":%d}", reads+0, writes+0, reads*512, writes*512
        }' /proc/diskstats)
    else
        DISK_IO='{"reads":0,"writes":0,"read_bytes":0,"write_bytes":0}'
    fi
    
    # ============ NETWORK ============
    if [ -f /proc/net/dev ]; then
        NET_STATS=$(awk '!/lo:|Inter|face/ {
            gsub(":", "", $1)
            rx+=$2; rx_packets+=$3; rx_errors+=$4; rx_drops+=$5
            tx+=$10; tx_packets+=$11; tx_errors+=$12; tx_drops+=$13
        } END {
            printf "{\"rx_bytes\":%d,\"tx_bytes\":%d,\"rx_packets\":%d,\"tx_packets\":%d,\"rx_errors\":%d,\"tx_errors\":%d,\"rx_drops\":%d,\"tx_drops\":%d}", rx+0, tx+0, rx_packets+0, tx_packets+0, rx_errors+0, tx_errors+0, rx_drops+0, tx_drops+0
        }' /proc/net/dev)
    else
        NET_STATS='{"rx_bytes":0,"tx_bytes":0,"rx_packets":0,"tx_packets":0,"rx_errors":0,"tx_errors":0,"rx_drops":0,"tx_drops":0}'
    fi
    
    # Network Interfaces
    NET_IFACES=$(ip -o link show 2>/dev/null | grep -v 'lo:' | head -5 | awk '{
        gsub(":", "", $2)
        status="down"
        if($0 ~ /state UP/) status="up"
        printf "{\"name\":\"%s\",\"status\":\"%s\"},", $2, status
    }' | sed 's/,$//' || echo "")
    NET_IFACES="[${NET_IFACES}]"
    
    # TCP States
    if command -v ss &> /dev/null; then
        TCP_STATES=$(ss -tan 2>/dev/null | tail -n +2 | awk '{
            states[$1]++
        } END {
            printf "{\"established\":%d,\"listen\":%d,\"time_wait\":%d,\"close_wait\":%d,\"total\":%d}", states["ESTAB"]+0, states["LISTEN"]+0, states["TIME-WAIT"]+0, states["CLOSE-WAIT"]+0, NR
        }')
    else
        TCP_STATES='{"established":0,"listen":0,"time_wait":0,"close_wait":0,"total":0}'
    fi
    
    # ============ PROCESSES ============
    PROC_TOTAL=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
    PROC_RUNNING=$(ps aux 2>/dev/null | awk '$8 ~ /R/ {count++} END {print count+0}')
    PROC_ZOMBIE=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count+0}')
    
    # Top 5 CPU processes
    TOP_CPU=$(ps aux --no-headers 2>/dev/null | sort -k3 -rn | head -5 | awk '{
        gsub(/"/, "", $11)
        cmd=substr($11,1,25)
        gsub(/[^a-zA-Z0-9_\/\.-]/, "", cmd)
        printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"cmd\":\"%s\"},", $2, $1, $3, $4, cmd
    }' | sed 's/,$//' || echo "")
    TOP_CPU="[${TOP_CPU}]"
    
    # Top 5 Memory processes
    TOP_MEM=$(ps aux --no-headers 2>/dev/null | sort -k4 -rn | head -5 | awk '{
        gsub(/"/, "", $11)
        cmd=substr($11,1,25)
        gsub(/[^a-zA-Z0-9_\/\.-]/, "", cmd)
        printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"cmd\":\"%s\"},", $2, $1, $3, $4, cmd
    }' | sed 's/,$//' || echo "")
    TOP_MEM="[${TOP_MEM}]"
    
    # ============ SERVICES ============
    if command -v systemctl &> /dev/null; then
        SERVICES_JSON=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | head -8 | awk '{
            gsub(".service", "", $1)
            printf "{\"name\":\"%s\",\"status\":\"running\"},", $1
        }' | sed 's/,$//' || echo "")
        FAILED_SERVICES=$(systemctl list-units --type=service --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
    else
        SERVICES_JSON=""
        FAILED_SERVICES=0
    fi
    SERVICES_JSON="[${SERVICES_JSON}]"
    
    # ============ LOGS ============
    AUTH_FAILURES=0
    if [ -f /var/log/auth.log ]; then
        AUTH_FAILURES=$(grep -c "Failed password\|authentication failure" /var/log/auth.log 2>/dev/null || echo 0)
    elif [ -f /var/log/secure ]; then
        AUTH_FAILURES=$(grep -c "Failed password\|authentication failure" /var/log/secure 2>/dev/null || echo 0)
    fi
    
    KERNEL_ERRORS=$(dmesg 2>/dev/null | tail -100 | grep -ci "error\|fail\|critical" || echo 0)
    
    # ============ SECURITY ============
    LOGGED_USERS=$(who 2>/dev/null | wc -l)
    LOGGED_USERS_LIST=$(who 2>/dev/null | awk '{printf "{\"user\":\"%s\",\"tty\":\"%s\"},", $1, $2}' | sed 's/,$//' || echo "")
    LOGGED_USERS_LIST="[${LOGGED_USERS_LIST}]"
    
    # ============ SYSTEM INFO ============
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        CPU_TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    else
        CPU_TEMP="null"
    fi
    
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs | sed 's/"/\\"/g' || echo "Unknown")
    
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Linux")
    else
        OS_NAME=$(uname -o 2>/dev/null || echo "Linux")
    fi
    
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
    "inodes": $INODE_JSON,
    "io": $DISK_IO,
    "iowait_percent": $IOWAIT_PERCENT
  },
  "network": {
    "traffic": $NET_STATS,
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
    "failed_count": $FAILED_SERVICES
  },
  "logs": {
    "auth_failures": $AUTH_FAILURES,
    "kernel_errors": $KERNEL_ERRORS
  },
  "security": {
    "logged_users": $LOGGED_USERS,
    "users_list": $LOGGED_USERS_LIST
  },
  "system": {
    "hostname": "$HOSTNAME",
    "os": "$OS_NAME",
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
