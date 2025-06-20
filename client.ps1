<#
.SYNOPSIS
    Monitoring CLient script to get a systems specs, and data

.DESCRIPTION
   The script collects metrics (CPU, RAM, disk, uptime, IP) and sends them to a central SQL Server database.

.PARAMETER dbServer
    SQL Server instance name/IP (default: DESKTOP-6PPL6UD\SQLEXPRESS)

.PARAMETER dbUser
    The username of the db server user

.PARAMETER dbPass
    The password of the db server user

.PARAMETER dbName
    The name of the db

.PARAMETER computerName
    Optional: Overwrites the host name determined

.PARAMETER silent
    Switches off console output

.EXAMPLE
    .\client.ps1 -dbServer "192.168.1.10\SQLEXPRESS" -silent
#>

param (
    [string]$dbServer = "DESKTOP-6PPL6UD\SQLEXPRESS",
    [string]$computerName = $env:COMPUTERNAME,
    [string]$dbUser,
    [string]$dbPass,
    [string]$dbName = "MonitoringDB",
    [switch]$silent
)

function Log {
    param([string]$msg)
    if (-not $silent) {
        Write-Host "$(Get-Date -Format "u") $msg"
    }
}

function CheckParams {
    if (-not $dbUser -or -not $dbPass) {
        Log "ERROR: Required parameters -dbUser and -dbPass are missing."
        exit 99
    }
}

function CheckAdmin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {        
        Log "WARNING: Script must be executed as admin"
        exit 1
    }
}

function Get-SystemData {
    Log "Start collecting..."

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" |
        Select-Object -ExpandProperty PercentProcessorTime
    $ramUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
    $ramTotal = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -First 1
    $diskUsed = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
    $diskTotal = [math]::Round($disk.Size / 1GB, 2)
    $uptime = [math]::Round((New-TimeSpan -Start $os.LastBootUpTime).TotalMinutes)
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress)

    return @{
        OS         = $os.Caption
        CPU        = $cpu
        RAMUsed    = $ramUsed
        RAMTotal   = $ramTotal
        DiskUsed   = $diskUsed
        DiskTotal  = $diskTotal
        IP         = $ip
        Uptime     = $uptime
    }
}

function Write-ToDatabase($data) {
    Log "Start db connection..."

    $connectionString = "Server=$dbServer;Database=$dbName;User Id=$dbUser;Password=$dbPass;Encrypt=False;TrustServerCertificate=True"

    $registerSql = @"
IF EXISTS (SELECT 1 FROM Computer WHERE hostname = '$computerName')
    UPDATE Computer SET lastContact = GETDATE() WHERE hostname = '$computerName'
ELSE
    INSERT INTO Computer (hostname, ipAddress, operatingSystem, lastContact)
    VALUES ('$computerName', '$($data.IP)', '$($data.OS)', GETDATE())
"@

    $insertSql = @"
DECLARE @compId INT = (SELECT computerId FROM Computer WHERE hostname = '$computerName');
EXEC InsertMeasurement 
    @computerId = @compId,
    @cpuUsage = $($data.CPU),
    @ramUsed = $($data.RAMUsed),
    @ramTotal = $($data.RAMTotal),
    @diskUsed = $($data.DiskUsed),
    @diskTotal = $($data.DiskTotal),
    @uptime = $($data.Uptime);
"@

    try {
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $registerSql
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $insertSql
        Log "Successfully sent data."
    } catch {
        Log "ERROR SQL: $_"
        exit 2
    }
}

# ====== Script ======
Import-Module SqlServer -ErrorAction SilentlyContinue

CheckAdmin
CheckParams

try {
    $data = Get-SystemData
    Write-ToDatabase -data $data
} catch {
    Log "ERROR: while collectiong data: $_"
    exit 1
}
