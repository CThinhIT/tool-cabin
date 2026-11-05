# Build audio_probe with MSVC (Visual Studio 2022). Output: build\Release\audio_probe.exe
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    cmake -S . -B build -G "Visual Studio 17 2022" -A x64
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
    cmake --build build --config Release
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
    Write-Host "OK: $PSScriptRoot\build\Release\audio_probe.exe"
} finally {
    Pop-Location
}
