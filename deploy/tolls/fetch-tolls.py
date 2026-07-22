#!/usr/bin/env python3
# PrePass toll importer (runs on the NAS in a python+paramiko container).
# PrePass delivers CSV files over SFTP; this pulls any NEW files, maps the
# PrePass columns to the import_toll_transactions RPC shape, and posts them to
# the toll-sync edge function (mode: import_rows) which does dedup + truck
# matching (EquipID == unit_number) + violation counting server-side.
#
# Idempotent two ways: processed filenames are recorded in state.json so a file
# is parsed once, AND the RPC dedups on toll_id even if state is lost. Secrets
# live in tolls.env (chmod 600): SFTP creds + TOLL_SYNC_KEY + SUPABASE_* .
import csv, hashlib, io, json, os, sys, urllib.request, datetime, paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
def load_env(p):
    env = {}
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1); env[k] = v
    return env
ENV = {**load_env(os.path.join(HERE, 'tolls.env')), **os.environ}
SFTP = json.load(open(os.path.join(HERE, 'prepass_sftp.json')))
STATE_PATH = os.path.join(HERE, 'state.json')

def log(m): print(f"[tolls] {datetime.datetime.utcnow().isoformat()} {m}", flush=True)

# PrePass agency code -> US state (extend as new agencies appear; unknown = '')
AGENCY_STATE = {
    'ILTOLL': 'IL', 'INTOLL': 'IN', 'OHTPK': 'OH', 'OTA': 'OK', 'KTA': 'KS',
    'NTTA': 'TX', 'HCTRA': 'TX', 'TXDOT': 'TX', 'PTC': 'PA', 'NJTPK': 'NJ',
    'NYSTA': 'NY', 'MDTA': 'MD', 'FLTPK': 'FL', 'SUNPASS': 'FL', 'ISTHA': 'IL', 'BATA': 'CA', 'GGB': 'CA', 'CFX': 'FL', 'THEATOLL': 'TX',
}

def ts(date_s, time_s=''):
    date_s = (date_s or '').strip(); time_s = (time_s or '').strip()
    if not date_s: return None
    for fmt in ('%m/%d/%y', '%Y-%m-%d', '%m/%d/%Y'):
        try:
            d = datetime.datetime.strptime(date_s, fmt)
            if time_s:
                for tf in ('%H:%M:%S', '%H:%M'):
                    try: t = datetime.datetime.strptime(time_s, tf); d = d.replace(hour=t.hour, minute=t.minute, second=t.second); break
                    except ValueError: pass
            return d.isoformat()
        except ValueError: continue
    return None

def num(v):
    v = (v or '').replace('$', '').replace(',', '').strip()
    try: return float(v)
    except ValueError: return 0.0

def map_row(r, acct_name):
    agency = (r.get('Agency') or '').strip()
    # Stable dedup id: PrePass CSV has no native tollId, so hash the fields
    # that uniquely identify one toll event.
    sig = '|'.join([r.get('CustID',''), r.get('PPTagID',''), agency,
                    r.get('Exit_Plaza',''), r.get('Exit_Date',''),
                    r.get('Exit_Time',''), r.get('Toll_Amount','')])
    toll_id = 'pp_' + hashlib.sha256(sig.encode()).hexdigest()[:32]
    return {
        'toll_id': toll_id,
        'account_number': int(r['CustID']) if r.get('CustID','').isdigit() else None,
        'account_name': acct_name,
        'post_date_time': ts(r.get('PostingDate')),
        'invoice_date_time': ts(r.get('InvoiceDate')),
        'exit_date_time': ts(r.get('Exit_Date'), r.get('Exit_Time')),
        'entry_date_time': ts(r.get('Entry_Date'), r.get('Entry_Time')),
        'device_number': (r.get('PPTagID') or '').strip(),
        'vehicle_number': (r.get('EquipID') or '').strip(),
        'plate_number': (r.get('ETagID_Plate') or '').strip(),
        'toll_agency_name': agency,
        'toll_agency_state': AGENCY_STATE.get(agency.upper(), ''),
        'read_type': (r.get('ReadType') or '').strip(),
        'toll_class': (r.get('Toll_Class') or '').strip(),
        'toll_charge': num(r.get('Toll_Amount')),
        'toll_category': 'Violation' if (r.get('Source','').lower().find('viol') >= 0) else 'Normal',
        'entry_plaza_name': (r.get('Entry_Plaza') or '').strip(),
        'exit_plaza_name': (r.get('Exit_Plaza') or '').strip(),
        'raw': r,
    }

def post_rows(rows):
    url = ENV['SUPABASE_URL'].rstrip('/') + '/functions/v1/toll-sync'
    body = json.dumps({'mode': 'import_rows', 'rows': rows}).encode()
    req = urllib.request.Request(url, data=body, headers={
        'Content-Type': 'application/json',
        'apikey': ENV['SUPABASE_ANON_KEY'],
        'Authorization': 'Bearer ' + ENV['SUPABASE_ANON_KEY'],
        'X-Toll-Key': ENV['TOLL_SYNC_KEY'],
    })
    return json.loads(urllib.request.urlopen(req, timeout=60).read())

def main():
    state = json.load(open(STATE_PATH)) if os.path.exists(STATE_PATH) else {'done': []}
    done = set(state.get('done', []))
    # Host-key pinning (review M-5): encrypted-but-unauthenticated SFTP lets a
    # MITM harvest the password and feed forged toll CSVs into the financials.
    # PREPASS_HOSTKEY (tolls.env) = "<type> <base64>" from ssh-keyscan; we fail
    # closed on absence or mismatch.
    pin = ENV.get('PREPASS_HOSTKEY', '').strip()
    if not pin:
        raise SystemExit('PREPASS_HOSTKEY missing from tolls.env — refusing unauthenticated SFTP')
    pin_type, pin_b64 = pin.split()[:2]
    t = paramiko.Transport((SFTP['host'], SFTP['port']))
    t.start_client(timeout=30)
    got = t.get_remote_server_key()
    if got.get_name() != pin_type or got.get_base64() != pin_b64:
        t.close()
        raise SystemExit(f'PrePass host key MISMATCH ({got.get_name()}) — possible MITM, aborting')
    t.auth_password(username=SFTP['user'], password=SFTP['pass'])
    s = paramiko.SFTPClient.from_transport(t)
    files = [f for f in s.listdir('.') if f.lower().endswith('.csv')]
    new = [f for f in files if f not in done]
    log(f"{len(files)} csv on server, {len(new)} new")
    total_ins = total_upd = total_unm = 0
    for fn in sorted(new):
        buf = io.BytesIO(); s.getfo(fn, buf); text = buf.getvalue().decode('utf-8-sig')
        acct_name = fn.split('_')[1] if '_' in fn else ''
        rows = [map_row(r, acct_name) for r in csv.DictReader(io.StringIO(text))]
        rows = [r for r in rows if r['toll_charge'] or r['exit_date_time']]
        if not rows: log(f"{fn}: 0 usable rows"); done.add(fn); continue
        res = post_rows(rows)
        if res.get('error'): log(f"{fn}: ERROR {res['error']}"); continue  # retry next run
        ins, upd, unm = res.get('inserted',0), res.get('updated',0), res.get('unmatched_trucks',0)
        total_ins += ins; total_upd += upd
        log(f"{fn}: {len(rows)} rows -> +{ins} new, {upd} updated, {res.get('violations',0)} violations")
        done.add(fn)
    t.close()
    state['done'] = sorted(done); json.dump(state, open(STATE_PATH, 'w'))
    log(f"done: +{total_ins} new tolls this run")

if __name__ == '__main__':
    try: main()
    except Exception as e:
        log(f"FATAL: {e}"); sys.exit(1)
