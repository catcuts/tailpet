#!/bin/bash
# headscale keepalive: 进程不在 → 拉起；进程在但 /health 不响应（假死）→ 强杀重启
LOG=/var/log/headscale-keepalive.log
START="setsid nohup headscale serve --config /etc/headscale/config.yaml </dev/null >> /var/log/headscale.log 2>&1 &"

if ! pgrep -x headscale > /dev/null; then
    echo "===== $(date -u '+%F %T') headscale down, starting =====" >> $LOG
    eval "$START"
    sleep 2
    pgrep -x headscale >> $LOG
elif ! curl -sk --noproxy '*' -m 8 https://127.0.0.1:443/health 2>/dev/null | grep -q '"status":"pass"'; then
    echo "===== $(date -u '+%F %T') headscale WEDGED (alive but unhealthy), force restart =====" >> $LOG
    pkill -9 -x headscale
    sleep 1
    eval "$START"
    sleep 2
    pgrep -x headscale >> $LOG
fi
