#!/bin/bash
# collector.sh — zebranie metryk dla analizy
# Użycie: bash collector.sh 2>&1 | tee server_report.txt

SEP="=========================================="

echo "$SEP"; echo "=== SYSTEM INFO ==="; echo "$SEP"
uname -a; hostname -f; uptime; echo "vCPU: $(nproc)"

echo "$SEP"; echo "=== LOAD & CPU ==="; echo "$SEP"
cat /proc/loadavg
vmstat 1 3

echo "$SEP"; echo "=== MEMORY ==="; echo "$SEP"
free -h
cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty'

echo "$SEP"; echo "=== DISK ==="; echo "$SEP"
df -hT --exclude-type=tmpfs --exclude-type=devtmpfs
df -i --exclude-type=tmpfs

echo "$SEP"; echo "=== I/O ==="; echo "$SEP"
iostat -xz 1 3 2>/dev/null || echo "iostat unavailable (install sysstat)"

echo "$SEP"; echo "=== TOP PROCESSES CPU ==="; echo "$SEP"
ps aux --sort=-%cpu | head -11

echo "$SEP"; echo "=== TOP PROCESSES MEM ==="; echo "$SEP"
ps aux --sort=-%mem | head -11

echo "$SEP"; echo "=== NETWORK ==="; echo "$SEP"
ss -s
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

echo "$SEP"; echo "=== FAILED SERVICES ==="; echo "$SEP"
systemctl --failed 2>/dev/null

echo "$SEP"; echo "=== DMESG ERRORS ==="; echo "$SEP"
dmesg -T --level=err,crit,alert,emerg 2>/dev/null | tail -20

echo "$SEP"; echo "=== JOURNAL ERRORS (1h) ==="; echo "$SEP"
journalctl -p err --since "1h ago" --no-pager 2>/dev/null | tail -30

echo "$SEP"; echo "=== OOM CHECK ==="; echo "$SEP"
dmesg -T 2>/dev/null | grep -i 'oom\|killed process' | tail -10

echo "$SEP"; echo "=== OPEN FILES ==="; echo "$SEP"
cat /proc/sys/fs/file-nr
lsof -n 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

echo "Done. Paste this output to Claude for analysis."
