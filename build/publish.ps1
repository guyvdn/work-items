#requires -Version 7.0
<#
.SYNOPSIS
    Stage and publish the guyvdn-work-items module to the PowerShell Gallery.

.DESCRIPTION
    Assembles a self-contained package under out\guyvdn-work-items (the manifest,
    the loader, and a copy of work-items.ps1), validates the manifest, and — unless
    -WhatIf is given — publishes it to the Gallery.

    Gallery versions are immutable: you cannot overwrite or re-upload a version that
    already exists. Bump ModuleVersion in the manifest before every real publish.

    The API key comes from -ApiKey or, by default, the PSGALLERY_KEY environment
    variable. Get one at https://www.powershellgallery.com/account/apikeys (scope it
    to the guyvdn-work-items package). Never commit the key.

.PARAMETER ApiKey
    PowerShell Gallery API key. Defaults to $env:PSGALLERY_KEY.

.EXAMPLE
    .\build\publish.ps1 -WhatIf
    Dry run: stage the package and run Test-ModuleManifest, but do not publish.

.EXAMPLE
    $env:PSGALLERY_KEY = '<key>'; .\build\publish.ps1
    Stage, validate, and publish the current ModuleVersion.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ApiKey = $env:PSGALLERY_KEY
)

$ErrorActionPreference = 'Stop'

$repo      = Split-Path $PSScriptRoot -Parent
$moduleSrc = Join-Path $repo 'module\guyvdn-work-items'
$staging   = Join-Path $repo 'out\guyvdn-work-items'

# Fresh staging directory every run. These always run, even under -WhatIf: staging
# and validation are side-effect-free against the Gallery, and Test-ModuleManifest
# below needs the files present. Only the Publish step is gated by ShouldProcess.
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -WhatIf:$false }
New-Item -ItemType Directory -Path $staging -Force -WhatIf:$false | Out-Null

# A published module must be self-contained, so copy the function source in beside
# the manifest and loader. work-items.ps1 stays the single source of truth in the
# repo root; this is the only place it is duplicated, and only into throwaway out\.
Copy-Item (Join-Path $moduleSrc '*') $staging -Recurse -Force -WhatIf:$false
Copy-Item (Join-Path $repo 'work-items.ps1') $staging -Force -WhatIf:$false

# Validate the manifest (also confirms RootModule and the source file are present).
$manifest = Join-Path $staging 'guyvdn-work-items.psd1'
$info = Test-ModuleManifest -Path $manifest
Write-Host "Staged guyvdn-work-items $($info.Version) -> $staging" -ForegroundColor Green

if ($PSCmdlet.ShouldProcess('PowerShell Gallery', "Publish guyvdn-work-items $($info.Version)")) {
    if (-not $ApiKey) {
        throw 'No API key. Set $env:PSGALLERY_KEY or pass -ApiKey. ' +
              'Create one at https://www.powershellgallery.com/account/apikeys'
    }
    # Prefer the modern PSResourceGet cmdlet (ships with PS 7.4+); fall back to
    # PowerShellGet v2 if only that is available.
    if (Get-Command Publish-PSResource -ErrorAction SilentlyContinue) {
        Publish-PSResource -Path $staging -ApiKey $ApiKey -Repository PSGallery
    } else {
        Publish-Module -Path $staging -NuGetApiKey $ApiKey -Repository PSGallery
    }
    Write-Host "Published guyvdn-work-items $($info.Version)." -ForegroundColor Green
} else {
    Write-Host "Dry run only — not published. Re-run without -WhatIf to publish." -ForegroundColor Yellow
}
