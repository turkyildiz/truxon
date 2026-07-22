---
name: prepass-toll-api
description: PrePass Toll Transaction API details for the Truxon tolls integration
metadata: 
  node_type: memory
  type: reference
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

PrePass developer portal: developer.prepass.com (also an FTP delivery option). Tolls integration for [[project-truxon]]. Unlike AtoB (browser-scraped), PrePass is a real REST API → the toll sync can run SERVERLESS (Supabase edge function + pg_cron), no NAS needed.

**Auth — Token API v1:** obtain a bearer token from client ID + secret (OAuth client-credentials). Base host `api.prepass.com`. Confirm exact token URL from the portal at deploy time; the user provides PREPASS_CLIENT_ID / PREPASS_CLIENT_SECRET / PREPASS_ACCOUNT_NUMBERS as secrets.

**Toll Transaction API v1:** `GET https://api.prepass.com/tolltransaction/v1/transactions?startPostDate=&endPostDate=&accountNumbers=&pageNumber=&pageSize=`
- startPostDate required (yyyy-mm-dd, <2yr old); at least one accountNumbers OR costCenters (not both); pageSize default/max 10000.
- Response: `pageInfo{pageNumber,pageSize,totalRecords,totalPages}` + `transactions[]`:
  tollId (dedup key), accountNumber/Name, billToAccountNumber/Name, postDateTime, invoiceDateTime,
  deviceNumber, vehicleNumber (Customer's unique vehicle id → match Truxon trucks.unit_number),
  plateNumber, tollAgencyName, tollAgencyState (jurisdiction), billingAgencyCode,
  entryDateTime, entryPlazaCode/Name, readType (Plate/Device), exitDateTime (local, yyyy-mm-ddTHH:mm:ss),
  exitPlazaCode/Name, tollClass, tollCharge (money, string), tollCategory (Normal/Violation),
  disputeStatus (In Dispute / Closed/Complete).

Also available: Account API v1, Fleet Management API v2, GPS Data API v2, Violation Prevention API v1.
