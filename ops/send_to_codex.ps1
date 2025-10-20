# VERSION: G2
# NEXT: implement Codex call
#requires -Version 7.0
<#!
.SYNOPSIS
send_to_codex CLI foundation for Codex-driven automation.
.DESCRIPTION
Establishes configuration loading, run tracking, and logging for the send_to_codex workflow while deferring Codex transport to future iterations.
.VERSION
G2
.AUTHOR
AI via Codex
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [Parameter()]
    [Alias("repo")]
    [string]$Repo,

    [Parameter()]
    [Alias("branch")]
    [string]$Branch,

    [Parameter()]
    [Alias("dry-run")]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:LogLevelMap = @{
    ERROR = 0
    WARN  = 1
    INFO  = 2
}
$script:ConfiguredLogLevel = "INFO"
$script:SaveLogs = $true
$script:LogFilePath = $null
$script:RunId = $null

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $normalizedLevel = $Level.ToUpperInvariant()
    if (-not $script:LogLevelMap.ContainsKey($normalizedLevel)) {
        $normalizedLevel = "INFO"
    }

    $configuredLevel = $script:ConfiguredLogLevel
    if (-not $script:LogLevelMap.ContainsKey($configuredLevel)) {
        $configuredLevel = "INFO"
    }

    if ($script:LogLevelMap[$normalizedLevel] -gt $script:LogLevelMap[$configuredLevel]) {
        return
    }

    $entry = "[send_to_codex] {0} {1}" -f $normalizedLevel, $Message

    switch ($normalizedLevel) {
        "ERROR" { Write-Host $entry -ForegroundColor Red }
        "WARN"  { Write-Host $entry -ForegroundColor Yellow }
        default  { Write-Host $entry }
    }

    if ($script:SaveLogs -and $script:LogFilePath) {
        try {
            Add-Content -Path $script:LogFilePath -Value $entry
        }
        catch {
            Write-Host "[send_to_codex] WARN Unable to append to log file: $($_.Exception.Message)"
        }
    }
}

function Write-Warn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log -Message $Message -Level "WARN"
}

function Write-ErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log -Message $Message -Level "ERROR"
    Write-Error -Message $Message -ErrorAction Continue
}

function Get-RepositoryRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    return (Resolve-Path -Path (Join-Path -Path $ScriptRoot -ChildPath "..")).Path
}

function New-RunId {
    [CmdletBinding()]
    param()

    return "run-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
}

function Load-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $configDirectory = Join-Path -Path $RepositoryRoot -ChildPath "ops/config"
    $configPath = Join-Path -Path $configDirectory -ChildPath "send_to_codex.yaml"

    $defaultConfig = @"
version: g2
mode: cli
default_repo: .
retry: 1
transport:
  cli_command: codex
logging:
  level: info
  save: true
"@

    if (-not (Test-Path -Path $configDirectory)) {
        try {
            New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        }
        catch {
            Write-Host "[send_to_codex] WARN Failed to create config directory: $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path -Path $configPath)) {
        try {
            Set-Content -Path $configPath -Value $defaultConfig -Encoding UTF8
        }
        catch {
            Write-Host "[send_to_codex] WARN Failed to create default config file: $($_.Exception.Message)"
        }
    }

    try {
        $rawConfig = Get-Content -Path $configPath -Raw
        $configData = ConvertFrom-Yaml -Yaml $rawConfig
        return [pscustomobject]@{
            Path = $configPath
            Data = $configData
        }
    }
    catch {
        Write-Host "[send_to_codex] WARN Unable to load configuration. Falling back to defaults. $($_.Exception.Message)"
        $configData = ConvertFrom-Yaml -Yaml $defaultConfig
        return [pscustomobject]@{
            Path = $configPath
            Data = $configData
        }
    }
}

function Initialize-LogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter()]
        [bool]$SaveLogs = $true
    )

    $logDirectory = Join-Path -Path $RepositoryRoot -ChildPath "logs/send"
    if (-not (Test-Path -Path $logDirectory)) {
        try {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        catch {
            Write-Host "[send_to_codex] WARN Failed to create log directory: $($_.Exception.Message)"
        }
    }

    $logFile = Join-Path -Path $logDirectory -ChildPath ("{0}.log" -f $RunId)

    if ($SaveLogs) {
        try {
            New-Item -ItemType File -Path $logFile -Force | Out-Null
        }
        catch {
            Write-Host "[send_to_codex] WARN Failed to initialize log file: $($_.Exception.Message)"
            return $null
        }
    }

    return $logFile
}

function Resolve-Repo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter()]
        [string]$RepoParameter,

        [Parameter()]
        [psobject]$Config
    )

    $candidate = $RepoParameter

    if ([string]::IsNullOrWhiteSpace($candidate) -and $Config -and $Config.PSObject.Properties["default_repo"]) {
        $candidate = $Config.default_repo
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = "."
    }

    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path -Path $RepositoryRoot -ChildPath $candidate
    }

    try {
        $resolved = Resolve-Path -Path $candidate -ErrorAction Stop
        return $resolved.Path
    }
    catch {
        Write-Warn -Message ("Repository path '{0}' could not be resolved. Continuing with provided value." -f $candidate)
        return $candidate
    }
}

function Invoke-SendToCodex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [string]$Branch,

        [switch]$DryRun,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [psobject]$Config
    )

    Write-Log -Message ("Starting send_to_codex run {0}." -f $RunId)
    Write-Log -Message ("Resolved repository path: {0}" -f $RepoPath)

    if ($Branch) {
        Write-Log -Message ("Target branch: {0}" -f $Branch)
    }

    if ($DryRun.IsPresent) {
        Write-Warn -Message "Dry-run mode active. Operational actions are skipped."
    }
    else {
        Write-Log -Message "Dry-run mode disabled. Operational actions would execute in future releases."
    }

    Write-Log -Message ("Message payload: {0}" -f $Message)

    if ($Config -and $Config.PSObject.Properties["transport"]) {
        $transportCommand = $Config.transport.cli_command
        if ($transportCommand) {
            Write-Log -Message ("Configured transport command: {0}" -f $transportCommand)
        }
    }

    Write-Log -Message "Codex transport not yet implemented (G2 base)."
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    $repositoryRoot = Get-RepositoryRoot -ScriptRoot $PSScriptRoot
    $configResult = Load-Config -RepositoryRoot $repositoryRoot
    $config = $configResult.Data

    $script:ConfiguredLogLevel = "INFO"
    $script:SaveLogs = $true

    if ($config -and $config.PSObject.Properties["logging"]) {
        $loggingLevel = $config.logging.level
        if (-not [string]::IsNullOrWhiteSpace($loggingLevel)) {
            $script:ConfiguredLogLevel = $loggingLevel.ToUpperInvariant()
        }

        if ($config.logging.PSObject.Properties["save"]) {
            $script:SaveLogs = [bool]$config.logging.save
        }
    }

    $script:RunId = New-RunId
    $logFile = Initialize-LogFile -RepositoryRoot $repositoryRoot -RunId $script:RunId -SaveLogs $script:SaveLogs
    $script:LogFilePath = $logFile

    Write-Log -Message ("Configuration loaded from: {0}" -f $configResult.Path)

    if ($logFile) {
        Write-Log -Message ("Log file initialized at: {0}" -f $logFile)
    }
    else {
        Write-Warn -Message "Log file could not be initialized; console logging only."
    }

    Write-Log -Message ("Run identifier: {0}" -f $script:RunId)

    $repoPath = Resolve-Repo -RepositoryRoot $repositoryRoot -RepoParameter $Repo -Config $config

    try {
        Invoke-SendToCodex -Message $Message -RepoPath $repoPath -Branch $Branch -DryRun $DryRun -RunId $script:RunId -Config $config
    }
    catch {
        Write-ErrorLog -Message ("Unhandled error: {0}" -f $_.Exception.Message)
        throw
    }
}

Invoke-Main
