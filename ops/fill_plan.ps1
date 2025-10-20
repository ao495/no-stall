param(
    [string]$File = "plan.yaml"
)

Write-Host "[no-stall] scanning $File..."

if (-not (Test-Path $File)) {
    Write-Warning "File not found: $File"
    exit 1
}

$content = Get-Content $File -Raw
$missing = @()

if ($content -notmatch "目的:") { $missing += "目的" }
if ($content -notmatch "状況:") { $missing += "状況" }
if ($content -notmatch "方針:") { $missing += "方針" }
if ($content -notmatch "返答:") { $missing += "返答" }

if ($missing.Count -eq 0) {
    Write-Host "✅ plan.yaml is complete."
} else {
    Write-Warning "⚠️ Missing sections detected:"
    $missing | ForEach-Object { Write-Host " - $_" }

    $choice = Read-Host "補完方法を選択 (1=AI提案, 2=手動入力, 3=スキップ)"
    switch ($choice) {
        1 { Write-Host "AI提案モードを準備中..." }
        2 { Write-Host "手動入力モードを開始します..." }
        3 { Write-Host "仮値を挿入して続行します..." }
    }
}
