"""Stream every object in the Supabase 'documents' storage bucket to stdout
as an uncompressed tar archive (stdlib only — runs in a bare python container).

Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
"""

import io
import json
import os
import sys
import tarfile
import time
import urllib.request

BASE = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
BUCKET = "documents"


def request(url: str, data: bytes | None = None) -> bytes:
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Authorization": f"Bearer {KEY}", "apikey": KEY, "Content-Type": "application/json"},
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def list_objects(prefix: str = "") -> list[str]:
    """Recursively list object paths under a prefix."""
    paths: list[str] = []
    offset = 0
    while True:
        body = json.dumps({"prefix": prefix, "limit": 1000, "offset": offset}).encode()
        entries = json.loads(request(f"{BASE}/storage/v1/object/list/{BUCKET}", body))
        if not entries:
            break
        for entry in entries:
            name = f"{prefix}{entry['name']}" if not prefix else f"{prefix}/{entry['name']}"
            if entry.get("id") is None:  # folder
                paths.extend(list_objects(name))
            else:
                paths.append(name)
        if len(entries) < 1000:
            break
        offset += 1000
    return paths


def main() -> None:
    paths = list_objects()
    print(f"backing up {len(paths)} objects", file=sys.stderr)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as tar:
        for path in paths:
            data = request(f"{BASE}/storage/v1/object/{BUCKET}/{path}")
            info = tarfile.TarInfo(name=path)
            info.size = len(data)
            info.mtime = int(time.time())
            tar.addfile(info, io.BytesIO(data))


if __name__ == "__main__":
    main()
