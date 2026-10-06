#!/bin/bash
# 启用 ACL 策略：部署 acl.hujson + config 加 policy 段 + 重启 headscale
set -e
cp /mnt/c/headscale-certs/acl_baseline.hujson /etc/headscale/acl.hujson
if ! grep -q '^policy:' /etc/headscale/config.yaml; then
  printf '\npolicy:\n  mode: file\n  path: /etc/headscale/acl.hujson\n' >> /etc/headscale/config.yaml
fi
grep -A2 '^policy:' /etc/headscale/config.yaml
pkill -x headscale || true
sleep 1
echo "restarted-by-acl-enable" >> /var/log/headscale-keepalive.log
