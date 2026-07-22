# Toll-fetch image: python + a PINNED paramiko (handles the SFTP host-key +
# secret path, so its version must not float — M-7). Built once on the NAS:
#   docker build -t truxon-tolls /volume1/docker/truxon-tolls
# Then run-tolls.sh picks it up via TOLLS_IMAGE=truxon-tolls and does NO runtime
# pip install at all. Rebuild deliberately (with a reviewed requirements bump).
FROM python:3.11-slim
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
WORKDIR /w
