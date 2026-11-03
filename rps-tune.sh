#!/usr/bin/env bash
#
# rps-tune - spread incoming packet processing across all CPU cores
#
# Many VPS network cards (virtio_net and others) expose a single RX queue, so
# every incoming packet is processed by the one core that takes its
# interrupt; under load that core adds latency and jitter. RPS hands packets
# to all cores by flow hash, and RFS steers each flow to the core where the
# application thread reading it (Xray) runs. NICs with at least one RX queue
# per core already spread the load in hardware and are left alone.
#
# Requires Linux with systemd; run as root.
#
#   bash rps-tune.sh install   apply now and at every boot
#   rps-tune status            settings and per-core packet load
#   rps-tune remove            back to kernel defaults

set -Eeuo pipefail
export LC_ALL=C

readonly PROG="rps-tune"
readonly SELF_BIN="/usr/local/sbin/rps-tune"
readonly UNIT="/etc/systemd/system/rps-tune.service"
readonly SYSCTL_FILE="/etc/sysctl.d/90-rps-tune.conf"
readonly FLOW_ENTRIES=32768

ok()  { printf '[+] %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }
trap 'die "Unexpected error at line $LINENO: $BASH_COMMAND"' ERR

require_root() { [[ $EUID -eq 0 ]] || die "Run as root"; }

# Interfaces carrying the default route; physical interfaces if there is none yet.
uplinks() {
  local l
  l=$({ ip -4 route show default; ip -6 route show default; } 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u)
  if [[ -z $l ]]; then
    l=$(for d in /sys/class/net/*/device; do basename "${d%/device}"; done 2>/dev/null)
  fi
  printf '%s\n' "$l"
}

# Mask of all online CPUs in sysfs format: 32-bit hex groups, highest first.
cpu_mask() {
  local n=$1 i bits mask=""
  for ((i = 0; i * 32 < n; i++)); do
    bits=$((n - i * 32 > 32 ? 32 : n - i * 32))
    mask=$(printf '%08x' $(((1 << bits) - 1)))${mask:+,$mask}
  done
  printf '%s\n' "$mask"
}

cpus() { getconf _NPROCESSORS_ONLN; }

# set_queues <rps_cpus> <rps_flow_cnt per queue|"split"> : on every uplink
# that has fewer RX queues than cores.
set_queues() {
  local ifc q n per
  local -a qs
  n=$(cpus)
  for ifc in $(uplinks); do
    qs=(/sys/class/net/"$ifc"/queues/rx-*)
    [[ -e ${qs[0]} ]] || continue
    if ((${#qs[@]} >= n)); then
      ok "$ifc: ${#qs[@]} hardware RX queues for $n cores, RPS not needed"
      continue
    fi
    per=$2
    if [[ $per == split ]]; then per=$((FLOW_ENTRIES / ${#qs[@]})); fi
    for q in "${qs[@]}"; do
      echo "$1" >"$q/rps_cpus"
      echo "$per" >"$q/rps_flow_cnt"
    done
    ok "$ifc: ${#qs[@]} RX queue(s), rps_cpus=$1, rps_flow_cnt=$per"
  done
}

cmd_apply() {
  require_root
  sysctl -q -w net.core.rps_sock_flow_entries=$FLOW_ENTRIES
  set_queues "$(cpu_mask "$(cpus)")" split
}

cmd_install() {
  require_root
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  [[ -f $src ]] || die "Save the script to a file and run it from there"
  if [[ $src != "$SELF_BIN" ]]; then install -m 755 "$src" "$SELF_BIN"; fi
  printf '# %s: flow table for RFS\nnet.core.rps_sock_flow_entries = %s\n' "$PROG" "$FLOW_ENTRIES" >"$SYSCTL_FILE"
  cat >"$UNIT" <<EOF
[Unit]
Description=$PROG: spread incoming packet processing across all CPU cores
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF_BIN apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$PROG.service" >/dev/null 2>&1
  cmd_apply
  systemctl start "$PROG.service"
  ok "Installed; applied now and at every boot"
}

cmd_remove() {
  require_root
  systemctl disable --now "$PROG.service" >/dev/null 2>&1 || true
  set_queues 0 0
  sysctl -q -w net.core.rps_sock_flow_entries=0
  rm -f "$UNIT" "$SYSCTL_FILE" "$SELF_BIN"
  systemctl daemon-reload
  ok "Removed; RPS/RFS back to kernel defaults (off)"
}

cmd_status() {
  local ifc q a b
  printf 'net.core.rps_sock_flow_entries = %s\n' "$(sysctl -n net.core.rps_sock_flow_entries)"
  for ifc in $(uplinks); do
    for q in /sys/class/net/"$ifc"/queues/rx-*; do
      [[ -e $q ]] || continue
      printf '%s %s: rps_cpus=%s rps_flow_cnt=%s\n' "$ifc" "${q##*/}" "$(cat "$q/rps_cpus")" "$(cat "$q/rps_flow_cnt")"
    done
  done
  printf 'Per-core load over 5s:\n'
  a=$(grep -E '^cpu[0-9]' /proc/stat)
  sleep 5
  b=$(grep -E '^cpu[0-9]' /proc/stat)
  paste <(echo "$a") <(echo "$b") | awk '{
    n = NF / 2; tot = 0
    for (i = 2; i <= n; i++) { d[i] = $(i + n) - $i; tot += d[i] }
    printf "  %-5s packet processing (softirq) %5.1f%%   busy %5.1f%%\n", $1, 100 * d[8] / tot, 100 * (tot - d[5] - d[6]) / tot
  }'
}

case ${1:-} in
  install) cmd_install ;;
  apply)   cmd_apply ;;
  status)  cmd_status ;;
  remove)  cmd_remove ;;
  *)       printf 'Usage: %s install | apply | status | remove\n' "$PROG" >&2; exit 2 ;;
esac
