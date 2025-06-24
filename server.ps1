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
        Log "WARNING: Script must be executed as administrator."
        exit 1
    }
}

function InitConnection {
    $Global:connectionString = "Server=$dbServer;Database=$dbName;User Id=$dbUser;Password=$dbPass;Encrypt=False;TrustServerCertificate=True"
    Log "Connection string initialized."
}

function GetCpu7Days {
    $query = "SELECT * FROM vw_AvgCpuUsageLast7Days"
    try {
        return Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
    } catch {
        Log "ERROR: Failed to fetch 7-day CPU averages: $_"
        exit 7
    }
}

function GetRam7Days {
    $query = "SELECT * FROM vw_AvgRamUsageLast7Days"
    try {
        return Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
    } catch {
        Log "ERROR: Failed to fetch 7-day RAM averages: $_"
        exit 8
    }
}

function GetWarningStats {
    $query = "SELECT * FROM vw_WarningTypeStatsLast7Days"
    try {
        return Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
    } catch {
        Log "ERROR: Failed to fetch warning stats: $_"
        exit 10
    }
}

function GetSummary {
    $query = "SELECT TOP 1 * FROM vw_DashboardSummary"

    try {
        $summary = Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query

        return $summary
    } catch {
        Log "ERROR: Failed to fetch summary from view: $_"
        exit 6
    }
}

function GetWarnings {
    $query = "SELECT * FROM vw_LatestWarnings"

    try {
        $warnings = Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
        return $warnings
    } catch {
        Log "ERROR: Failed to fetch latest warnings: $_"
        exit 4
    }
}

function GetMeasurements {
    $query = "SELECT * FROM vw_Latest10Measurements"
    try {
        return Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
    } catch {
        Log "ERROR: Failed to fetch measurements: $_"
        exit 5
    }
}

function WriteToJs {
    param(
        $warnings,
        $measurements,
        $summary,
        $cpu7,
        $ram7,
        $warnings7,
        $warningStats
    )

    if (-not $warnings) { $warnings = @() }

    # Pre-parse summary values
    $computerCount = $summary.computerCount -as [int]; if (-not $computerCount) { $computerCount = 0 }
    $cpuAvg = $summary.avgCpuToday -as [double]; if (-not $cpuAvg) { $cpuAvg = 0 }
    $ramAvg = $summary.avgRamUsageToday -as [double]; if (-not $ramAvg) { $ramAvg = 0 }
    $avgWarnings = $summary.avgWarningsLast7Days -as [double]; if (-not $avgWarnings) { $avgWarnings = 0 }
    $warningsToday = $summary.warningsToday -as [int]; if (-not $warningsToday) { $warningsToday = 0 }

    $output = "const data = {`n  lastUpdated: '" + (Get-Date -Format "d.M.yyyy HH:mm:ss") + "',`n"

    # Summary section
    $output += @"
  summary: {
    computerCount: $computerCount,
    warningsToday: $warningsToday,
    avgCpuToday: $cpuAvg,
    avgRamUsageToday: $ramAvg,
    avgWarningsLast7Days: $avgWarnings
  },
"@


     # Warnings
    $output += "  warnings: [`n"
    foreach ($warn in $warnings) {
        $output += @"
    {
      warningId: $($warn.warningId),
      measurementId: $($warn.measurementId),
      type: '$($warn.type)',
      description: '$($warn.description)',
      severityLevel: '$($warn.severityLevel)',
      timestamp: '$($warn.timestamp.ToString("yyyy-MM-dd HH:mm:ss"))',
      hostname: '$($warn.hostname)'
    },
"@
    }
    $output = $output.TrimEnd(",`n") + "`n  ],`n"

      # Measurements
    $output += "  measurements: [`n"
    foreach ($m in $measurements) {
        $uptime = [math]::Round(($m.uptimeMinutes / 60), 1)
        $output += @"
    {
      hostname: '$($m.hostname)',
      cpuUsagePercent: $($m.cpuUsagePercent),
      ramUsagePercent: $($m.ramUsagePercent),
      diskUsagePercent: $($m.diskUsagePercent),
      uptimeHours: $uptime,
      timestamp: '$($m.timestamp.ToString("yyyy-MM-dd HH:mm:ss"))'
    },
"@
    }
    $output = $output.TrimEnd(",`n") + "`n  ],`n" 

     # CPU 7-day stats
    $output += "  cpu7Days: [`n"
    foreach ($entry in $cpu7) {
        $output += "    { day: '$($entry.day)', avgCpuUsage: $($entry.avgCpuUsage) },`n"
    }
    $output = $output.TrimEnd(",`n") + "`n  ],`n"

    # RAM 7-day stats
    $output += "  ram7Days: [`n"
    foreach ($entry in $ram7) {
        $output += "    { day: '$($entry.day)', avgRamUsagePercent: $($entry.avgRamUsagePercent) },`n"
    }
    $output = $output.TrimEnd(",`n") + "`n  ],`n"

    # Warning Stats by Type
    $output += "  warningStats: [`n"
    foreach ($entry in $warningStats) {
        $count = $entry.count -as [int]; if (-not $count) { $count = 0 }
        $percentage = $entry.percentage -as [double]; if (-not $percentage) { $percentage = 0 }
        $output += "    { type: '$($entry.warningType)', count: $count, percentage: $percentage },`n"
    }
    $output = $output.TrimEnd(",`n") + "`n  ]`n"
    $output += "}"

    $output += ";"

    try {
        Set-Content -Path "./data.js" -Value $output -Encoding UTF8
        Log "data.js file successfully created with summary, computers, and 10 latest warnings."
    } catch {
        Log "ERROR: Failed to write to data.js: $_"
        exit 5
    }
}


# Main script 
Import-Module SqlServer -ErrorAction SilentlyContinue

CheckAdmin
CheckParams
InitConnection

try {
    $warnings = GetWarnings
    if (-not $warnings) { $warnings = @() }

    $cpu7 = GetCpu7Days
    if (-not $cpu7) { $cpu7 = @() }

    $ram7 = GetRam7Days
    if (-not $ram7) { $ram7 = @() }

    $measurements = GetMeasurements
    if (-not $measurements) { $measurements = @() }

    $summary = GetSummary
    if (-not $summary -or $summary.Count -eq 0) {
        $summary = @{
            computerCount = 0
            avgCpuToday = 0
            avgRamUsageToday = 0
            avgWarningsLast7Days = 0
            warningsToday = 0
        }
    } else {
        $summary = $summary[0]  # Because SELECT TOP 1 returns a single-row DataTable
    }

    $warningStats = GetWarningStats
    if (-not $warningStats) { $warningStats = @() }

    WriteToJs -warnings $warnings -measurements $measurements -summary $summary -cpu7 $cpu7 -ram7 $ram7 -warnings7 $null -warningStats $warningStats
} catch {
    Log "ERROR: Unexpected error: $_"
    exit 1
}