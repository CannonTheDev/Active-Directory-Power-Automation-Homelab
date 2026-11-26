#Requires -Version 5.1
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Lab.psd1'),
    [string]$CsvPath = (Join-Path $PSScriptRoot 'users.csv')
)

$ErrorActionPreference = 'Stop'
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$server = "$($config.PrimaryDC).$($config.DomainName)"
$domain = Get-ADDomain -Server $server
if ($domain.DNSRoot -ne $config.DomainName) {
    throw "The domain reported by $server differs from the configured domain."
}

$departments = @($config.Departments)
$ouNamePattern = '^[A-Za-z][A-Za-z0-9-]{0,15}$'
if ($config.RootOU -notmatch $ouNamePattern -or $departments.Count -eq 0 -or
    @($departments | Where-Object { $_ -notmatch $ouNamePattern }).Count -gt 0 -or
    @($departments | Sort-Object -Unique).Count -ne $departments.Count) {
    throw 'Use distinct department names and a root OU name with 1-16 letters, digits, or hyphens, starting with a letter.'
}

$users = @(Import-Csv -LiteralPath $CsvPath)
if ($users.Count -eq 0) {
    throw 'Provide at least one CSV data row.'
}
$seen = @{}
foreach ($user in $users) {
    $sam = $user.SamAccountName
    if ($sam -notmatch '^[a-z][a-z0-9._-]{0,19}$' -or
        [string]::IsNullOrWhiteSpace($user.GivenName) -or
        [string]::IsNullOrWhiteSpace($user.Surname) -or $user.Department -notin $departments) {
        throw "Invalid CSV row for '$sam'. Check the required columns, account name, and department."
    }
    if ($seen.ContainsKey($sam)) {
        throw "Duplicate account name in CSV: $sam"
    }
    $seen[$sam] = $true
}

$rootDN = "OU=$($config.RootOU),$($domain.DistinguishedName)"
$usersDN = "OU=Users,$rootDN"
$groupsDN = "OU=Groups,$rootDN"
$ous = @(
    @{ Name = $config.RootOU; Parent = $domain.DistinguishedName }
    @{ Name = 'Users'; Parent = $rootDN }
    @{ Name = 'Groups'; Parent = $rootDN }
    @{ Name = 'Workstations'; Parent = $rootDN }
)
foreach ($department in $departments) {
    $ous += @{ Name = $department; Parent = $usersDN }
}

# Check for account and group collisions before creating any objects.
foreach ($department in $departments) {
    $name = "GG-$department"
    $group = Get-ADGroup -Filter "SamAccountName -eq '$name'" -Server $server
    if ($group -and ($group.DistinguishedName -ne "CN=$name,$groupsDN" -or
            $group.GroupScope -ne 'Global' -or $group.GroupCategory -ne 'Security')) {
        throw "Group $name already exists with a different path or type."
    }
}
foreach ($user in $users) {
    $sam = $user.SamAccountName
    $account = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Server $server -Properties UserPrincipalName
    $expectedDN = "CN=$sam,OU=$($user.Department),$usersDN"
    if ($account -and ($account.DistinguishedName -ne $expectedDN -or
            $account.UserPrincipalName -ne "$sam@$($domain.DNSRoot)")) {
        throw "Account $sam already exists with a different path or sign-in name."
    }
}

$summary = [ordered]@{ OUsCreated = 0; GroupsCreated = 0; UsersCreated = 0; MembershipsAdded = 0 }
foreach ($ou in $ous) {
    $name = $ou.Name
    $dn = "OU=$name,$($ou.Parent)"
    $existing = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -Server $server
    if (-not $existing -and $PSCmdlet.ShouldProcess($dn, 'Create organizational unit')) {
        New-ADOrganizationalUnit -Name $name -Path $ou.Parent -ProtectedFromAccidentalDeletion $true -Server $server
        $summary.OUsCreated++
    }
}

foreach ($department in $departments) {
    $name = "GG-$department"
    $group = Get-ADGroup -Filter "SamAccountName -eq '$name'" -Server $server
    if (-not $group -and $PSCmdlet.ShouldProcess($name, 'Create global security group')) {
        New-ADGroup -Name $name -SamAccountName $name -Path $groupsDN -GroupScope Global -GroupCategory Security -Server $server
        $summary.GroupsCreated++
    }
}

foreach ($user in $users) {
    $sam = $user.SamAccountName
    $account = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Server $server
    if (-not $account -and $PSCmdlet.ShouldProcess($sam, 'Create disabled user')) {
        $newUser = @{
            Name = $sam
            SamAccountName = $sam
            UserPrincipalName = "$sam@$($domain.DNSRoot)"
            GivenName = $user.GivenName
            Surname = $user.Surname
            DisplayName = "$($user.GivenName) $($user.Surname)"
            Department = $user.Department
            Path = "OU=$($user.Department),$usersDN"
            Enabled = $false
            Server = $server
            PassThru = $true
        }
        $account = New-ADUser @newUser
        $summary.UsersCreated++
    }

    $groupName = "GG-$($user.Department)"
    $group = Get-ADGroup -Filter "SamAccountName -eq '$groupName'" -Server $server -Properties Member
    $hasMembership = $account -and $group -and $account.DistinguishedName -in $group.Member
    if (-not $hasMembership -and $PSCmdlet.ShouldProcess("$sam in $groupName", 'Add group membership')) {
        Add-ADGroupMember -Identity $group.DistinguishedName -Members $account.DistinguishedName -Server $server
        $summary.MembershipsAdded++
    }
}

[pscustomobject]$summary
