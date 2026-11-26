# Active Directory Deployment and PowerShell Automation

Deploy a two-controller Active Directory Domain Services (AD DS) lab, automate user and group provisioning, and validate authentication and replication from a Windows workstation. Run the project on an isolated VMware Workstation network.

## Verified lab results

The health script returned **8 passing checks** across two domain controllers. Both DNS servers advertised both controllers, both controllers exposed SYSVOL and NETLOGON, and each controller reported successful inbound replication from its peer within the configured two-hour window. The CSV-provisioned account `lab.avery` appeared in the IT OU on both controllers.

The deployment steps below use example network settings. Workstation domain join and interactive sign-in are separate validation steps.

## Lab layout

| VM | Role | Example IPv4 | DNS client settings |
| --- | --- | --- | --- |
| DC01 | First writable domain controller and DNS server | 192.168.77.10/24 | Own IP before promotion. After both DCs replicate, DC02 then its own IP. |
| DC02 | Second writable domain controller and DNS server | 192.168.77.11/24 | DC01 before and during promotion. After replication, DC01 then its own IP. |
| WIN11-01 | Domain-joined Windows 11 Pro or Enterprise client | 192.168.77.20/24 | DC01 then DC02 after both are ready. |

`lab.example.test` and `LAB` are example domain names for this isolated lab. Edit `Lab.psd1` once before deployment and copy the same project folder to both VMs. Use IPs from your actual lab subnet. If you already have an AD forest on DC01 and DC02, set the configuration to match it and begin with the directory preview after confirming both controllers are healthy. Forest creation is for a fresh VM.

Use two Windows Server 2022 or 2025 VMs and a Windows PowerShell 5.1 session. Rename the VMs and restart them before deployment. Connect all three VMs to the same host-only or LAN-segment network. Use static addresses from a range that avoids the virtual network's DHCP pool. A fully isolated segment needs no default gateway. Match the VM clocks and keep VMware console access for reboots. Use lab-only credentials.

## 1. Deploy DC01

On DC01, set its NIC's DNS server to its own static IP. Open an elevated **Windows PowerShell** console inside the VM and change to the extracted project folder. Review the target, then run the promotion. The cmdlet prompts for a Directory Services Restore Mode (DSRM) password and restarts the VM.

```powershell
.\01-Deploy-DomainController.ps1 -Role Primary -WhatIf
.\01-Deploy-DomainController.ps1 -Role Primary
```

After reboot, sign in as a lab domain administrator. Verify that DC01 registers its domain controller service record and publishes its shares.

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName
Resolve-DnsName _ldap._tcp.dc._msdcs.lab.example.test -Type SRV -Server 192.168.77.10
Get-SmbShare -Name SYSVOL, NETLOGON
```

## 2. Deploy DC02

On DC02, set the NIC's DNS server to DC01's IP. Run the second promotion from an elevated Windows PowerShell console on DC02. Supply a lab domain administrator credential and a DSRM password when prompted.

```powershell
.\01-Deploy-DomainController.ps1 -Role Secondary -WhatIf
.\01-Deploy-DomainController.ps1 -Role Secondary
```

After reboot, run `repadmin /showrepl` and `repadmin /replsummary` on DC01. Confirm both controllers replicate successfully and publish their AD DNS records before applying the post-replication DNS settings from the layout table.

## 3. Provision the directory

On DC01, use a lab administrator account or an account delegated to create the objects and manage the groups in this lab OU. The sample CSV defines three fictional users. The script creates departmental security groups, places each user in the corresponding OU, and adds each user to that department's group. The accounts start disabled.

```powershell
.\02-Initialize-LabDirectory.ps1 -WhatIf
.\02-Initialize-LabDirectory.ps1
.\02-Initialize-LabDirectory.ps1
```

| Expected result with the sample data | OUs created | Groups created | Users created | Memberships added |
| --- | ---: | ---: | ---: | ---: |
| First run against an empty lab OU | 7 | 3 | 3 | 3 |
| Second run | 0 | 0 | 0 | 0 |

The script sends all directory reads and writes to DC01. Run a single provisioning session at a time. If a run stops midway, fix the reported error and rerun against the same server to complete missing objects or memberships. For existing identities, the script checks the expected path and sign-in name before assignment. Treat a CSV department change as a separate move and access review for that account.

To prepare one user for the workstation sign-in test, run the following on DC01. Choose a unique temporary password that satisfies the domain's password policy. Wait for replication before signing in if the client uses DC02.

```powershell
$tempPassword = Read-Host 'Temporary password for lab.avery' -AsSecureString
Set-ADAccountPassword -Identity lab.avery -Reset -NewPassword $tempPassword
Set-ADUser -Identity lab.avery -ChangePasswordAtLogon $true
Enable-ADAccount -Identity lab.avery
Remove-Variable tempPassword
```

## 4. Join and test WIN11-01

Set the Windows client to use DC01 and DC02 for DNS. Save any open work, then run the join command in an elevated Windows PowerShell console on the client. Supply an account authorized to join computers in the lab. The VM restarts.

```powershell
Add-Computer -DomainName lab.example.test -Credential (Get-Credential) -Restart
```

Sign in from the VM console as `LAB\lab.avery` and change the temporary password when prompted. Verify the identity and group membership with `whoami` and `whoami /groups`. From an elevated Windows PowerShell session on WIN11-01, run `Test-ComputerSecureChannel -Verbose` and expect `True`. If you want to organize the workstation under the lab OU, move its computer object into **Homelab > Workstations** in Active Directory Users and Computers.

## 5. Run health checks and collect evidence

Run on DC01 after replication has had time to complete. With the sample data, expect eight passing checks. Each DC is queried for the shared SRV records, SYSVOL and NETLOGON accessibility, recent inbound domain-partition replication from its peer, and the same sample account. The script writes `LabHealth.csv` before reporting any failed checks.

```powershell
.\03-Test-LabHealth.ps1
repadmin /replsummary
```

| If a check fails | Inspect |
| --- | --- |
| Client cannot locate the domain | Verify the adapter lists only lab DNS servers. Query the SRV name in step 1 against the DC IPs. |
| DC02 lacks shares or the sample account | Check `repadmin /showrepl DC02`, the Directory Service and DFS Replication logs, and DNS and clock settings on both VMs. |
| Replication succeeds but is older than the report threshold | Check the last successful replication time in `repadmin /showrepl`. Use `-MaxReplicationAgeHours` if your lab's replication schedule requires a different threshold. |
| Account sign-in fails | Confirm the sample account is enabled and its password change has reached the authenticating DC. |
| Preview fails before listing actions | Check the exact VM name for promotion, and verify the configured DC is reachable and the AD PowerShell module is present for provisioning. |

For a portfolio walkthrough, capture your first and second provisioning summaries, the replication summary, and the successful workstation secure-channel result. Include your actual outcome and one issue you encountered and resolved. Keep lab passwords and generated health reports out of public copies.

**Portfolio description to use after deployment:** Built a two-domain-controller Windows Server lab in VMware Workstation. Automated AD DS deployment and CSV-driven provisioning of organizational units, security groups, and user accounts with PowerShell. Verified DNS service records, replication, workstation domain join, and user sign-in.

## Microsoft references

- [Install Active Directory Domain Services on Windows Server](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/install-active-directory-domain-services--level-100-)
- [DNS client settings for domain controllers and domain members](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/best-practices-for-dns-client-settings)
- [Get-ADReplicationPartnerMetadata](https://learn.microsoft.com/en-us/powershell/module/activedirectory/get-adreplicationpartnermetadata)
- [Test-ComputerSecureChannel](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/test-computersecurechannel?view=powershell-5.1)
