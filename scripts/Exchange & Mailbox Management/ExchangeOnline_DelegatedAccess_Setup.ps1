# Exchange Online PowerShell - Delegated Access Setup & Connection
# Run as Administrator

# ===== STEP 1: SET EXECUTION POLICY =====
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# ===== STEP 2: INSTALL/UPDATE POWERSHELLGET =====
Install-Module -Name PowerShellGet -Force -AllowClobber

# ===== STEP 3: INSTALL EXCHANGE ONLINE MANAGEMENT MODULE =====
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber

# ===== STEP 4: VERIFY INSTALLATION =====
Get-Module ExchangeOnlineManagement -ListAvailable

# ===== STEP 5: CONNECT TO CUSTOMER TENANT VIA DELEGATED ACCESS =====
Connect-ExchangeOnline -DelegatedOrganization healthoneau.onmicrosoft.com

# ===== VERIFY CONNECTION =====
# Run a test command to confirm connection
Get-OrganizationConfig

# ===== TO DISCONNECT =====
# Disconnect-ExchangeOnline -Confirm:$false
