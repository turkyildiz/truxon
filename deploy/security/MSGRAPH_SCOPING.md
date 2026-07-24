# Scope the Microsoft Graph app to just forest@ + dispatch@

**Why:** the Truxon Graph app (client id = edge secret `MSGRAPH_CLIENT_ID`) holds
**tenant-wide** application permissions (`Mail.Read` / `Mail.Send`), so it *could*
read/send as any mailbox in the tenant. It only ever uses two:
`forest@truxon.com` (inbox mining, Forest replies, invoice-send, reminders) and
`dispatch@aidalogistics.com` (dispatch-watch). An **Application Access Policy**
restricts the app to exactly those two — least privilege, no code change.

**You run this** (Exchange admin). Claude can't — it needs your admin session
and the app id. ~10 min + up to 30 min propagation.

## Steps (Exchange Online PowerShell)
```powershell
# 1. Connect (as an Exchange admin)
Install-Module ExchangeOnlineManagement -Scope CurrentUser   # first time only
Connect-ExchangeOnline

# 2. A mail-enabled security group holding ONLY the two service mailboxes
New-DistributionGroup -Name "Truxon-Graph-Scope" -Type Security `
  -PrimarySmtpAddress truxon-graph-scope@aidalogistics.com `
  -Members forest@truxon.com,dispatch@aidalogistics.com

# 3. The access policy — restrict the app to that group. Put your real AppId in.
#    AppId = MSGRAPH_CLIENT_ID (Supabase edge secret / Azure → App registrations).
New-ApplicationAccessPolicy -AppId <MSGRAPH_CLIENT_ID> `
  -PolicyScopeGroupId truxon-graph-scope@aidalogistics.com `
  -AccessRight RestrictAccess `
  -Description "Truxon app limited to forest@ + dispatch@"

# 4. Verify: the two mailboxes GRANTED, everyone else DENIED
Test-ApplicationAccessPolicy -AppId <MSGRAPH_CLIENT_ID> -Identity forest@truxon.com          # Granted
Test-ApplicationAccessPolicy -AppId <MSGRAPH_CLIENT_ID> -Identity dispatch@aidalogistics.com # Granted
Test-ApplicationAccessPolicy -AppId <MSGRAPH_CLIENT_ID> -Identity <any-other-user>           # Denied
```

## After (Claude verifies)
Once propagated (~30 min), tell Claude — it re-checks that mail still flows:
trux-inbox poll reaches forest@, invoice-send works, dispatch-watch reads
dispatch@. If a call starts 403-ing `ErrorAccessDenied`, the scope group is
missing that mailbox — add it with `Add-DistributionGroupMember`.

## Caveats
- `forest@truxon.com` and `dispatch@aidalogistics.com` must be in the **same
  M365 tenant** for one policy to cover both (they are, if truxon.com is a domain
  on the Aida tenant). If truxon.com is a separate tenant, each needs its own
  policy under that tenant's app registration.
- Application Access Policies apply to **application permissions** (app-only,
  `client_credentials`) — which is exactly how this app authenticates. MFA on
  interactive login is unrelated and unaffected.
