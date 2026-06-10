@{
    # The published module is named for its owner to keep the Gallery id unique
    # (`work-items` alone is too generic to claim). The *command* it exports is
    # still plain `work-items` — see FunctionsToExport — so users type that.
    RootModule        = 'guyvdn-work-items.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'df94105e-6727-4f01-8263-6e3620ad8372'
    Author            = 'guyvdn'
    CompanyName       = 'guyvdn'
    Copyright         = '(c) 2026 guyvdn. Released under the MIT License.'
    Description       = 'A themed terminal dashboard for the GitHub issues and pull requests assigned to you: grouped by project-board status, theme-adaptive ANSI colours, parallel fetch with a spinner, and one-key hand-off to Claude Code.'

    # ForEach-Object -Parallel requires PowerShell 7; the tool is Core-only.
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')

    # Exactly one public command. Listing it explicitly (not '*') is what lets
    # PowerShell autoload this module the first time someone types `work-items`,
    # so no profile edit or Import-Module is needed.
    FunctionsToExport = @('work-items')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('GitHub','gh','issues','pull-requests','TUI','terminal','dashboard','productivity','ClaudeCode','PSEdition_Core')
            LicenseUri   = 'https://github.com/guyvdn/work-items/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/guyvdn/work-items'
            ReleaseNotes = 'Initial PowerShell Gallery release.'
        }
    }
}
