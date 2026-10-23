# Root setup launcher - delegates to technical-setup/setup.ps1
[CmdletBinding()]
param(
    [switch]$ForceReinstall,
    [switch]$IncludeKorean
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetScript = Join-Path $ScriptDir "technical-setup\setup.ps1"

if (Test-Path $TargetScript) {
    & $TargetScript @PSBoundParameters
} else {
    Write-Error "Could not locate technical-setup/setup.ps1"
}
