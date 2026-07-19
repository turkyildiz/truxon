"""Stream every object in the Supabase storage buckets to stdout as an
uncompressed tar archive (stdlib only — runs in a bare python container).
Objects are stored under <bucket>/<path> inside the tar so a restore can tell
the buckets apart.

Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
     BACKUP_BUCKETS  (optional, comma-separated; default "documents,personal,team")
"""

import io
import json
import os
import sys
import tarfile
import time
import urllib.parse
import urllib.request

BASE = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
BUCKETS = [b.strip() for b in os.environ.get("BACKUP_BUCKETS", "documents,personal,team").split(",") if b.strip()]


def request(url: str, data: bytes | None = None) -> bytes:
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Authorization": f"Bearer {KEY}", "apikey": KEY, "Content-Type": "application/json"},
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def list_objects(bucket: str, prefix: str = "") -> list[str]:
    """Recursively list object paths under a prefix within a bucket."""
    paths: list[str] = []
    offset = 0
    while True:
        body = json.dumps({"prefix": prefix, "limit": 1000, "offset": offset}).encode()
        entries = json.loads(request(f"{BASE}/storage/v1/object/list/{bucket}", body))
        if not entries:
            break
        for entry in entries:
            name = f"{prefix}{entry['name']}" if not prefix else f"{prefix}/{entry['name']}"
            if entry.get("id") is None:  # folder
                paths.extend(list_objects(bucket, name))
            else:
                paths.append(name)
        if len(entries) < 1000:
            break
        offset += 1000
    return paths


def main() -> None:
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as tar:
        for bucket in BUCKETS:
            try:
                paths = list_objects(bucket)
            except urllib.error.HTTPError as exc:
                # A bucket that doesn't exist yet shouldn't fail the whole backup.
                print(f"skipping bucket {bucket}: {exc}", file=sys.stderr)
                continue
            print(f"backing up {len(paths)} objects from {bucket}", file=sys.stderr)
            for path in paths:
                # Object names can contain spaces, (), #, … — percent-encode each
                # path segment (keep the / separators) or urllib rejects the URL.
                enc = urllib.parse.quote(path, safe="/")
                data = request(f"{BASE}/storage/v1/object/{bucket}/{enc}")
                info = tarfile.TarInfo(name=f"{bucket}/{path}")
                info.size = len(data)
                info.mtime = int(time.time())
                tar.addfile(info, io.BytesIO(data))


if __name__ == "__main__":
    main()
