#!/bin/sh
# PVY-LIMA-UI compatibility shims - FreeBSD port
# Provides Linux-style commands that the PVY-LIMA UI backend executes
# via 'limactl shell <instance> <cmd>' for its metric panels:
#   free -b/-k/-m/-g  (7-column Linux format)
#   df -BG --output=size,used,avail,pcent /  (with header)
#   ps aux --sort=-pcpu  (Linux column layout, sorted by %CPU)
#   hostname -I
#   nproc
#   uptime -p / uptime
# Install: sh compat-shims-fbsd.sh   (as root)
# Copyright: PVY.swiss LTD | Author: André Grueter 2026, released under GPL v.3.0
set -e

install_shim() {
    name="$1"; body="$2"
    printf '%s\n' "$body" > "/usr/local/bin/$name"
    chmod 755 "/usr/local/bin/$name"
    echo "installed /usr/local/bin/$name"
}

# --- free: Linux-compatible 7-column output ---
# UI parses: parts[0]="Mem:" then total used free shared buff/cache available
install_shim free '#!/bin/sh
# PVY compat: Linux free (7 columns) from FreeBSD sysctl
unit=1
for a in "$@"; do case "$a" in
  -b) unit=1 ;; -k) unit=1024 ;; -m) unit=$((1024*1024)) ;; -g) unit=$((1024*1024*1024)) ;;
esac; done
ps=$(sysctl -n hw.pagesize)
tot=$(sysctl -n hw.physmem)
fr=$(sysctl -n vm.stats.vm.v_free_count)
in=$(sysctl -n vm.stats.vm.v_inactive_count)
ca=$(sysctl -n vm.stats.vm.v_cache_count)
la=$(sysctl -n vm.stats.vm.v_laundry_count)
wire=$(sysctl -n vm.stats.vm.v_wire_count)
# Linux "free" = completely unused; FreeBSD free_pages
free_b=$(( fr * ps ))
# Linux "available" = free + reclaimable (inactive + cache)
avail_b=$(( (fr + in + ca) * ps ))
# Linux "used" = total - free - buff/cache (approx via wire + laundry + active part)
used_b=$(( tot - free_b - in * ps - ca * ps ))
if [ "$used_b" -lt 0 ]; then used_b=$(( wire * ps )); fi
cache_b=$(( (in + ca) * ps ))
shared_b=0
round() { if [ "$unit" -gt 1 ]; then echo $(( ($1 + unit - 1) / unit )); else echo "$1"; fi; }
printf "%-7s %15s %15s %15s %15s %15s %15s\n" "" total used free shared buff/cache available
printf "%-7s %15s %15s %15s %15s %15s %15s\n" "Mem:" "$(round $tot)" "$(round $used_b)" "$(round $free_b)" "$(round $shared_b)" "$(round $cache_b)" "$(round $avail_b)"
printf "%-7s %15s %15s\n" "Swap:" "" ""'

# --- df: Linux -BG --output=size,used,avail,pcent (with header) ---
install_shim df '#!/bin/sh
# PVY compat: df wrapper supporting -BG --output=size,used,avail,pcent
args=""
for a in "$@"; do
  case "$a" in
    --output=*) ;; # recognized, handled below
    -BG|-G) ;;     # recognized: we always report GB
    *) args="$args $a" ;;
  esac
done
out=$(/bin/df -g $args)
fs=$(echo "$out" | tail -1 | awk "{print \$1}")
printf "%-6s %6s %6s %6s %6s %s\n" "Size" "Used" "Avail" "Use%" "" ""
/bin/df -g $args | tail -1 | awk "{printf \"%-6s %6s %6s %6s %6s\\n\", \$2, \$3, \$4, \$5, \$6}"'

# --- ps: Linux aux --sort=-pcpu (kernel threads filtered, as on Linux) ---
install_shim ps '#!/bin/sh
# PVY compat: ps wrapper; supports "aux --sort=-pcpu" (Linux syntax).
# Kernel threads ([idle], [intr], ...) are filtered - Linux userland ps
# does not list them either; showing them confuses CPU rankings.
for a in "$@"; do
  if [ "$a" = "--sort=-pcpu" ]; then
    /bin/ps ax -o user,pid,pcpu,pmem,vsz,rss,tty,stat,start,time,command | awk "NR==1 || \$11 !~ /^\\[/"
    /bin/ps ax -o user,pid,pcpu,pmem,vsz,rss,tty,stat,start,time,command | tail -n +2 | awk "\$11 !~ /^\\[/" | sort -k3 -rn | head -50
    exit 0
  fi
done
exec /bin/ps "$@"'

# --- hostname: Linux -I (all IPs, IP-tokens only - filters any noise) ---
install_shim hostname '#!/bin/sh
# PVY compat: hostname with Linux -I flag; emits IPv4 tokens only
for a in "$@"; do
  if [ "$a" = "-I" ]; then
    ifconfig -a | awk "\$1==\"inet\" && \$2 !~ /^127\./ {print \$2}" | grep -E "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$" | tr "\\n" " " | sed "s/ $//"
    echo
    exit 0
  fi
done
exec /bin/hostname "$@"'

# --- nproc ---
install_shim nproc '#!/bin/sh
# PVY compat: Linux nproc
sysctl -n hw.ncpu'

# --- uptime: Linux -p pretty ---
install_shim uptime-p '#!/bin/sh
# PVY compat: uptime -p equivalent
b=$(sysctl -n kern.boottime | sed -E "s/\{ sec = ([0-9]+).*/\1/")
s=$(( $(date +%s) - b ))
d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
printf "up %d days, %d hours, %d minutes\n" "$d" "$h" "$m"'

install_shim uptime '#!/bin/sh
# PVY compat: uptime with -p support
for a in "$@"; do
  if [ "$a" = "-p" ]; then exec /usr/local/bin/uptime-p "$@"; fi
done
exec /usr/bin/uptime "$@"'

echo "PVY compat shims installed."
