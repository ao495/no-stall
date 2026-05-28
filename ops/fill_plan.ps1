# ops/fill_plan.ps1
<#
.SYNOPSIS
  NoStall: Plan Filler
.DESCRIPTION
  PLAN.md やログをスキャンして「次にやるべきこと」を自動提案する。
  Codex / GPT に送る命令文を生成し、send_to_codex.ps1 に引き渡す。
#>

param(
    [string]$PlanPath = "PLAN.md",
    [string]$LogDir = "logs/send",
    [switch]$DryRun,
    [switch]$SendDryRun
)

$RepositoryRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).Path

function Resolve-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path -Path $RepositoryRoot -ChildPath $Path
}

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[fill_plan] $timestamp $Message"
}

function Get-LatestLog {
    param([string]$Dir)
    $resolvedDir = Resolve-RepoPath -Path $Dir
    if (!(Test-Path $resolvedDir)) { return $null }
    Get-ChildItem $resolvedDir -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Analyze-NextStep {
    param([string]$PlanFile, [System.IO.FileInfo]$LatestLog)
    $resolvedPlanFile = Resolve-RepoPath -Path $PlanFile
    $plan = if (Test-Path $resolvedPlanFile) { Get-Content $resolvedPlanFile -Raw } else { "" }
    $log = if ($LatestLog) { Get-Content $LatestLog.FullName -Raw } else { "" }

    Write-Log "PLANと最新ログを解析中..."
    $prompt = @"
次のタスクを提案してください。
【PLAN内容】
$plan

【最新ログ】
$log
"@
    return $prompt
}

Write-Log "fill_plan 開始"
$latest = Get-LatestLog -Dir $LogDir
$cmd = Analyze-NextStep -PlanFile $PlanPath -LatestLog $latest

if ($DryRun) {
    Write-Log "DryRunモード - 生成内容:"
    Write-Host $cmd
} else {
    Write-Log "send_to_codex.ps1 に転送します..."
    $sendScript = Join-Path -Path $PSScriptRoot -ChildPath "send_to_codex.ps1"
    $sendArgs = @($sendScript, $cmd, "-Repo", $RepositoryRoot)
    if ($SendDryRun) {
        $sendArgs += "-DryRun"
    }

    & pwsh @sendArgs
}
