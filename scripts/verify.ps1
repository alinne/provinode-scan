Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Fail {
    param([string]$Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$guardScript = Join-Path $repoRoot "scripts/ops/Assert-InternalApiArchitecture.ps1"
$projectPath = Join-Path $repoRoot "ProvinodeScan.xcodeproj"
$scheme = "ProvinodeScan"

$destinationId = & xcodebuild -project $projectPath -scheme $scheme -showdestinations 2>$null `
    | awk '/platform:iOS Simulator/ && /name:iPhone/ && /id:[A-F0-9-]+/ {print}' `
    | sed -E 's/.*id:([^, ]+).*/\1/' `
    | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace([string]$destinationId)) {
    Fail "No iPhone simulator destination found."
}

& xcodebuild -project $projectPath -scheme $scheme -destination "id=$destinationId" `
    -only-testing:ProvinodeScanTests/PairingServiceTests `
    -only-testing:ProvinodeScanTests/CaptureViewModelTests `
    -only-testing:ProvinodeScanTests/SessionRecorderTests `
    test
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& pwsh -NoProfile -File $guardScript -Strict
exit $LASTEXITCODE
