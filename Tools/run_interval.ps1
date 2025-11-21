param(
    [string]$Config = "Debug",
    [string]$Platform = "x64",
    [int]$RunSeconds = 10
)

$ErrorActionPreference = "Stop"
$env:D3D12_ENABLE_DEBUG_LAYER = "1"

$root    = Resolve-Path "..\\Samples\\Desktop\\D3D12MeshShaders\\src"
$proj    = Join-Path $root "IntervalShadingTetrahedron\\IntervalShadingTetrahedron.vcxproj"
$binDir  = Join-Path $root ("bin\\{0}\\{1}" -f $Platform, $Config)
$exe     = Join-Path $binDir "IntervalShadingTetrahedron.exe"
$logPath = Join-Path $binDir "d3d12_log.txt"

Write-Host "Building $proj ($Config|$Platform)..."
& msbuild $proj /m /p:Configuration=$Config /p:Platform=$Platform

Write-Host "Clearing previous log: $logPath"
if (Test-Path $logPath) { Remove-Item $logPath }

Write-Host "Launching $exe"
$proc = Start-Process -FilePath $exe -PassThru

Start-Sleep -Seconds $RunSeconds

if (!$proc.HasExited) {
    Write-Host "Stopping $exe after $RunSeconds seconds..."
    $proc.CloseMainWindow() | Out-Null
    Start-Sleep -Seconds 2
    if (!$proc.HasExited) { $proc | Stop-Process -Force }
}

if (Test-Path $logPath) {
    Write-Host "`n--- d3d12_log.txt ---"
    Get-Content $logPath
} else {
    Write-Host "`n(No d3d12_log.txt found; ensure the app writes the info queue to this file.)"
}
