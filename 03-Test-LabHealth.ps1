#Requires -Version 5.1
#Requires -Modules ActiveDirectory
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Lab.psd1'),
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9._-]{0,19}$')]
    [string]$SampleUser = 'lab.avery',
    [ValidateRange(1, 168)]
    [int]$MaxReplicationAgeHours = 2,
    [string]$ReportPath = (Join-Path $PSScriptRoot 'LabHealth.csv')
)

$ErrorActionPreference = 'Stop'
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$domain = $config.DomainName
$controllers = @("$($config.PrimaryDC).$domain", "$($config.SecondaryDC).$domain")
$cutoff = (Get-Date).AddHours(-$MaxReplicationAgeHours)

function Invoke-HealthCheck {
    param([string]$Server, [string]$Check, [scriptblock]$Action)

    try {
        $detail = & $Action
        [pscustomobject]@{ Server = $Server; Check = $Check; Result = 'Pass'; Detail = $detail }
    }
    catch {
        [pscustomobject]@{ Server = $Server; Check = $Check; Result = 'Fail'; Detail = $_.Exception.Message }
    }
}

$results = foreach ($server in $controllers) {
    $peer = $controllers | Where-Object { $_ -ne $server }
    Invoke-HealthCheck $server 'DNS advertises both DCs' {
        $records = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -Server $server -DnsOnly
        $targets = @($records | Where-Object Type -eq 'SRV' | ForEach-Object { $_.NameTarget.TrimEnd('.') })
        $missing = @($controllers | Where-Object { $_ -notin $targets })
        if ($missing.Count) { throw "Missing DNS SRV target(s): $($missing -join ', ')." }
        $controllers -join ', '
    }
    Invoke-HealthCheck $server 'SYSVOL and NETLOGON' {
        foreach ($share in 'SYSVOL', 'NETLOGON') {
            $null = Get-Item -LiteralPath "\\$server\$share"
        }
        'Both shares are accessible from this computer.'
    }
    Invoke-HealthCheck $server 'Inbound domain replication' {
        $partition = (Get-ADDomain -Server $server).DistinguishedName
        $peerSettings = (Get-ADDomainController -Identity $peer -Server $server).NTDSSettingsObjectDN
        $neighbors = @(Get-ADReplicationPartnerMetadata -Target $server -Partition $partition |
            Where-Object { $_.Partner -eq $peerSettings })
        if ($neighbors.Count -eq 0) { throw "No inbound domain replication neighbor matches $peer." }
        $unhealthy = @($neighbors | Where-Object {
            $_.LastReplicationResult -ne 0 -or $_.ConsecutiveReplicationFailures -ne 0 -or
            $_.LastReplicationSuccess -lt $cutoff
        })
        if ($unhealthy.Count) { throw "Inbound replication from $peer failed or exceeds the age limit." }
        "Domain partition replicated from $peer within $MaxReplicationAgeHours hour(s)."
    }
    Invoke-HealthCheck $server 'Sample account' {
        $account = Get-ADUser -Identity $SampleUser -Server $server
        $labSuffix = ",OU=Users,OU=$($config.RootOU)," + (Get-ADDomain -Server $server).DistinguishedName
        if (-not $account.DistinguishedName.EndsWith($labSuffix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$SampleUser is outside the expected lab user OUs."
        }
        $account.DistinguishedName
    }
}

$results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
$results
if ($results.Result -contains 'Fail') {
    throw "One or more checks failed. See $ReportPath."
}
