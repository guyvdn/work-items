# Module loader for guyvdn-work-items.
#
# The actual code lives in work-items.ps1 — a single self-contained `work-items`
# function — so the same file serves both distribution methods: plain dot-sourcing
# of a clone, and this Gallery module. This loader just locates that file and
# re-exports the one public command.
#
# Where work-items.ps1 sits depends on how the module is loaded:
#   * installed from the Gallery / staged for publishing -> beside this file
#     (build\publish.ps1 copies it into the package),
#   * imported straight from the repo source tree         -> repo root, two levels up
#     (module\guyvdn-work-items\ -> repo root).
$src = Join-Path $PSScriptRoot 'work-items.ps1'
if (-not (Test-Path $src)) { $src = Join-Path $PSScriptRoot '..\..\work-items.ps1' }
. $src

Export-ModuleMember -Function 'work-items'
