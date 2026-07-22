#!/bin/sh
# JadePuffer/ENCFORGE IOC egress+ingress block. Run on the NAS with sudo.
# These are the known command-and-control / exfil-staging IPs from the Sysdig
# JadePuffer report (2026-07). Blocking them is safe — nothing legitimate on
# the NAS talks to them. Attackers rotate IPs, so this is a tripwire/quick-win,
# not a substitute for the DB ransomware guard and immutable backups.
#
# Usage:  sudo sh deploy/security/ioc-block.sh
# Persist across reboot on Synology: add this line to
#   Control Panel > Task Scheduler > Triggered Task (Boot) > root
set -eu

IOCS="45.131.66.106 64.20.53.230"   # C2/beacon, exfil-staging
for ip in $IOCS; do
  iptables -C OUTPUT -d "$ip" -j DROP 2>/dev/null || iptables -I OUTPUT -d "$ip" -j DROP
  iptables -C INPUT  -s "$ip" -j DROP 2>/dev/null || iptables -I INPUT  -s "$ip" -j DROP
  echo "blocked $ip (in+out)"
done
echo "done. Verify: iptables -L OUTPUT -n | grep -E '45.131.66.106|64.20.53.230'"
