#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Primary','Secondary')]
    [string]$Role,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Lab.psd1')
)

$ErrorActionPreference = 'Stop'
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$domain = $config.DomainName
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$expectedName = if ($Role -eq 'Primary') { $config.PrimaryDC } else { $config.SecondaryDC }

if ($config.PrimaryDC -eq $config.SecondaryDC) {
    throw 'Configure two distinct domain controller names in Lab.psd1.'
}
if ($computer.Name -ne $expectedName) {
    throw "Run this phase on $expectedName. Current computer: $($computer.Name)."
}

# DomainRole 4 and 5 identify domain controllers, regardless of FSMO ownership.
if ($computer.DomainRole -in 4, 5) {
    if ($computer.Domain -ne $domain) {
        throw "This server is already a domain controller for $($computer.Domain)."
    }
    Write-Output "$expectedName is already a domain controller for $domain."
    return
}
if ($computer.DomainRole -lt 2) {
    throw 'Run this script on a Windows Server VM.'
}
if ($computer.PartOfDomain -and ($Role -eq 'Primary' -or $computer.Domain -ne $domain)) {
    throw "This server is already joined to $($computer.Domain)."
}

$source = "$($config.PrimaryDC).$domain"
if ($Role -eq 'Secondary') {
    $records = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -DnsOnly
    if ($source -notin @($records | Where-Object Type -eq 'SRV' |
            ForEach-Object { $_.NameTarget.TrimEnd('.') })) {
        throw "DNS must advertise $source as a controller for $domain before promotion."
    }
}

if (-not $PSCmdlet.ShouldProcess("$expectedName for $domain", 'Install AD DS and promote server; promotion restarts the VM')) {
    return
}

Import-Module ServerManager
$install = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
if (-not $install.Success) {
    throw 'AD DS feature installation failed.'
}
if ($install.RestartNeeded -eq 'Yes') {
    throw 'Restart this VM to finish installing AD DS, then rerun this phase.'
}
Import-Module ADDSDeployment

# The promotion cmdlets prompt for the DSRM password.
if ($Role -eq 'Primary') {
    Install-ADDSForest -DomainName $domain -DomainNetbiosName $config.NetBIOSName -InstallDns -CreateDnsDelegation:$false
}
else {
    $credential = Get-Credential -Message "Enter a domain administrator credential for $domain"
    Install-ADDSDomainController -DomainName $domain -Credential $credential -ReplicationSourceDC $source -InstallDns -CreateDnsDelegation:$false
}
