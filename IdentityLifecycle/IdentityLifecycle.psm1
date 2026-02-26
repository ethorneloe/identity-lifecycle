
# Resolve module root whether loaded via Import-Module ($PSScriptRoot is set) or dot-sourced ($PSScriptRoot is empty)
$moduleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }

# Load public functions
$publicFunctions = Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'functions/public') -Filter *.ps1 -Recurse
foreach ($publicFunction in $publicFunctions) {
    . $publicFunction.FullName
    if ($PSScriptRoot) { Export-ModuleMember -Function $publicFunction.Basename }
}
