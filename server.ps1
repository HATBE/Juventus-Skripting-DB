<#
.SYNOPSIS
    Export monitoring data from SQL Server to data.js

.DESCRIPTION
    Connects to a SQL Server MonitoringDB and fetches:
    - Computers
    - Warnings
    - Summary (counts, averages)
    Then writes it all to a JavaScript file in a `const data = { ... }` format.

.PARAMETER dbServer
    SQL Server instance (e.g., .\SQLEXPRESS or localhost)

.PARAMETER dbUser
    SQL Server login username

.PARAMETER dbPass
    SQL Server login password

.PARAMETER dbName
    Name of the database (default: MonitoringDB)

.PARAMETER silent
    Suppresses log output if specified

.EXAMPLE
    .\Export-ToDataJs.ps1 -dbUser serverUser -dbPass Server123!
#>

param (
    [string]$dbServer = "DESKTOP-6PPL6UD\SQLEXPRESS",
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
        Log "ERROR: Required parameters -dbUser and -dbPass and -dbUser are missing."
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

function Getcpu7daysDays {
    $query = "SELECT * FROM vw_AvgCpuUsageLast7Days"
    return execSQLQuery -query $query
}
function Getram7daysDays {
    $query = "SELECT * FROM vw_AvgRamUsageLast7Days"
    return execSQLQuery -query $query
}

function Getram7daysDays {
    $query = "SELECT * FROM vw_AvgRamUsageLast7Days"
    return execSQLQuery -query $query
}

function GetWarningStats {
    $query = "SELECT * FROM vw_WarningTypeStatsLast7Days"
    return execSQLQuery -query $query
}

function GetOperatingSystemStats {
    $query = "SELECT * FROM vw_OperatingSystemStats"
    return execSQLQuery -query $query
}

function GetSummary {
    $query = "SELECT * FROM vw_DashboardSummary"
    return execSQLQuery -query $query
}

function GetWarnings {
    $query = "SELECT * FROM vw_LatestWarnings"
    return execSQLQuery -query $query
}

function GetMeasurements {
    $query = "SELECT * FROM vw_Latest10Measurements"
    return execSQLQuery -query $query
}

function WriteToJs {
    param(
        $warnings,
        $measurements,
        $summary,
        $cpu7days,
        $ram7days,
        $warnings7,
        $warningStats,
        $osStats
    )

    $data = @{
        lastUpdated = (swissDate)
        summary = @{
            computerCount = $summary.computerCount
            warningsToday = $summary.warningsToday
            avgCpuToday = $summary.avgCpuToday
            avgRamUsageToday = $summary.avgRamUsageToday
            avgWarningsLast7Days = $summary.avgWarningsLast7Days
        }
        osStats = $osStats | ForEach-Object {
            @{
                osName = $_.operatingSystem
                percentage = $_.percentage -as [double]
            }
        }
        warnings = $warnings | ForEach-Object {
            @{
                warningId = $_.warningId
                measurementId = $_.measurementId
                type = $_.type
                description = $_.description
                severityLevel = $_.severityLevel
                timestamp = $_.timestamp.ToString("yyyy-MM-dd HH:mm:ss") # american format, because JS uses this in this usecase
                hostname = $_.hostname
            }
        }
        measurements = $measurements | ForEach-Object {
            @{
                hostname = $_.hostname
                cpuUsagePercent = $_.cpuUsagePercent
                ramUsagePercent = $_.ramUsagePercent
                diskUsagePercent = $_.diskUsagePercent
                uptimeHours = [math]::Round($_.uptimeMinutes / 60, 1)
                timestamp = $_.timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        cpu7Days = $cpu7days | ForEach-Object {
            @{ 
                day = $_.day.ToString("yyyy-MM-dd"); 
                avgCpuUsage = $_.avgCpuUsage
            }
        }
        ram7Days = $ram7days | ForEach-Object {
            @{ 
                day = $_.day.ToString("yyyy-MM-dd"); ; 
                avgRamUsagePercent = $_.avgRamUsagePercent
            }
        }
       warningStats = $warningStats | ForEach-Object {
            $count = $_.count -as [int]
            if (-not $count) { $count = 0 }

            $percentage = $_.percentage -as [double]
            if (-not $percentage) { $percentage = 0 }   

            @{
                type = $_.warningType
                count = $count
                percentage = $percentage
            }
        }
    }

    try {
        $json = $data | ConvertTo-Json
        $output = "const data = $json;"
        Set-Content -Path "./data.js" -Value $output -Encoding UTF8
        Log "data.js file successfully created."
    } catch {
        Log "ERROR: Failed to write to data.js: $_"
        exit 1
    }
}

# Main script 
CheckAdmin
CheckParams
InitDBConnection

try {
    $warnings = GetWarnings
    if (-not $warnings) { $warnings = @() }

    $cpu7days = Getcpu7daysDays
    if (-not $cpu7days) { $cpu7days = @() }

    $ram7days = Getram7daysDays
    if (-not $ram7days) { $ram7days = @() }

    $measurements = GetMeasurements
    if (-not $measurements) { $measurements = @() }

    $summary = GetSummary
    if (-not $summary) { $summary = @()}

    $warningStats = GetWarningStats
    if (-not $warningStats) { $warningStats = @() }

    $osStats = GetOperatingSystemStats
    if (-not $osStats) { $osStats = @() }

    WriteToJs -warnings $warnings -measurements $measurements -summary $summary -cpu7days $cpu7days -ram7days $ram7days -warnings7 $warnings -warningStats $warningStats -osStats $osStats
} catch {
    Log "ERROR: Unexpected error: $_"
    exit 1
}