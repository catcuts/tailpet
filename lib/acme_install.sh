#!/bin/bash
# acme.sh 安装 + 证书签发（Let's Encrypt + DuckDNS DNS-01）
# 用法: bash acme_install.sh <域名> <邮箱> <duckdns_token> [staging|prod]
set -e
DOMAIN="$1"; EMAIL="$2"; TOKEN="$3"; MODE="${4:-prod}"
export DuckDNS_Token="$TOKEN"
export http_proxy=http://127.0.0.1:10808 https_proxy=http://127.0.0.1:10808
CERT_DIR=/mnt/c/headscale-certs/certificates
mkdir -p "$CERT_DIR"

# 1) acme.sh 本体（WSL 无 crontab，手工放两个文件）
if [ ! -f /root/.acme.sh/acme.sh ]; then
  mkdir -p /root/.acme.sh/dnsapi
  # 优先用 A 中转推送的本地文件（/mnt/c/headscale-certs），否则回退在线下载
  if [ -f /mnt/c/headscale-certs/acme.sh ]; then
    cp /mnt/c/headscale-certs/acme.sh /root/.acme.sh/acme.sh
    cp /mnt/c/headscale-certs/dns_duckdns.sh /root/.acme.sh/dnsapi/dns_duckdns.sh
  else
    curl -sL -o /root/.acme.sh/acme.sh https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh
    curl -sL -o /root/.acme.sh/dnsapi/dns_duckdns.sh https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_duckdns.sh
  fi
  chmod +x /root/.acme.sh/acme.sh
fi

# 2) 签发（先 staging 验链路，再 prod；幂等——已有证书则跳过）
SERVER="letsencrypt"
if [ "$MODE" = "staging" ]; then SERVER="letsencrypt_test"; fi
if [ ! -f /root/.acme.sh/${DOMAIN}_ecc/fullchain.cer ]; then
  /root/.acme.sh/acme.sh --issue --server $SERVER --dns dns_duckdns \
    -d "$DOMAIN" --dnssleep 30 --keylength ec-256
fi
# staging→prod 升级：若现有证书实际是 staging 签的而本次要求 prod，强制重签
if [ "$MODE" = "prod" ] && [ -f /root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf ]; then
  if grep -q 'acme-staging' /root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf 2>/dev/null; then
    /root/.acme.sh/acme.sh --issue --server letsencrypt --dns dns_duckdns \
      -d "$DOMAIN" --dnssleep 30 --keylength ec-256 --force
  fi
fi

# 3) 部署到 headscale 证书目录
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file "$CERT_DIR/$DOMAIN.crt" \
  --key-file "$CERT_DIR/$DOMAIN.key"
openssl x509 -in "$CERT_DIR/$DOMAIN.crt" -noout -subject -dates
