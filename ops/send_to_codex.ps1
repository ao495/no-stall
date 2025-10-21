# VERSION: G2
# NEXT: implement Codex-driven PR pipeline
#requires -Version 7.0
<#!
.SYNOPSIS
send_to_codex CLI foundation for Codex-driven automation.
.DESCRIPTION
Provides configuration loading, run tracking, logging, and Codex CLI transport for AI-driven development workflows.
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
    [Alias("Repository", "RepoName")]
    [string]$Repo,

    [Parameter()]
    [Alias("TargetBranch", "BranchName")]
    [string]$Branch,

    [Parameter()]
    [Alias("Dry", "DryRunMode")]
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

    $defaultConfigLines = @(
        'version: g2',
        'mode: cli',
        'default_repo: .',
        'retry: 1',
        'transport:',
        '  cli_command: codex',
        'logging:',
        '  level: info',
        '  save: true'
    )
    $defaultConfig = $defaultConfigLines -join "`n"

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

function Send-CodexMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$RepoPath,

        [string]$Branch,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$LogFile,

        [Parameter()]
        [bool]$VerboseMode = $false
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Warn -Message "Codex transport skipped: message payload is empty."
        return
    }

    $transportMode = "cli"
    if ($Config -and $Config.PSObject.Properties["mode"] -and $Config.mode) {
        $transportMode = $Config.mode.ToLowerInvariant()
    }

    if ($transportMode -ne "cli") {
        Write-Warn -Message ("Configured transport mode '{0}' is not supported in this release." -f $transportMode)
        return
    }

    $transportCommand = "codex"
    if ($Config -and $Config.PSObject.Properties["transport"] -and $Config.transport.cli_command) {
        $transportCommand = $Config.transport.cli_command
    }

    $branchDisplay = if ([string]::IsNullOrWhiteSpace($Branch)) { "(not specified)" } else { $Branch }

    $payloadBuilder = [System.Text.StringBuilder]::new()
    $null = $payloadBuilder.AppendLine("# Executor: send_to_codex.ps1 (G2 CLI)")
    $null = $payloadBuilder.AppendLine()
    $null = $payloadBuilder.AppendLine("## Context")
    $null = $payloadBuilder.AppendLine(("Repository: {0}" -f $RepoPath))
    $null = $payloadBuilder.AppendLine(("Branch: {0}" -f $branchDisplay))
    $null = $payloadBuilder.AppendLine(("Run ID: {0}" -f $RunId))
    $null = $payloadBuilder.AppendLine()
    $null = $payloadBuilder.AppendLine("## Instruction")
    $null = $payloadBuilder.AppendLine($Message.Trim())
    $payload = $payloadBuilder.ToString()

    Write-Log -Message ("Prepared Codex payload ({0} characters)." -f $payload.Length)

    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $transportCommand
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true

        if ($VerboseMode) {
            Write-Log -Message ("Executing transport command: {0}" -f $transportCommand)
        }

        $process = [System.Diagnostics.Process]::Start($processInfo)
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()

        $response = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
    }
    catch {
        Write-ErrorLog -Message ("Failed to execute Codex transport: {0}" -f $_.Exception.Message)
        return
    }

    if ($errorOutput) {
        Write-Warn -Message ("Codex transport stderr: {0}" -f $errorOutput.Trim())
    }

    if (-not $response -or [string]::IsNullOrWhiteSpace($response)) {
        Write-Warn -Message "Codex transport returned no response."
        return
    }

    Write-Log -Message "Codex transport completed; capturing response."
    Write-Host $response

    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value ("[send_to_codex] INFO Codex response ({0})" -f (Get-Date -Format "O"))
            Add-Content -Path $LogFile -Value $response
        }
        catch {
            Write-Warn -Message ("Failed to append Codex response to log file: {0}" -f $_.Exception.Message)
        }
    }

    return $response
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

        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$LogFile,

        [Parameter()]
        [bool]$VerboseMode = $false
    )

    Write-Log -Message ("Starting send_to_codex run {0}." -f $RunId)
    Write-Log -Message ("Resolved repository path: {0}" -f $RepoPath)

    if ($Branch) {
        Write-Log -Message ("Target branch: {0}" -f $Branch)
    }

    if ($DryRun.IsPresent) {
        Write-Warn -Message "Dry-run mode active. Operational actions are skipped."
        Write-Log -Message "Codex transport not invoked due to dry-run configuration."
        return
    }

    Write-Log -Message ("Message payload: {0}" -f $Message)

    if ($Config -and $Config.PSObject.Properties["transport"]) {
        $transportCommand = $Config.transport.cli_command
        if ($transportCommand) {
            Write-Log -Message ("Configured transport command: {0}" -f $transportCommand)
        }
    }

    $null = Send-CodexMessage -Message $Message -RepoPath $RepoPath -Branch $Branch -RunId $RunId -Config $Config -LogFile $LogFile -VerboseMode:$VerboseMode
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
    $verboseMode = $VerbosePreference -eq 'Continue'

    try {
        Invoke-SendToCodex -Message $Message -RepoPath $repoPath -Branch $Branch -DryRun:$DryRun -RunId $script:RunId -Config $config -LogFile $logFile -VerboseMode:$verboseMode
    }
    catch {
        Write-ErrorLog -Message ("Unhandled error: {0}" -f $_.Exception.Message)
        throw
    }
}

Invoke-Main
