# Windows System Metrics Collector
# Collects actual Windows system metrics and writes to JSON

$MetricsFile = ".\web\metrics.json"
$Interval = 2

function Get-SafeValue($value, $default = 0) {
    if ($null -eq $value -or $value -eq '') { return $default }
    return $value
}

while ($true) {
    try {
        $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        
        # ============ CPU ============
        $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
        $cpuPercent = [math]::Round((Get-SafeValue $cpu.Average 0), 1)
        
        # ============ MEMORY ============
        $os = Get-CimInstance Win32_OperatingSystem
        $memTotal = [long]$os.TotalVisibleMemorySize * 1024
        $memFree = [long]$os.FreePhysicalMemory * 1024
        $memUsed = $memTotal - $memFree
        $memPercent = [math]::Round(($memUsed / $memTotal) * 100, 1)
        $memAvailable = $memFree
        
        # Swap/PageFile
        $pageFile = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pageFile) {
            $swapTotal = [long]$pageFile.AllocatedBaseSize * 1MB
            $swapUsed = [long]$pageFile.CurrentUsage * 1MB
            $swapPercent = if ($swapTotal -gt 0) { [math]::Round(($swapUsed / $swapTotal) * 100, 1) } else { 0 }
        } else {
            $swapTotal = 0; $swapUsed = 0; $swapPercent = 0
        }
        
        # ============ LOAD AVERAGE (simulated for Windows) ============
        $cpuQueue = (Get-CimInstance Win32_PerfFormattedData_PerfOS_System).ProcessorQueueLength
        $loadAvg = [math]::Round($cpuQueue / (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors, 2)
        
        # ============ UPTIME ============
        $bootTime = $os.LastBootUpTime
        $uptime = (Get-Date) - $bootTime
        $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        $uptimeSeconds = [int]$uptime.TotalSeconds
        
        # ============ DISK USAGE ============
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $used = $_.Size - $_.FreeSpace
            $pct = if ($_.Size -gt 0) { [int](($used / $_.Size) * 100) } else { 0 }
            @{
                mount = $_.DeviceID
                used = [long]$used
                total = [long]$_.Size
                available = [long]$_.FreeSpace
                percent = $pct
            }
        }
        
        # Disk I/O
        $diskIO = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        if ($diskIO) {
            $diskReadBytes = [long]$diskIO.DiskReadBytesPerSec
            $diskWriteBytes = [long]$diskIO.DiskWriteBytesPerSec
            $diskReads = [long]$diskIO.DiskReadsPerSec
            $diskWrites = [long]$diskIO.DiskWritesPerSec
        } else {
            $diskReadBytes = 0; $diskWriteBytes = 0; $diskReads = 0; $diskWrites = 0
        }
        
        # IO Wait approximation
        $ioWait = if ($diskIO) { [math]::Round($diskIO.PercentDiskTime / 10, 1) } else { 0 }
        
        # ============ NETWORK ============
        $netAdapters = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue
        $rxBytes = 0; $txBytes = 0; $rxPackets = 0; $txPackets = 0; $rxErrors = 0; $txErrors = 0
        foreach ($adapter in $netAdapters) {
            $rxBytes += [long]$adapter.BytesReceivedPerSec
            $txBytes += [long]$adapter.BytesSentPerSec
            $rxPackets += [long]$adapter.PacketsReceivedPerSec
            $txPackets += [long]$adapter.PacketsSentPerSec
            $rxErrors += [long]$adapter.PacketsReceivedErrors
            $txErrors += [long]$adapter.PacketsOutboundErrors
        }
        
        # Network Interfaces
        $netIfaces = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' } | Select-Object -First 5 | ForEach-Object {
            @{
                name = $_.Name
                status = if ($_.Status -eq 'Up') { 'up' } else { 'down' }
            }
        }
        if (-not $netIfaces) { $netIfaces = @() }
        
        # TCP Connections
        $tcpConns = Get-NetTCPConnection -ErrorAction SilentlyContinue | Group-Object State
        $tcpEstab = ($tcpConns | Where-Object { $_.Name -eq 'Established' }).Count
        $tcpListen = ($tcpConns | Where-Object { $_.Name -eq 'Listen' }).Count
        $tcpTimeWait = ($tcpConns | Where-Object { $_.Name -eq 'TimeWait' }).Count
        $tcpCloseWait = ($tcpConns | Where-Object { $_.Name -eq 'CloseWait' }).Count
        $tcpTotal = ($tcpConns | Measure-Object -Property Count -Sum).Sum
        
        # ============ PROCESSES ============
        $processes = Get-Process -ErrorAction SilentlyContinue
        $procTotal = $processes.Count
        $procRunning = ($processes | Where-Object { $_.Responding }).Count
        $procZombie = ($processes | Where-Object { -not $_.Responding }).Count
        
        # Top 5 CPU processes
        $topCpu = Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
            $cpuPct = [math]::Round($_.CPU / ((Get-Date) - $_.StartTime).TotalSeconds * 100 / (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors, 1)
            if ($cpuPct -gt 100) { $cpuPct = 100 }
            @{
                pid = $_.Id
                user = $_.ProcessName
                cpu = $cpuPct
                mem = [math]::Round($_.WorkingSet64 / $memTotal * 100, 1)
                cmd = $_.ProcessName.Substring(0, [Math]::Min(25, $_.ProcessName.Length))
            }
        }
        if (-not $topCpu) { $topCpu = @() }
        
        # Top 5 Memory processes
        $topMem = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
            @{
                pid = $_.Id
                user = $_.ProcessName
                cpu = 0
                mem = [math]::Round($_.WorkingSet64 / $memTotal * 100, 1)
                cmd = $_.ProcessName.Substring(0, [Math]::Min(25, $_.ProcessName.Length))
            }
        }
        if (-not $topMem) { $topMem = @() }
        
        # ============ SERVICES ============
        $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 8 | ForEach-Object {
            @{ name = $_.Name; status = 'running' }
        }
        $failedServices = (Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Stopped' -and $_.StartType -eq 'Automatic' }).Count
        if (-not $services) { $services = @() }
        
        # ============ SECURITY ============
        $loggedUsers = (Get-CimInstance Win32_LoggedOnUser -ErrorAction SilentlyContinue | Select-Object -Unique Antecedent).Count
        $usersList = @()
        try {
            $quser = quser 2>$null
            if ($quser) {
                $usersList = $quser | Select-Object -Skip 1 | ForEach-Object {
                    $parts = $_ -split '\s+'
                    @{ user = $parts[0]; tty = $parts[1] }
                }
            }
        } catch { }
        if (-not $usersList) { $usersList = @() }
        
        # Auth failures (Windows Event Log)
        $authFailures = 0
        try {
            $authFailures = (Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 100 -ErrorAction SilentlyContinue).Count
        } catch { }
        
        # ============ SYSTEM INFO ============
        $compSys = Get-CimInstance Win32_ComputerSystem
        $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
        
        # CPU Temperature (if available)
        $cpuTemp = $null
        try {
            $thermal = Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace "root/wmi" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($thermal) {
                $cpuTemp = [math]::Round(($thermal.CurrentTemperature - 2732) / 10, 1)
            }
        } catch { }
        
        $hostname = $compSys.Name
        $osName = (Get-CimInstance Win32_OperatingSystem).Caption
        $kernelVersion = [System.Environment]::OSVersion.Version.ToString()
        $cpuModel = $cpuInfo.Name
        $cpuCores = $compSys.NumberOfLogicalProcessors
        
        # ============ BUILD JSON ============
        $metrics = @{
            ok = $true
            ts_ms = $ts
            core = @{
                cpu_percent = $cpuPercent
                load_1m = $loadAvg
                load_5m = $loadAvg
                load_15m = $loadAvg
                memory = @{
                    total = $memTotal
                    used = $memUsed
                    free = $memFree
                    available = $memAvailable
                    percent = $memPercent
                }
                swap = @{
                    total = $swapTotal
                    used = $swapUsed
                    percent = $swapPercent
                }
                uptime = $uptimeStr
                uptime_seconds = $uptimeSeconds
            }
            disk = @{
                partitions = @($disks)
                inodes = @()
                io = @{
                    reads = $diskReads
                    writes = $diskWrites
                    read_bytes = $diskReadBytes
                    write_bytes = $diskWriteBytes
                }
                iowait_percent = $ioWait
            }
            network = @{
                traffic = @{
                    rx_bytes = $rxBytes
                    tx_bytes = $txBytes
                    rx_packets = $rxPackets
                    tx_packets = $txPackets
                    rx_errors = $rxErrors
                    tx_errors = $txErrors
                    rx_drops = 0
                    tx_drops = 0
                }
                interfaces = @($netIfaces)
                tcp_states = @{
                    established = [int]$tcpEstab
                    listen = [int]$tcpListen
                    time_wait = [int]$tcpTimeWait
                    close_wait = [int]$tcpCloseWait
                    total = [int]$tcpTotal
                }
            }
            processes = @{
                total = $procTotal
                running = $procRunning
                zombie = $procZombie
                top_cpu = @($topCpu)
                top_mem = @($topMem)
            }
            services = @{
                list = @($services)
                failed_count = $failedServices
            }
            logs = @{
                auth_failures = [int]$authFailures
                kernel_errors = 0
            }
            security = @{
                logged_users = [int]$loggedUsers
                users_list = @($usersList)
            }
            system = @{
                hostname = $hostname
                os = $osName
                kernel = $kernelVersion
                cpu_model = $cpuModel
                cpu_cores = $cpuCores
                cpu_temp = $cpuTemp
            }
        }
        
        $json = $metrics | ConvertTo-Json -Depth 10 -Compress
        $json | Out-File -FilePath $MetricsFile -Encoding utf8 -Force
        
    } catch {
        Write-Host "Error: $_"
    }
    
    Start-Sleep -Seconds $Interval
}
