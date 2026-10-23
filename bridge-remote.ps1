$target = Join-Path $PSScriptRoot "scripts\bridge-remote.ps1"
if ($args.Count -eq 0) {
    & $target
} else {
    & $target @args
}
