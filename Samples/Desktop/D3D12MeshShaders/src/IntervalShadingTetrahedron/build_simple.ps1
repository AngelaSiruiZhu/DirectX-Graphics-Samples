# Find MSBuild
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe

if (-not $msbuild) {
    Write-Error "MSBuild not found."
    exit 1
}

# Define paths
$projectRoot = "$PSScriptRoot"
$solutionPath = Resolve-Path "$projectRoot\..\D3D12MeshShaders.sln"
$outputDir = "$projectRoot\bin\"

# Touch all shader files to force recompilation
Get-ChildItem "$projectRoot\*.hlsl" | ForEach-Object { $_.LastWriteTime = Get-Date }

# Build
& $msbuild $solutionPath /t:IntervalShadingTetrahedron /p:Configuration=Debug /p:Platform=x64 /p:OutDir="$outputDir" /p:TargetName="runnable" -restore

if ($LASTEXITCODE -eq 0) {
    Write-Host "Build success! Output: ${outputDir}runnable.exe"
} else {
    Write-Error "Build failed."
}

