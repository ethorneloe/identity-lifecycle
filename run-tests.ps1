$log = 'C:\Dev\identity-lifecycle\test-output.txt'
Start-Transcript -Path $log -Force
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
. 'C:\Dev\identity-lifecycle\IdentityLifecycle\tests\Invoke-SweepTest.ps1'
Stop-Transcript
