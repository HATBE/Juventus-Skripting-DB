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

function SafeParseDouble($val) {
    if ($null -eq $val -or $val -eq "") { return 0.0 }
    try {
        return [double]::Parse($val.ToString().Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return 0.0
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


function GetComputers {
    $query = "SELECT computerId, hostname, ipAddress, operatingSystem, lastContact FROM Computer"

    try {
        $computers = Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
        return $computers
    } catch {
        Log "ERROR: Failed to fetch computers: $_"
        exit 2
    }
}

function GetWarnings {
    $query = @"
SELECT 
    w.warningId,
    w.measurementId,
    w.type,
    w.description,
    w.severityLevel,
    m.timestamp
FROM Warning w
JOIN Measurement m ON m.measurementId = w.measurementId
ORDER BY m.timestamp DESC
"@

    try {
        $warnings = Invoke-Sqlcmd -ConnectionString $Global:connectionString -Query $query
        return $warnings
    } catch {
        Log "ERROR: Failed to fetch warnings: $_"
        exit 4
    }
}

function WriteToJs {
    param(
        $computers,
        $warnings,
        $summary
    )

    if (-not $computers) { $computers = @() }
    if (-not $warnings) { $warnings = @() }

    # Pre-parse summary values outside of here-string to ensure accuracy
    $computerCount = $summary.computerCount
    $cpuAvg = $summary.avgCpuToday
    $ramAvg =  $summary.avgRamUsageToday
    $avgWarnings = $summary.avgWarningsLast7Days
    $warningsToday = $summary.warningsToday

    $output = "const data = {`n"

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

    # Computers section
    $output += "  computers: [`n"
    foreach ($comp in $computers) {
        $output += @"
    {
      computerId: $($comp.computerId),
      hostname: '$($comp.hostname)',
      ipAddress: '$($comp.ipAddress)',
      operatingSystem: '$($comp.operatingSystem)',
      lastContact: '$($comp.lastContact.ToString("yyyy-MM-dd HH:mm:ss"))'
    },
"@
    }
    $output = $output.TrimEnd(",`n") + "`n  ],`n"

    # Warnings section
    $output += "  warnings: [`n"
    foreach ($warn in $warnings) {
        $output += @"
    {
      warningId: $($warn.warningId),
      measurementId: $($warn.measurementId),
      type: '$($warn.type)',
      description: '$($warn.description)',
      severityLevel: '$($warn.severityLevel)',
      timestamp: '$($warn.timestamp.ToString("yyyy-MM-dd HH:mm:ss"))'
    },
"@
    }
    $output = $output.TrimEnd(",`n") + "`n  ]`n};"

    try {
        Set-Content -Path "./data.js" -Value $output -Encoding UTF8
        Log "data.js file successfully created with full dashboard summary, computers, and warnings."
    } catch {
        Log "ERROR: Failed to write to data.js: $_"
        exit 5
    }
}

# Main script flow
Import-Module SqlServer -ErrorAction SilentlyContinue

CheckAdmin
CheckParams
InitConnection

try {
    $computers = GetComputers
    $warnings = GetWarnings
    $summary = GetSummary
    WriteToJs -computers $computers -warnings $warnings -summary $summary
} catch {
    Log "ERROR: Unexpected error: $_"
    exit 1
}
