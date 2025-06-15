<#
.SYNOPSIS
    System Monitoring Client Script

.DESCRIPTION
    Collects system metrics and inserts them into a central SQL Server database.

.PARAMETER dbServer
    The hostname or IP of the SQL Server.

.PARAMETER computerName
    Override the detected computer name (optional).

.PARAMETER silent
    Runs script without console output.

.EXAMPLE
    .\client.ps1 -dbServer "127.0.0.1\SQLEXPRESS" -silent
#>

param (
    [string]$dbServer = "127.0.0.1\SQLEXPRESS",
    [string]$computerName = $env:COMPUTERNAME,
    [switch]$silent
)

function Log {
    param ([string]$msg)
    if (-not $silent) { Write-Host "$(Get-Date -Format "u") $msg" }
}

# Load SQL Server module
Import-Module SqlServer -ErrorAction SilentlyContinue

# Collect system data
try {
    Log "Collecting system metrics..."

    # CPU
    $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" |
        Select-Object -ExpandProperty PercentProcessorTime

    # OS Info
    $osInfo = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
    $osName = $osInfo.Caption
    $ramUsed = [math]::Round(($osInfo.TotalVisibleMemorySize - $osInfo.FreePhysicalMemory) / 1024)
    $ramTotal = [math]::Round($osInfo.TotalVisibleMemorySize / 1024)

    # Disk
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -First 1
    $diskUsedGB = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
    $diskTotalGB = [math]::Round($disk.Size / 1GB, 2)

    # Network
    $netStats = Get-NetAdapterStatistics
    $rx = [math]::Round(($netStats | Measure-Object -Sum ReceivedBytes).Sum / 1MB, 2)
    $tx = [math]::Round(($netStats | Measure-Object -Sum SentBytes).Sum / 1MB, 2)

    # IP
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress)

    # Uptime
    $lastBoot = $osInfo.LastBootUpTime
    $uptimeMinutes = [math]::Round((New-TimeSpan -Start $lastBoot).TotalMinutes)

} catch {
    Log "Error collecting system data: $_"
    exit 1
}

# Connect and insert
try {
    Log "Connecting to database..."

    $connectionString = "Server=localhost\SQLEXPRESS;Database=MonitoringDB;User Id=clientUser;Password=Client123!;Encrypt=False;TrustServerCertificate=True"

    # Ensure computer is registered & update last contact
    $registerSql = @"
IF EXISTS (SELECT 1 FROM Computer WHERE hostname = '$computerName')
BEGIN
    UPDATE Computer SET lastContact = GETDATE() WHERE hostname = '$computerName'
END
ELSE
BEGIN
    INSERT INTO Computer (hostname, ipAddress, operatingSystem, lastContact)
    VALUES ('$computerName', '$ip', '$osName', GETDATE())
END
"@
    Invoke-Sqlcmd -ConnectionString $connectionString -Query $registerSql

    # Insert measurement
    $query = @"
DECLARE @compId INT = (SELECT computerId FROM Computer WHERE hostname = '$computerName');
EXEC InsertMeasurement 
    @computerId = @compId,
    @cpuUsage = $cpu,
    @ramUsed = $ramUsed,
    @ramTotal = $ramTotal,
    @diskUsed = $diskUsedGB,
    @diskTotal = $diskTotalGB,
    @netRx = $rx,
    @netTx = $tx,
    @uptime = $uptimeMinutes;
"@

    Invoke-Sqlcmd -ConnectionString $connectionString -Query $query
    Log "Inserted data for $computerName"

} catch {
    Log "Error: SQL insert failed: $_"
    exit 2
}
