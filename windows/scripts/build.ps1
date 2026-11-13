$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not (Test-Path .venv)) { py -3.12 -m venv .venv }
& .venv\Scripts\python.exe -m pip install -r requirements-build.txt
# PyInstaller resolves Qt's icuuc.dll dependency from PATH. Keep unrelated ICU
# builds (for example, a Poppler runtime) from being bundled ahead of Windows' ICU.
$systemIcuDirectory = Join-Path $env:SystemRoot "System32"
$filteredPath = foreach ($entry in ($env:PATH -split ';')) {
  if (-not $entry.Trim()) { continue }
  $resolvedEntry = [System.IO.Path]::GetFullPath($entry.Trim('"'))
  $isSystemIcu = $resolvedEntry.TrimEnd('\') -ieq $systemIcuDirectory.TrimEnd('\')
  if (-not $isSystemIcu -and (Test-Path (Join-Path $resolvedEntry 'icuuc.dll') -PathType Leaf)) { continue }
  $entry
}
$env:PATH = $filteredPath -join ';'
& .venv\Scripts\python.exe -m PyInstaller --noconfirm --clean AnyWay.spec
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# Keep only the browser locales used by the desktop UI.
Get-ChildItem "dist\AnyWay\runtime" -Directory -Recurse -Filter qtwebengine_locales |
  ForEach-Object {
    Get-ChildItem $_.FullName -File -Filter *.pak |
      Where-Object { $_.BaseName -notin @('en-US', 'zh-CN') } | Remove-Item
  }
$bytes = (Get-ChildItem "dist\AnyWay" -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("AnyWay 目录大小: {0:N1} MiB" -f ($bytes / 1MB))
Write-Host "已生成 dist\AnyWay\AnyWay.exe"
