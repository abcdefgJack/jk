@{
    RootModule        = 'jk.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5b1f7d1e-3c51-4f2e-9a3a-8f6f0d9c2a71'
    Author            = 'Jack Wang'
    Description       = 'jk - a personal command-line toolkit: deadlines, reminders, focus timer, Downloads cleanup, competitive programming runner, directory jumping and more.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('jk', 'j')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('productivity', 'deadlines', 'competitive-programming') } }
}
