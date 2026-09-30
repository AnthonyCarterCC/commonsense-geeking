# =============================================================================
# Verify-Harmoniq-gMSA.ps1
# Checks that the Harmoniq gMSA is active and ready to use on:
#   - HMA-DC26
#   - HMA-RDS26
#   - HMA-SQL26
#
# Run this on each server individually (the local check), OR run the remote
# section from one machine (e.g. the DC) to check all three at once via
# PowerShell remoting (requires WinRM enabled, which is on by default
# between domain-joined servers).
# =============================================================================

$gmsaName = "Harmoniq"
$servers  = @("HMA-DC26", "HMA-RDS26", "HMA-SQL26")

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Harmoniq gMSA Readiness Check" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# LOCAL CHECK - what happens on the machine the script is run on
# ---------------------------------------------------------------------------
function Test-HarmoniqLocally {
    $hostname = $env:COMPUTERNAME
    Write-Host "`nChecking on: $hostname" -ForegroundColor Yellow

    $testResult = $null
    try {
        $testResult = Test-ADServiceAccount -Identity $gmsaName
    } catch {
        Write-Host "  [FAIL] Test-ADServiceAccount threw an error: $_" -ForegroundColor Red
        return
    }

    if ($testResult -eq $true) {
        Write-Host "  [PASS] gMSA '$gmsaName' is ACTIVE and READY on $hostname" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] gMSA '$gmsaName' is NOT ready on $hostname" -ForegroundColor Red
        Write-Host "         - Confirm $hostname`$ is a member of Harmoniq-Servers group" -ForegroundColor Yellow
        Write-Host "         - Confirm Install-ADServiceAccount -Identity $gmsaName has been run here" -ForegroundColor Yellow
        Write-Host "         - A reboot may be required to refresh the Kerberos ticket" -ForegroundColor Yellow
    }
}

Test-HarmoniqLocally

# ---------------------------------------------------------------------------
# REMOTE CHECK - run this from any single machine to check ALL THREE
# servers at once via PowerShell remoting
# ---------------------------------------------------------------------------
Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host " Remote check across all servers" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

foreach ($server in $servers) {
    Write-Host "`nChecking $server remotely..." -ForegroundColor Yellow
    try {
        $result = Invoke-Command -ComputerName $server -ScriptBlock {
            param($gmsaName)
            try {
                $env:ADPS_LoadDefaultDrive = 0
                Import-Module ActiveDirectory -ErrorAction Stop
                New-PSDrive -Name AD -PSProvider ActiveDirectory -Server "HMA-DC26" -Root "//RootDSE/" -ErrorAction Stop | Out-Null
                $test = Test-ADServiceAccount -Identity $gmsaName
                return $test
            } catch {
                return "ERROR: $_"
            }
        } -ArgumentList $gmsaName -ErrorAction Stop

        if ($result -eq $true) {
            Write-Host "  [PASS] $server - gMSA is ACTIVE and READY" -ForegroundColor Green
        } elseif ($result -eq $false) {
            Write-Host "  [FAIL] $server - gMSA installed but not ready (check group membership / reboot)" -ForegroundColor Red
        } else {
            Write-Host "  [FAIL] $server - $result" -ForegroundColor Red
        }
    } catch {
        Write-Host "  [FAIL] $server - Could not connect remotely (WinRM/firewall issue?): $_" -ForegroundColor Red
        Write-Host "         Run this script locally on $server instead." -ForegroundColor Yellow
    }
}

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host " Check complete." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
