# Real-Time System Monitor & Server-Sent Events Log Streaming

> Comprehensive monitoring solution with real-time system metrics and live log streaming via Server-Sent Events

## Features

### 📊 System Monitoring Dashboard
- **Real-time metrics** - CPU, Memory, Disk, Network updated every 2 seconds
- **Interactive charts** - Powered by Chart.js with 60-second history
- **Multi-platform** - Windows, Linux, macOS, and Docker containers
- **Process monitoring** - Top CPU/Memory consuming processes
- **System information** - Hostname, OS, kernel, uptime, temperature

### 📜 Live Log Streaming
- **Server-Sent Events** - Real-time log delivery without polling
- **Zero-latency** - Filesystem change notifications via `watchfiles`
- **Multi-client** - Each browser gets independent stream
- **Heartbeat monitoring** - Connection health checks every 10s

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    MONITORING SYSTEM                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Metrics Collectors          Log Producer                       │
│  ┌───────────────┐          ┌─────────────┐                     │
│  │ • PS1 (Win)   │          │ deploy.sh   │                     │
│  │ • Bash (Linux)│──►       │      ▼      │                     │
│  │ • Bash (macOS)│  writes  │ deploy.log  │                     │
│  │ • Container   │  every   └──────┬──────┘                     │
│  └───────┬───────┘   2s            │ read-only                  │
│          │                         │                            │
│          ▼                         ▼                            │
│   metrics.json         ┌────────────────────┐                   │
│          │             │  FastAPI Backend   │                   │
│          │             │  (SSE streaming)   │                   │
│          └──────┬──────┴──────────┬─────────┘                   │
│                 │                 │                             │
│                 ▼                 ▼                             │
│          ┌────────────────────────────┐                         │
│          │    Nginx (Port 8080)       │                         │
│          │  • Reverse proxy           │                         │
│          │  • Static file server      │                         │
│          └──────┬──────────────┬──────┘                         │
│                 │              │                                │
│                 ▼              ▼                                │
│         monitor.html     index.html                             │
│         (Metrics UI)     (Log Stream)                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1) Start Docker Services

```bash
docker compose up --build -d
```

This starts:
- **Nginx** on port 8080 (web server + reverse proxy)
- **FastAPI Backend** on port 8000 (SSE log streaming)

### 2) Start Metrics Collector

Choose the appropriate script for your platform:

**Windows (PowerShell):**
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\collect_metrics.ps1
```

**Linux / WSL:**
```bash
chmod +x scripts/collect_metrics.sh
./scripts/collect_metrics.sh
```

**macOS:**
```bash
chmod +x scripts/collect_metrics_macos.sh
./scripts/collect_metrics_macos.sh
```

**Docker Container:**
```bash
chmod +x scripts/collect_metrics_container.sh
./scripts/collect_metrics_container.sh
```

### 3) Start Log Producer (Optional)

For live log streaming demo:

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

### 4) Access Dashboards

- **System Monitor**: http://localhost:8080/monitor.html
- **Log Streaming**: http://localhost:8080/index.html

## Project Structure

```
project linux/
├── docker-compose.yml          # Docker services config
├── README.md                   # This file
├── backend/                    # FastAPI SSE service
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
│       └── main.py            # SSE streaming endpoint
├── nginx/
│   └── nginx.conf             # Reverse proxy config
├── web/                       # Frontend files
│   ├── index.html             # Log streaming UI
│   ├── monitor.html           # System monitoring dashboard
│   └── metrics.json           # Live metrics data
├── scripts/                   # Collectors & producers
│   ├── collect_metrics.ps1    # Windows collector
│   ├── collect_metrics.sh     # Linux collector
│   ├── collect_metrics_macos.sh  # macOS collector
│   ├── collect_metrics_container.sh  # Container collector
│   └── deploy.sh              # Log producer
└── logs/
    └── deploy.log             # Log file for streaming
```

## Platform Support

| Metric | Windows | macOS | Linux | Container |
|--------|---------|-------|-------|-----------|
| CPU % | Win32_Processor | `top` | `/proc/stat` | `/proc/stat` |
| Memory | Win32_OS | `vm_stat` | `/proc/meminfo` | `/proc/meminfo` |
| Disk | Win32_LogicalDisk | `df` | `df` | `df` |
| Network | Get-NetAdapter | `netstat` | `/proc/net/dev` | `/proc/net/dev` |
| Processes | Get-Process | `ps` | `ps` | `ps` |
| Load Avg | Queue Length | `sysctl` | `/proc/loadavg` | `/proc/loadavg` |

## Configuration

### Metrics Update Interval

Edit the collector scripts:

**PowerShell** (collect_metrics.ps1):
```powershell
$Interval = 2  # seconds
```

**Bash** (collect_metrics.sh):
```bash
INTERVAL=2  # seconds
```

### Chart History

Edit web/monitor.html:
```javascript
while (labels.length > 30) {  // Keep 30 data points (60 seconds)
```

## SSE Event Format

**Log lines:**
```
event: log
data: <log line>

```

**Heartbeat (every 10s):**
```
event: heartbeat
data: ping

```

## Troubleshooting

### Dashboard shows blank page
1. Check containers: `docker compose ps`
2. Verify metrics.json exists: `ls web/metrics.json` or `dir web\metrics.json`
3. Restart services: `docker compose restart`
4. Check logs: `docker compose logs nginx`

### Metrics show 0 or N/A
- **Windows**: Run PowerShell as Administrator
- **Linux/macOS**: Ensure execute permission: `chmod +x scripts/*.sh`
- Verify collector is running
- Check metrics.json timestamp is recent

### No logs appear
- Confirm deploy.sh is running
- Verify `./logs/deploy.log` exists and updates
- Check backend logs: `docker compose logs backend`

### Connection refused on localhost:8080
```bash
docker compose up -d
docker compose logs nginx
```

### Permission errors

**Windows:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**Linux/macOS:**
```bash
chmod +x scripts/*.sh
```

## Production Best Practices

### Security
- ✅ **Read-only volume mount** - Logs mounted as `:ro`
- ✅ **No shell execution** - Python backend only reads files
- ✅ **Static serving** - No server-side code execution
- ⚠️ **Add authentication** - Use Nginx basic auth for production
- ⚠️ **Enable HTTPS** - SSL certificates for public access

### Performance
- **Multi-client safe** - Each browser gets independent stream
- **Low latency** - Filesystem change notifications via `watchfiles`
- **Nginx tuned** - `proxy_buffering off`, long timeouts
- **Efficient polling** - 2-second metrics update interval

### Limitations
- Log rotation: Backend resets offset if file truncated
- Multi-line logs: Split into separate events
- High throughput: Consider Redis/Kafka for scaling

## Advanced Usage

### Running as Background Service

**Windows (Task Scheduler):**
```powershell
schtasks /create /tn "SystemMonitor" /tr "powershell -File C:\path\to\collect_metrics.ps1" /sc onstart
```

**Linux (systemd):**
```bash
sudo systemctl enable system-monitor
sudo systemctl start system-monitor
```

### Custom Metrics

Add to collector scripts:
```bash
"custom_metric": $(your_command)
```

### Remote Monitoring

```bash
ssh user@host 'bash -s' < scripts/collect_metrics.sh > web/metrics.json
```

## Optional Extensions

- **FIFO mode** - True blocking streaming for single-consumer
- **Redis Pub/Sub** - Fan-out at scale for multiple consumers
- **systemd units** - Manage collectors as system services
- **Kubernetes** - Sidecar pattern with shared volumes
- **Alerting** - Threshold-based notifications
- **Historical data** - Time-series database (InfluxDB/Prometheus)

## License

MIT License - Free to use, modify, and distribute.

---

**Made with ❤️ for real-time system monitoring**
