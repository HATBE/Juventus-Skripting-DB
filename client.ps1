<#
.SYNOPSIS
    Monitoring client script to collect system specifications and metrics.

.DESCRIPTION
    This script gathers system metrics including CPU usage, RAM usage, disk usage, system uptime, and IP address.
    It then sends the collected data to a specified SQL Server database.

.PARAMETER dbServer
    SQL Server instance (z. b. ".\SQLEXPRESS" or "localhost")

.PARAMETER dbUser
    SQL login username

.PARAMETER dbPass
    SQL login password

.PARAMETER dbName
    Name of the target database (default: MonitoringDB)

.PARAMETER silent
    If set, suppresses console log output

.EXAMPLE
    .\client.ps1 -dbServer "192.168.1.10\SQLEXPRESS" -dbUser "admin" -dbPass "password" -silent

.NOTES
    Run this script with administrative privileges for full functionality.
#>

param (
    [string]$dbServer = "DESKTOP-6PPL6UD\SQLEXPRESS",
    [string]$computerName = $env:COMPUTERNAME,
    [string]$dbUser,
    [string]$dbPass,
    [string]$dbName = "MonitoringDB",
    [switch]$silent
)

Import-Module SqlServer -ErrorAction SilentlyContinue

function swissDate {
    return (Get-Date -Format "dd.MM.yyyy HH:mm:ss")
}

function Log {
    param([string]$msg)
    if (-not $silent) {
        Write-Host "$(swissDate) $msg"
    }
}

function CheckParams {
    if (-not $dbUser -or -not $dbPass  -or -not $dbUser) {
        Log "ERROR: Required parameters -dbUser and -dbPass  and -dbUser are missing."
        exit 1
    }
}

function CheckAdmin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {        
        Log "ERROR: Script must be executed as administrator."
        exit 1
    }
}

function InitDBConnection {
    $Global:connectionString = "Server=$dbServer;Database=$dbName;User Id=$dbUser;Password=$dbPass;Encrypt=False;TrustServerCertificate=True"
    Log "Connection to DB set in connectionstring."
}

function execSQLQuery {
    param(
        [string]$query
    )
    
    try {
        return Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
    } catch {
        Log "ERROR: SQL query failed: $_"
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
        OS = $os.Caption
        CPU = $cpu
        RAMUsed = $ramUsed
        RAMTotal = $ramTotal
        DiskUsed = $diskUsed
        DiskTotal = $diskTotal
        IP = $ip
        Uptime = $uptime
    }
}
function Write-ToDatabase($data) {
    $registerComputerSql = @"
EXEC InsertComputer
    @hostname = '$computerName',
    @ipAddress = '$($data.IP)',
    @operatingSystem = '$($data.OS)';
"@

    # first get id of this computer, by hostname, then insert the data with the id (ik, unsecure, but who cares)
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

    Log "Writing data to database..."
    execSQLQuery -query $registerComputerSql
    execSQLQuery -query $insertSql
    Log "Data written successfully."
}

#----------------
# Main script 
#----------------

CheckAdmin
CheckParams
InitDBConnection

try {
    $data = Get-SystemData
    
    Write-ToDatabase -data $data
} catch {
    Log "ERROR: Unexpected error: $_"
    exit 1
}
