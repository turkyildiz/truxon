# Pinned rsync+ssh image for the offsite (INDIANCREEK) replication leg of the
# nightly backup. backup.sh runs inside the docker:cli (Alpine) scheduler
# container, which ships ssh but NOT rsync — so the offsite rsync silently
# failed ("rsync: command not found") every night after containerization
# (found 2026-07-23 DR drill). Rather than apk-install at every run (the
# anti-pattern this repo already retired for truxon-tolls/truxon-vision), the
# offsite step now runs as a sibling `docker run` off this pinned image, the
# same way pg_dump (postgres:17-alpine) and the B2 upload (amazon/aws-cli) do.
#
# Build on the NAS:  docker build -t truxon-offsite-rsync:1 deploy/backup/offsite-rsync
FROM alpine:3.21
RUN apk add --no-cache rsync openssh-client
# ssh refuses a private key not owned by the running uid, and getpwuid() must
# resolve — so bake a uid-1000 user (the host key owner, turkyildiz) with a
# real home. backup.sh runs this image with --user 1000:1000.
RUN adduser -D -u 1000 -h /home/offsite offsite
ENTRYPOINT []
