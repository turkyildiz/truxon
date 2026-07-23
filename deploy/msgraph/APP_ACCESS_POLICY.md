# Scope the Truxon Graph app to its two mailboxes

**Why:** the app registration behind Forest's mail (trux-inbox, invoice-send,
watchdog reminders, dispatch shadow) holds tenant-wide `Mail.Read`/`Mail.Send`
application permissions — it can read EVERY mailbox in the tenant. That is how
the fresh forest@ mailbox worked with zero consent (convenient, but the exposure
runs the other way too). An Exchange **Application Access Policy** restricts the
app to exactly `forest@truxon.com` + `dispatch@truxon.com`. One-time, ~5 minutes,
reversible.

**Needs:** Exchange admin. Run in [Azure Cloud Shell](https://shell.azure.com)
(PowerShell) or any PowerShell with `ExchangeOnlineManagement`.

```powershell
Connect-ExchangeOnline

# 1. Mail-enabled security group that defines the app's reach
New-DistributionGroup -Name "Truxon Graph Scope" -Alias truxon-graph-scope `
  -Type Security -PrimarySmtpAddress truxon-graph-scope@truxon.com
Add-DistributionGroupMember -Identity truxon-graph-scope -Member forest@truxon.com
Add-DistributionGroupMember -Identity truxon-graph-scope -Member dispatch@truxon.com

# 2. Restrict the app (AppId = the Graph app's client id — Azure portal →
#    App registrations → the Truxon/Forest app → Application (client) ID;
#    same value as the msgraph client id in Supabase edge secrets)
New-ApplicationAccessPolicy -AppId <CLIENT_ID> `
  -PolicyScopeGroupId truxon-graph-scope@truxon.com `
  -AccessRight RestrictAccess `
  -Description "Forest: mail access limited to forest@ + dispatch@"

# 3. Prove it (expect Granted, Granted, Denied)
Test-ApplicationAccessPolicy -Identity forest@truxon.com   -AppId <CLIENT_ID>
Test-ApplicationAccessPolicy -Identity dispatch@truxon.com -AppId <CLIENT_ID>
Test-ApplicationAccessPolicy -Identity <any-other-user>@truxon.com -AppId <CLIENT_ID>
```

Policy takes effect within ~30 minutes. **After it lands, verify Forest still
works:** trux-inbox poll succeeds (staff door), an invoice-send test goes out,
and the dispatch shadow's next 20-min cycle reads dispatch@ cleanly — all three
run against the two allowed mailboxes, so nothing should change. If anything
breaks: `Remove-ApplicationAccessPolicy -Identity <policy id>` reverts
instantly (`Get-ApplicationAccessPolicy` lists ids).
