#!/bin/sh
# PVY-LIMA-UI compatibility shims - FreeBSD port
# Provides Linux-style commands the PVY-LIMA UI executes for its
# metric panels (free, nproc, uptime -p, df --output) on FreeBSD guests.
# Install: sh compat-shims-fbsd.sh   (as root)
# Copyright: PVY.swiss LTD | Author: André Grueter 2026, released under GPL v.3.0
set -e

install_shim() {
    name="$1"; body="$2"
    printf '%s\n' "$body" > "/usr/local/bin/$name"
    chmod 755 "/usr/local/bin/$name"
    echo "installed /usr/local/bin/$name"
}

# free - minimal subset: free -m / free -b (totals + available)
install_shim free '#!/bin/sh
# PVY compat: Linux free subset (FreeBSD sysctl sources)
unit=1; arg=""
for a in "$@"; do case "$a" in
  -b) unit=1 ;; -k) unit=1024 ;; -m) unit=$((1024*1024)) ;; -g) unit=$((1024*1024*1024)) ;;
  -*) : ;; *) arg="$a" ;;
esac; done
ps=$(sysctl -n hw.pagesize)
tot=$(sysctl -n hw.physmem)
fr=$(sysctl -n vm.stats.vm.v_free_count)
in=$(sysctl -n vm.stats.vm.v_inactive_count)
ca=$(sysctl -n vm.stats.vm.v_cache_count)
avail=$(( (fr + in + ca) * ps ))
used=$(( tot - avail ))
if [ "$unit" -gt 1 ]; then
  tot=$(( (tot + unit - 1) / unit )); avail=$(( (avail + unit - 1) / unit )); used=$(( (used + unit - 1) / unit ))
fi
printf "%-15s %12s %12s %12s\n" "" total used available
printf "%-15s %12d %12d %12d\n" "Mem:" "$tot" "$used" "$avail"'

# nproc
install_shim nproc '#!/bin/sh
# PVY compat: Linux nproc
sysctl -n hw.ncpu'

# uptime -p (pretty)
install_shim uptime-p '#!/bin/sh
# PVY compat: uptime -p equivalent
b=$(sysctl -n kern.boottime | sed -E "s/\{ sec = ([0-9]+).*/\1/")
s=$(( $(date +%s) - b ))
d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
printf "up %d days, %d hours, %d minutes\n" "$d" "$h" "$m"'

# uptime wrapper: pass -p to shim, else native uptime
install_shim uptime '#!/bin/sh
# PVY compat: uptime with -p support
for a in "$@"; do
  if [ "$a" = "-p" ]; then exec /usr/local/bin/uptime-p "$@"; fi
done
exec /usr/bin/uptime "$@"'

echo "PVY compat shims installed."
