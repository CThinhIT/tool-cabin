# Runs gemini_probe with GEMINI_API_KEY taken from a DPAPI-encrypted file that
# only the current Windows user can decrypt. The key is never printed, and the
# variable lives only in this PowerShell process.
#
# Create the key file once (in your own PowerShell window, paste the key, Enter):
#   New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\trans_app" | Out-Null
#   Read-Host "Gemini API key" -AsSecureString | ConvertFrom-SecureString | Set-Content "$env:LOCALAPPDATA\trans_app\gemini_key.dpapi"
# Delete it when done:
#   Remove-Item "$env:LOCALAPPDATA\trans_app\gemini_key.dpapi"
#
# Usage: .\with_key.ps1 translate --in samples\en_short.wav --target vi --out out\x.wav
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $ProbeArgs)

$keyFile = Join-Path $env:LOCALAPPDATA 'trans_app\gemini_key.dpapi'
if (-not $env:GEMINI_API_KEY) {
    if (-not (Test-Path $keyFile)) {
        Write-Output "Key file not found: $keyFile"
        Write-Output 'Create it with the two commands at the top of this script.'
        exit 78
    }
    try {
        $secure = Get-Content $keyFile -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
    } catch {
        Write-Output "Cannot decrypt $keyFile (created by another Windows user?): $($_.Exception.Message)"
        exit 78
    }
    $env:GEMINI_API_KEY = [System.Net.NetworkCredential]::new('', $secure).Password
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location $PSScriptRoot
& dart run bin/gemini_probe.dart @ProbeArgs
exit $LASTEXITCODE
