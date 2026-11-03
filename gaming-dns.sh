#!/usr/bin/env bash
#
# gaming-dns - lowest-latency DNS for Xray gaming servers
#
# Makes SmartDNS this server's resolver:
#   * every lookup goes to Google and Gcore DNS in parallel,
#   * every IP in the answers is latency-tested from this server
#     (ICMP ping, then TCP 443/80 when ping is blocked),
#   * only the fastest IP(s) are returned.
# By default outgoing DNS queries on UDP port 53 are also redirected to it,
# so Xray's own lookups *and* the DNS queries of connected clients receive
# the IP that is fastest from this server (VPN tunnels on port 53 are not
# touched). A watchdog fails open to the original DNS setup if SmartDNS
# stops answering or keeps returning empty answers.
#
# Requires Debian 11+ / Ubuntu 20.04+ with systemd; run as root.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/Gaming-DNS/main/gaming-dns.sh) install
#   bash gaming-dns.sh install       install (re-run with options to reconfigure)
#   gaming-dns test [domain...]      every IP of a domain, its latency, what Xray gets
#   gaming-dns help                  all commands and options

set -Eeuo pipefail
umask 022
export LC_ALL=C

readonly VERSION="1.1.1"
readonly PROG="gaming-dns"
readonly SELF_BIN="/usr/local/bin/gaming-dns"
readonly CONF_DIR="/etc/gaming-dns"
readonly CONF_FILE="$CONF_DIR/gaming-dns.conf"
readonly STATE_DIR="/var/lib/gaming-dns"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly DEGRADED_FLAG="$STATE_DIR/degraded"
readonly LOCK_FILE="/run/gaming-dns.lock"
readonly SDNS_CONF="/etc/smartdns/smartdns.conf"
readonly SDNS_CACHE_DIR="/var/cache/smartdns"
readonly SDNS_LOG_DIR="/var/log/smartdns"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/90-gaming-dns.conf"
readonly UNIT_DIR="/etc/systemd/system"
readonly SDNS_DROPIN="$UNIT_DIR/smartdns.service.d/90-gaming-dns.conf"
readonly FIREWALL_UNIT="gaming-dns-firewall.service"
readonly OLD_REDIRECT_UNIT="gaming-dns-redirect.service" # name used by 1.0
readonly WATCHDOG_UNIT="gaming-dns-watchdog"
readonly NAT_CHAIN="GAMING_DNS"
readonly RAW_CHAIN="GAMING_DNS_RAW"
readonly FW_MARK="23886"           # SmartDNS marks its upstream queries with this
readonly BYPASS_USER="gaming-dns"  # DNS sent by this user is never redirected
readonly PROBE_NAME="probe.gaming-dns.invalid" # answered locally, for health checks
readonly GH_API="https://api.github.com/repos/pymumu/smartdns/releases/latest"
readonly REPO_RAW="https://raw.githubusercontent.com/xmohammad1/Gaming-DNS/main"
readonly TEST_DOMAINS="api.steampowered.com steamcdn-a.akamaihd.net cdn.discordapp.com download.epicgames.com www.ea.com"

# Settings: persisted in $CONF_FILE, overridable with command-line options.
UPSTREAMS="8.8.8.8 8.8.4.4 95.85.95.85 2.56.220.2"
RESPONSE_MODE="fastest-ip"
SPEED_CHECK="ping,tcp:443,tcp:80"
MAX_IPS="1"
IPV6="auto"
ECS="auto"
REDIRECT="yes"
CACHE_SIZE="65536"
REPLY_TTL="30"

# One-shot options.
DEB_FILE=""
PURGE="auto"
SDNS_CONF_CHANGED=0

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_CYN=$'\e[36m' C_BLD=$'\e[1m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else
  C_RED="" C_GRN="" C_YLW="" C_CYN="" C_BLD="" C_DIM="" C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
row()  { printf '  %-14s %s\n' "$1" "$2"; }

# event <priority> <message>: to the journal, and to the terminal if there is one.
event() {
  logger -t "$PROG" -p "user.$1" -- "$2" 2>/dev/null || true
  if [[ -t 2 ]]; then printf '%s\n' "$2" >&2; fi
  return 0
}

trap 'die "Unexpected error at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
$PROG $VERSION - lowest-latency DNS for Xray gaming servers

Usage: $PROG <command> [options]

Commands:
  install            Install SmartDNS and switch this server to it
                     (re-run with options to change settings)
  apply              Same as install: re-applies $CONF_FILE
  status             Service state, settings and redirect counters
  test [domain...]   Every IP of a domain, its latency and what Xray receives
  redirect on|off    Toggle the transparent redirect of outgoing DNS (UDP 53)
  xray               Print the recommended Xray "dns" and sniffing settings
  update             Upgrade SmartDNS to the latest release
  uninstall          Remove everything and restore the original DNS setup
  health             Watchdog check (run every 30s by $WATCHDOG_UNIT.timer)

Options for install / apply:
  --upstreams LIST   Upstream DNS servers, comma separated
                     (default: 8.8.8.8,8.8.4.4,95.85.95.85,2.56.220.2)
  --mode MODE        fastest-ip (default) | first-ping | fastest-response
  --speed-check STR  Latency probes in order of preference
                     (default: ping,tcp:443,tcp:80)
  --max-ips N        IPs returned per answer, fastest first (default: 1)
  --ipv6 MODE        auto (default) | on | off
  --ecs VALUE        EDNS client subnet: auto (default) | off | <ip/prefix>
  --reply-ttl SEC    Max TTL handed to clients (default: 30)
  --cache-size N     DNS cache entries (default: 65536)
  --no-redirect      Only change the system resolver, leave UDP 53 traffic alone
  --redirect         Re-enable the redirect
  --deb FILE         Install SmartDNS from a local .deb (servers without GitHub)

Options for uninstall:
  --purge            Also remove the SmartDNS package (default if $PROG installed it)
  --keep-smartdns    Keep the SmartDNS package installed
EOF
}

# ---------------------------------------------------------------- settings --

require_root() { [[ $EUID -eq 0 ]] || die "Run as root"; }

take_lock() {
  exec 9>"$LOCK_FILE"
  flock -w 60 9 || die "Another $PROG command is running"
}

load_conf() {
  if [[ -r $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
  return 0
}

save_conf() {
  install -d -m 755 "$CONF_DIR"
  cat >"$CONF_FILE" <<EOF
# $PROG settings. Apply changes with: $PROG apply

# Upstream DNS servers, queried in parallel.
UPSTREAMS="$UPSTREAMS"
# fastest-ip: wait for every latency check and return the fastest IP.
# first-ping: return the first IP that answers (quicker first lookup).
RESPONSE_MODE="$RESPONSE_MODE"
# How latency is measured, in order of preference.
SPEED_CHECK="$SPEED_CHECK"
# IPs returned per answer, fastest first (1-16).
MAX_IPS="$MAX_IPS"
# auto: A records always; AAAA only when IPv6 is faster. off: IPv4 only.
IPV6="$IPV6"
# EDNS client subnet: auto (this server's /24), off, or <ip/prefix>.
ECS="$ECS"
# yes: redirect outgoing DNS queries on UDP 53 (Xray and its clients) to SmartDNS.
REDIRECT="$REDIRECT"
CACHE_SIZE="$CACHE_SIZE"
# Max TTL handed to clients, so they follow latency changes quickly.
REPLY_TTL="$REPLY_TTL"
EOF
}

need_val() { [[ $# -ge 2 && -n $2 ]] || die "Option $1 needs a value"; }

parse_opts() {
  while (($#)); do
    case $1 in
      --upstreams)     need_val "$@"; UPSTREAMS=${2//,/ }; shift ;;
      --mode)          need_val "$@"; RESPONSE_MODE=$2; shift ;;
      --speed-check)   need_val "$@"; SPEED_CHECK=$2; shift ;;
      --max-ips)       need_val "$@"; MAX_IPS=$2; shift ;;
      --ipv6)          need_val "$@"; IPV6=$2; shift ;;
      --ecs)           need_val "$@"; ECS=$2; shift ;;
      --reply-ttl)     need_val "$@"; REPLY_TTL=$2; shift ;;
      --cache-size)    need_val "$@"; CACHE_SIZE=$2; shift ;;
      --redirect)      REDIRECT="yes" ;;
      --no-redirect)   REDIRECT="no" ;;
      --deb)           need_val "$@"; DEB_FILE=$2; shift ;;
      --purge)         PURGE="yes" ;;
      --keep-smartdns) PURGE="no" ;;
      -h | --help)     usage; exit 0 ;;
      *)               die "Unknown option: $1 (see: $PROG help)" ;;
    esac
    shift
  done
  validate_opts
}

is_ipv4() { [[ $1 =~ ^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$ ]]; }
is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:]+$ ]]; }

validate_opts() {
  local u
  [[ -n ${UPSTREAMS// /} ]] || die "--upstreams is empty"
  for u in $UPSTREAMS; do
    is_ipv4 "$u" || is_ipv6 "$u" || die "Invalid upstream DNS server: $u (an IP address is expected)"
  done
  [[ $RESPONSE_MODE =~ ^(fastest-ip|first-ping|fastest-response)$ ]] ||
    die "--mode must be fastest-ip, first-ping or fastest-response"
  [[ $SPEED_CHECK =~ ^(none|(ping|tcp(-syn)?:[0-9]{1,5})(,(ping|tcp(-syn)?:[0-9]{1,5}))*)$ ]] ||
    die "Invalid --speed-check: $SPEED_CHECK"
  [[ $MAX_IPS =~ ^[0-9]{1,2}$ ]] && ((10#$MAX_IPS >= 1 && 10#$MAX_IPS <= 16)) || die "--max-ips must be 1-16"
  [[ $IPV6 =~ ^(auto|on|off)$ ]] || die "--ipv6 must be auto, on or off"
  [[ $ECS == auto || $ECS == off || $ECS =~ ^[0-9a-fA-F.:]+/[0-9]{1,3}$ ]] || die "--ecs must be auto, off or <ip>/<prefix>"
  [[ $CACHE_SIZE =~ ^[0-9]+$ ]] || die "--cache-size must be a number"
  [[ $REPLY_TTL =~ ^[0-9]+$ ]] && ((10#$REPLY_TTL >= 1)) || die "--reply-ttl must be at least 1"
  [[ $REDIRECT =~ ^(yes|no)$ ]] || die "REDIRECT must be yes or no"
}

# ----------------------------------------------------------------- system --

preflight() {
  [[ -d /run/systemd/system ]] || die "systemd is required"
  command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1 || die "Debian or Ubuntu is required"
  smartdns_arch >/dev/null
}

ensure_deps() {
  local -a need=()
  command -v dig >/dev/null 2>&1 || need+=(dnsutils)
  command -v iptables >/dev/null 2>&1 || need+=(iptables)
  command -v curl >/dev/null 2>&1 || need+=(curl)
  command -v ping >/dev/null 2>&1 || need+=(iputils-ping)
  command -v ss >/dev/null 2>&1 || need+=(iproute2)
  command -v conntrack >/dev/null 2>&1 || need+=(conntrack)
  command -v jq >/dev/null 2>&1 || need+=(jq)
  ((${#need[@]})) || return 0
  info "Installing dependencies: ${need[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null
}

ensure_bypass_user() {
  id -u "$BYPASS_USER" >/dev/null 2>&1 ||
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BYPASS_USER"
}

install_self() {
  local src tmp
  src=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
  if [[ -f $src ]] && grep -q 'readonly PROG="gaming-dns"' "$src" 2>/dev/null; then
    if [[ $src != "$SELF_BIN" ]]; then install -m 755 "$src" "$SELF_BIN"; fi
    return 0
  fi
  # Started from a pipe (bash <(curl ...)): fetch the same script to install.
  tmp=$(mktemp)
  if curl -fsSL --max-time 60 -o "$tmp" "$REPO_RAW/gaming-dns.sh" && bash -n "$tmp" &&
    grep -q 'readonly PROG="gaming-dns"' "$tmp"; then
    install -m 755 "$tmp" "$SELF_BIN"
  elif [[ ! -x $SELF_BIN ]]; then
    rm -f "$tmp"
    die "Could not download $REPO_RAW/gaming-dns.sh; save the script to a file and run it from there"
  fi
  rm -f "$tmp"
}

is_private_v4() {
  [[ $1 =~ ^(10|127)\. || $1 =~ ^192\.168\. || $1 =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ||
     $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

public_ipv4() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  if [[ -z $ip ]] || is_private_v4 "$ip"; then
    ip=$(curl -4 -fsS --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p') || true
  fi
  if is_ipv4 "$ip"; then printf '%s\n' "$ip"; fi
  return 0
}

has_ipv6_internet() { ping -6 -n -c 2 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; }
lo_has_ipv6() { ip -6 addr show dev lo 2>/dev/null | grep '::1/128' >/dev/null; }
has_resolved() { systemctl is-active --quiet systemd-resolved 2>/dev/null || systemctl is-enabled --quiet systemd-resolved 2>/dev/null; }

# Saves the original DNS setup once, so uninstall/fail-open can return to it.
backup_once() {
  [[ -e $BACKUP_DIR/.complete ]] && return 0
  install -d -m 700 "$BACKUP_DIR"
  if [[ -L /etc/resolv.conf ]]; then
    readlink /etc/resolv.conf >"$BACKUP_DIR/resolv.conf.symlink"
  elif grep "Managed by $PROG" /etc/resolv.conf >/dev/null 2>&1; then
    # Our own file (state was lost): the original cannot be recovered.
    if has_resolved; then echo /run/systemd/resolve/stub-resolv.conf >"$BACKUP_DIR/resolv.conf.symlink"; fi
  elif [[ -e /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf"
  fi
  if [[ -f $SDNS_CONF ]]; then cp -a "$SDNS_CONF" "$BACKUP_DIR/smartdns.conf"; fi
  if ! smartdns_installed; then touch "$BACKUP_DIR/smartdns.ours"; fi
  touch "$BACKUP_DIR/.complete"
}

# --------------------------------------------------------------- smartdns --

smartdns_arch() {
  case $(uname -m) in
    x86_64 | amd64)  echo x86_64 ;;
    aarch64 | arm64) echo aarch64 ;;
    armv6* | armv7*) echo arm ;;
    i?86)            echo x86 ;;
    *)               die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

smartdns_installed() {
  [[ -x /usr/sbin/smartdns && $(dpkg-query -W -f='${Status}' smartdns 2>/dev/null) == "install ok installed" ]]
}

smartdns_version() { dpkg-query -W -f='${Version}' smartdns 2>/dev/null || echo "not installed"; }

dpkg_install() {
  dpkg-deb --info "$1" >/dev/null 2>&1 || die "Not a valid .deb package: $1"
  # Our smartdns.conf is already in place; keep it over the packaged one,
  # which listens on every interface.
  DEBIAN_FRONTEND=noninteractive dpkg -i --force-confold --force-confdef "$1" >/dev/null ||
    die "dpkg could not install SmartDNS"
  ok "SmartDNS $(smartdns_version) installed"
}

install_smartdns() { # [force]
  local arch api url="" digest="" tmp sum
  if [[ -z ${1:-} ]] && smartdns_installed; then
    ok "SmartDNS $(smartdns_version) already installed"
    return 0
  fi
  if [[ -n $DEB_FILE ]]; then
    [[ -f $DEB_FILE ]] || die "No such file: $DEB_FILE"
    dpkg_install "$DEB_FILE"
    return 0
  fi
  arch=$(smartdns_arch)
  info "Downloading the latest SmartDNS release ($arch)"
  api=$(curl -fsSL --max-time 20 "$GH_API" 2>/dev/null) || true
  if [[ -n $api ]]; then
    read -r url digest < <(jq -r --arg s ".${arch}-debian-all.deb" \
      '[.assets[] | select(.name | endswith($s))][0] | "\(.browser_download_url // "") \(.digest // "")"' \
      <<<"$api" 2>/dev/null) || true
  fi
  [[ -n $url ]] || die "GitHub is unreachable. Download smartdns.*.${arch}-debian-all.deb from
    https://github.com/pymumu/smartdns/releases and run: $PROG install --deb <file>"
  tmp=$(mktemp -d)
  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "$tmp/smartdns.deb" "$url"; then
    rm -rf "$tmp"
    die "Download failed: $url"
  fi
  if [[ $digest == sha256:* ]]; then
    sum=$(sha256sum "$tmp/smartdns.deb" | cut -d' ' -f1)
    if [[ $sum != "${digest#sha256:}" ]]; then
      rm -rf "$tmp"
      die "Checksum mismatch for $url (expected ${digest#sha256:}, got $sum)"
    fi
    ok "Checksum verified (sha256 ${sum:0:16}...)"
  else
    warn "GitHub published no checksum for this release; installing unverified"
  fi
  dpkg_install "$tmp/smartdns.deb"
  rm -rf "$tmp"
}

write_smartdns_conf() {
  local u ecs="" dual pub
  case $ECS in
    off) ;;
    auto)
      pub=$(public_ipv4)
      if [[ -n $pub ]]; then ecs="${pub%.*}.0/24"; fi
      ;;
    *) ecs=$ECS ;;
  esac
  case $IPV6 in
    on)  dual="dualstack-ip-selection no" ;;
    off) dual="force-AAAA-SOA yes" ;;
    auto)
      # A records are always answered; AAAA only when IPv6 is the faster path.
      if has_ipv6_internet; then dual="dualstack-ip-selection yes"; else dual="force-AAAA-SOA yes"; fi
      ;;
  esac

  install -d -m 755 "${SDNS_CONF%/*}" "$SDNS_CACHE_DIR" "$SDNS_LOG_DIR"
  {
    cat <<EOF
# Generated by $PROG $VERSION. Do not edit by hand:
# change $CONF_FILE (or pass options) and run: $PROG apply

server-name $PROG

# Loopback only, never reachable from the internet. 127.0.0.53 is the
# systemd-resolved stub address that containers copied into their resolv.conf.
bind 127.0.0.1:53
bind-tcp 127.0.0.1:53
bind 127.0.0.53:53
bind-tcp 127.0.0.53:53
EOF
    if lo_has_ipv6; then printf 'bind [::1]:53\nbind-tcp [::1]:53\n'; fi

    printf '\n# Upstreams, queried in parallel over persistent TCP: under load Google and\n'
    printf '# Gcore truncate UDP answers, which SmartDNS would turn into empty replies.\n'
    printf '# The mark lets their packets bypass the DNS redirect rules.\n'
    for u in $UPSTREAMS; do
      if is_ipv6 "$u"; then u="[$u]"; fi
      printf 'server-tcp %s -set-mark %s\n' "$u" "$FW_MARK"
    done

    cat <<EOF

# Answer with the IP(s) that respond fastest from this server.
speed-check-mode $SPEED_CHECK
response-mode $RESPONSE_MODE
max-reply-ip-num $MAX_IPS
$dual
EOF
    if [[ -n $ecs ]]; then
      printf '\n# Ask for CDN answers that are close to this server.\nedns-client-subnet %s\n' "$ecs"
    fi

    cat <<EOF

# HTTPS/SVCB records carry IP hints straight from the upstream, unmeasured.
# Drop the hints (keep ALPN/ECH) so clients connect to the measured A/AAAA.
https-record noipv4hint,noipv6hint

# Local record for the $PROG health check.
address /$PROBE_NAME/127.0.0.1

# Cache hits are instant. Popular names are refreshed (and re-measured)
# before they expire; others are served stale once while being refreshed.
cache-size $CACHE_SIZE
cache-persist yes
cache-file $SDNS_CACHE_DIR/smartdns.cache
cache-checkpoint-time 3600
prefetch-domain yes
serve-expired yes
serve-expired-ttl 3600
serve-expired-reply-ttl 5
rr-ttl-min 30
# A selection is re-measured at least every 10 minutes.
rr-ttl-max 600
# Short TTL for clients, so they follow latency changes quickly.
rr-ttl-reply-max $REPLY_TTL

log-level warn
log-file $SDNS_LOG_DIR/smartdns.log
log-size 1m
log-num 2
EOF
  } >"$SDNS_CONF.tmp"
  # Only real setting changes count (they also flush the cache), not comments.
  if ! cmp -s <(grep -v '^#' "$SDNS_CONF.tmp") <(grep -v '^#' "$SDNS_CONF" 2>/dev/null); then
    SDNS_CONF_CHANGED=1
  fi
  mv -f "$SDNS_CONF.tmp" "$SDNS_CONF"
}

# Liveness: SmartDNS answers its local probe record (no upstream involved).
answering() { [[ $(dig @127.0.0.1 +short +time=2 +tries=1 "$PROBE_NAME" A 2>/dev/null) == 127.0.0.1 ]]; }

# has_a <server> [user]: www.google.com resolves to at least one A record.
has_a() {
  local -a run=()
  if [[ -n ${2:-} ]]; then run=(runuser -u "$2" --); fi
  [[ -n $("${run[@]}" dig @"$1" +short +time=2 +tries=1 www.google.com A 2>/dev/null | grep -E '^[0-9.]+$') ]]
}

wait_answering() { # [seconds]
  local i
  for ((i = 0; i < ${1:-15}; i++)); do
    if answering; then return 0; fi
    sleep 1
  done
  return 1
}

# ------------------------------------------------------- resolver switching --

write_resolv_conf() { # local | upstream
  local tmp u n=0
  tmp=$(mktemp /etc/.resolv.conf.XXXXXX)
  {
    if [[ $1 == local ]]; then
      printf '# Managed by %s: local SmartDNS (lowest-latency answers).\n' "$PROG"
      printf '# "%s uninstall" restores the original file.\n' "$PROG"
      printf 'nameserver 127.0.0.1\n'
      if lo_has_ipv6; then printf 'nameserver ::1\n'; fi
    else
      printf '# Managed by %s: direct upstream DNS.\n' "$PROG"
      for u in $UPSTREAMS; do
        if ((n < 3)); then printf 'nameserver %s\n' "$u"; fi
        n=$((n + 1))
      done
    fi
    printf 'options edns0 trust-ad\n'
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" /etc/resolv.conf
}

# Lists anything other than SmartDNS that holds port 53 on loopback/wildcard.
port53_conflicts() {
  local l
  l=$(ss -H -lntup 'sport = :53' 2>/dev/null | grep -v '"smartdns"' |
    awk '{print $5, $7}' | grep -E '^(127\.|0\.0\.0\.0|\*|\[::\]|\[::1\])' || true)
  [[ -z $l ]] && return 0
  warn "Port 53 on loopback is already in use by:"
  printf '      %s\n' "$l" >&2
  return 1
}

# Points the whole server at SmartDNS. Returns non-zero if it does not answer.
use_local_dns() {
  if has_resolved; then
    install -d -m 755 "${RESOLVED_DROPIN%/*}"
    printf '# %s: port 53 on loopback is served by SmartDNS.\n[Resolve]\nDNSStubListener=no\n' "$PROG" >"$RESOLVED_DROPIN"
    if ss -H -lnup 'sport = :53' 2>/dev/null | grep '"systemd-resolve"' >/dev/null; then
      systemctl restart systemd-resolved || return 1
    fi
  fi
  port53_conflicts || return 1
  systemctl enable smartdns >/dev/null 2>&1 || true
  if ((SDNS_CONF_CHANGED)); then
    # Cached answers were selected under the old settings.
    systemctl stop smartdns >/dev/null 2>&1 || true
    rm -f "$SDNS_CACHE_DIR/smartdns.cache"
  fi
  systemctl restart smartdns || return 1
  wait_answering 15 || return 1
  write_resolv_conf local
  fw_apply
  return 0
}

# Returns the server to its original DNS setup (fail-open and uninstall).
use_original_dns() {
  fw_down
  notrack_down
  systemctl stop smartdns >/dev/null 2>&1 || true
  rm -f "$RESOLVED_DROPIN"
  if has_resolved; then systemctl restart systemd-resolved >/dev/null 2>&1 || true; fi
  if [[ -f $BACKUP_DIR/resolv.conf.symlink ]]; then
    ln -sfn "$(cat "$BACKUP_DIR/resolv.conf.symlink")" /etc/resolv.conf
  elif [[ -f $BACKUP_DIR/resolv.conf ]]; then
    cp -af "$BACKUP_DIR/resolv.conf" /etc/resolv.conf
  else
    write_resolv_conf upstream
  fi
}

# ------------------------------------------------------------ DNS redirect --
# DNS queries this server sends on UDP port 53 (Xray's lookups and the DNS
# packets its clients send through the tunnel) are redirected to SmartDNS.
# Packets are matched on the DNS header (QR=0, opcode 0, one question, no
# answer/authority records), so VPN tunnels that run on port 53 pass
# untouched. TCP is left alone: its first packet has no payload to check.
# SmartDNS's own upstream queries carry FW_MARK and are let through.

readonly U32_DNS4="0>>22&0x3C@8&0xF800=0 && 0>>22&0x3C@12=0x10000 && 0>>22&0x3C@16>>16=0"
readonly U32_DNS6="48&0xF800=0 && 52=0x10000 && 56>>16=0"

fw_chain() { # <iptables|ip6tables> <loopback net> <u32 DNS-query match>
  local t=$1
  "$t" -w -t nat -N "$NAT_CHAIN" 2>/dev/null || "$t" -w -t nat -F "$NAT_CHAIN" || return 1
  "$t" -w -t nat -A "$NAT_CHAIN" -d "$2" -j RETURN || return 1
  "$t" -w -t nat -A "$NAT_CHAIN" -m mark --mark "$FW_MARK" -j RETURN || return 1
  "$t" -w -t nat -A "$NAT_CHAIN" -m owner --uid-owner "$BYPASS_USER" -j RETURN || return 1
  "$t" -w -t nat -A "$NAT_CHAIN" -p udp -m u32 --u32 "$3" -j REDIRECT --to-ports 53 || return 1
  "$t" -w -t nat -C OUTPUT -p udp --dport 53 -j "$NAT_CHAIN" >/dev/null 2>&1 ||
    "$t" -w -t nat -I OUTPUT 1 -p udp --dport 53 -j "$NAT_CHAIN" || return 1
  # Older versions also redirected TCP.
  while "$t" -w -t nat -D OUTPUT -p tcp --dport 53 -j "$NAT_CHAIN" 2>/dev/null; do :; done
}

fw_up() {
  ensure_bypass_user
  fw_chain iptables 127.0.0.0/8 "$U32_DNS4" || return 1
  if lo_has_ipv6 && command -v ip6tables >/dev/null 2>&1; then
    fw_chain ip6tables ::1/128 "$U32_DNS6" || warn "IPv6 DNS redirect unavailable (ip6tables nat)"
  fi
  # NAT only applies to new flows: drop tracked DNS flows so long-lived Xray
  # UDP sessions are redirected now rather than when they time out.
  if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -f ipv4 -p udp --dport 53 >/dev/null 2>&1 || true
    conntrack -D -f ipv6 -p udp --dport 53 >/dev/null 2>&1 || true
  fi
  return 0
}

fw_down() {
  local t p
  for t in iptables ip6tables; do
    command -v "$t" >/dev/null 2>&1 || continue
    for p in udp tcp; do
      while "$t" -w -t nat -D OUTPUT -p "$p" --dport 53 -j "$NAT_CHAIN" 2>/dev/null; do :; done
    done
    "$t" -w -t nat -F "$NAT_CHAIN" 2>/dev/null || true
    "$t" -w -t nat -X "$NAT_CHAIN" 2>/dev/null || true
  done
  return 0
}

fw_active() { iptables -w -t nat -C OUTPUT -p udp --dport 53 -j "$NAT_CHAIN" >/dev/null 2>&1; }

# Loopback DNS (Xray -> SmartDNS, several hundred queries/s) skips conntrack:
# no NAT is involved, and each query would otherwise hold an entry for 30s.
notrack_chain() { # <iptables|ip6tables> <loopback net>
  local t=$1
  "$t" -w -t raw -N "$RAW_CHAIN" 2>/dev/null || "$t" -w -t raw -F "$RAW_CHAIN" || return 1
  "$t" -w -t raw -A "$RAW_CHAIN" -p udp --dport 53 -j CT --notrack || return 1
  "$t" -w -t raw -A "$RAW_CHAIN" -p udp --sport 53 -j CT --notrack || return 1
  "$t" -w -t raw -C OUTPUT -o lo -s "$2" -d "$2" -j "$RAW_CHAIN" >/dev/null 2>&1 ||
    "$t" -w -t raw -I OUTPUT 1 -o lo -s "$2" -d "$2" -j "$RAW_CHAIN" || return 1
}

notrack_up() {
  notrack_chain iptables 127.0.0.0/8 || return 1
  if lo_has_ipv6 && command -v ip6tables >/dev/null 2>&1; then
    notrack_chain ip6tables ::1/128 || true
  fi
  return 0
}

notrack_down() {
  local t net
  for t in iptables ip6tables; do
    command -v "$t" >/dev/null 2>&1 || continue
    if [[ $t == iptables ]]; then net=127.0.0.0/8; else net=::1/128; fi
    while "$t" -w -t raw -D OUTPUT -o lo -s "$net" -d "$net" -j "$RAW_CHAIN" 2>/dev/null; do :; done
    "$t" -w -t raw -F "$RAW_CHAIN" 2>/dev/null || true
    "$t" -w -t raw -X "$RAW_CHAIN" 2>/dev/null || true
  done
  return 0
}

notrack_active() { iptables -w -t raw -C OUTPUT -o lo -s 127.0.0.0/8 -d 127.0.0.0/8 -j "$RAW_CHAIN" >/dev/null 2>&1; }

notrack_count() {
  iptables -w -t raw -L "$RAW_CHAIN" -n -v -x 2>/dev/null | awk '/CT/ {s += $1} END {print s + 0}'
}

# Applies the loopback conntrack bypass and, if enabled, the DNS redirect.
fw_apply() {
  notrack_up || warn "Could not add the conntrack bypass for loopback DNS (iptables raw)"
  if [[ $REDIRECT == yes && ! -e $DEGRADED_FLAG ]]; then
    fw_up || warn "Could not add the DNS redirect rules (iptables nat unavailable?)"
  else
    fw_down
  fi
  return 0
}

smartdns_listen() { ss -H -lnup 'sport = :53' 2>/dev/null | awk '/"smartdns"/ {printf "%s ", $4}'; }

fw_redirected_count() {
  { iptables -w -t nat -L "$NAT_CHAIN" -n -v -x 2>/dev/null
    ip6tables -w -t nat -L "$NAT_CHAIN" -n -v -x 2>/dev/null; } |
    awk '/REDIRECT/ {s += $1} END {print s + 0}'
}

# ------------------------------------------------------------------ units --

install_units() {
  if [[ -f $UNIT_DIR/$OLD_REDIRECT_UNIT ]]; then
    systemctl disable "$OLD_REDIRECT_UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$OLD_REDIRECT_UNIT"
  fi
  # At boot SmartDNS must be up before containers (Xray) start resolving.
  install -d -m 755 "${SDNS_DROPIN%/*}"
  printf '# %s: DNS is ready before containers start.\n[Unit]\nBefore=docker.service\n' "$PROG" >"$SDNS_DROPIN"
  cat >"$UNIT_DIR/$FIREWALL_UNIT" <<EOF
[Unit]
Description=$PROG: loopback DNS conntrack bypass and DNS redirect
After=network.target smartdns.service docker.service
Wants=smartdns.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF_BIN firewall-up
ExecStop=$SELF_BIN firewall-down

[Install]
WantedBy=multi-user.target
EOF
  cat >"$UNIT_DIR/$WATCHDOG_UNIT.service" <<EOF
[Unit]
Description=$PROG: SmartDNS health check
After=smartdns.service

[Service]
Type=oneshot
ExecStart=$SELF_BIN health
LogLevelMax=notice
EOF
  cat >"$UNIT_DIR/$WATCHDOG_UNIT.timer" <<EOF
[Unit]
Description=$PROG: SmartDNS health check every 30 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$WATCHDOG_UNIT.timer" >/dev/null 2>&1
  systemctl enable "$FIREWALL_UNIT" >/dev/null 2>&1
}

# --------------------------------------------------------------- commands --

cmd_install() {
  require_root
  take_lock
  load_conf
  parse_opts "$@"
  preflight
  install -d -m 755 "$STATE_DIR"
  ensure_deps
  backup_once
  write_smartdns_conf
  install_smartdns
  ensure_bypass_user
  install_self
  save_conf
  install_units

  info "Switching this server's DNS to SmartDNS"
  rm -f "$DEGRADED_FLAG"
  if ! use_local_dns; then
    use_original_dns
    die "SmartDNS did not start; the original DNS setup was restored. See: journalctl -u smartdns -n 50"
  fi
  systemctl start "$FIREWALL_UNIT" >/dev/null 2>&1 || true

  ok "SmartDNS $(smartdns_version) answering on: $(smartdns_listen)"
  ok "Upstreams: $UPSTREAMS  (mode: $RESPONSE_MODE, check: $SPEED_CHECK, ips: $MAX_IPS)"
  ok "System resolver: 127.0.0.1"
  if fw_active; then
    ok "DNS redirect: on (DNS queries from Xray and its clients on UDP 53 -> SmartDNS)"
  else
    warn "DNS redirect: off (only processes using the system resolver get the fastest IPs)"
  fi
  if notrack_active; then ok "Loopback DNS bypasses conntrack"; fi
  ok "Watchdog: every 30s, fails open to the original DNS if SmartDNS stops answering"
  printf '\nNext:  %s test      %s status      %s xray\n' "$PROG" "$PROG" "$PROG"
}

cmd_update() {
  require_root
  take_lock
  load_conf
  validate_opts
  smartdns_installed || die "SmartDNS is not installed; run: $PROG install"
  local before
  before=$(smartdns_version)
  ensure_deps
  fw_down
  install_smartdns force
  # The package's prerm stops and disables the service.
  systemctl enable smartdns >/dev/null 2>&1 || true
  systemctl restart smartdns >/dev/null 2>&1 || true
  if ! wait_answering 15; then
    use_original_dns
    touch "$DEGRADED_FLAG"
    die "SmartDNS did not come back after the update; failed open to the original DNS"
  fi
  fw_apply
  ok "SmartDNS $before -> $(smartdns_version)"
}

cmd_uninstall() {
  require_root
  take_lock
  load_conf
  parse_opts "$@"
  info "Restoring the original DNS setup"
  systemctl disable --now "$WATCHDOG_UNIT.timer" >/dev/null 2>&1 || true
  systemctl disable "$FIREWALL_UNIT" "$OLD_REDIRECT_UNIT" >/dev/null 2>&1 || true
  use_original_dns
  systemctl disable smartdns >/dev/null 2>&1 || true

  local purge=$PURGE
  if [[ $purge == auto ]]; then
    if [[ -e $BACKUP_DIR/smartdns.ours ]]; then purge=yes; else purge=no; fi
  fi
  if [[ $purge == yes ]]; then
    dpkg --purge smartdns >/dev/null 2>&1 || true
    rm -rf "$SDNS_CACHE_DIR" "$SDNS_LOG_DIR" "${SDNS_CONF%/*}"
    ok "SmartDNS package removed"
  elif [[ -f $BACKUP_DIR/smartdns.conf ]]; then
    cp -af "$BACKUP_DIR/smartdns.conf" "$SDNS_CONF"
    ok "SmartDNS kept (stopped); its previous config was restored"
  fi

  rm -f "$UNIT_DIR/$FIREWALL_UNIT" "$UNIT_DIR/$OLD_REDIRECT_UNIT" "$SDNS_DROPIN" \
    "$UNIT_DIR/$WATCHDOG_UNIT.service" "$UNIT_DIR/$WATCHDOG_UNIT.timer"
  rmdir "${SDNS_DROPIN%/*}" 2>/dev/null || true
  systemctl daemon-reload
  userdel "$BYPASS_USER" >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR" "$STATE_DIR"
  rm -f "$SELF_BIN"
  ok "$PROG removed; DNS is back to the original configuration"
}

cmd_redirect() {
  require_root
  take_lock
  load_conf
  case ${1:-} in
    on)
      answering || die "SmartDNS is not answering; check: $PROG status"
      REDIRECT="yes"
      save_conf
      fw_up || die "Could not add the iptables nat rules"
      ok "DNS redirect on"
      ;;
    off)
      REDIRECT="no"
      save_conf
      fw_down
      ok "DNS redirect off"
      ;;
    *) die "Usage: $PROG redirect on|off" ;;
  esac
}

# Boot-time hook of $FIREWALL_UNIT.
cmd_firewall_up() {
  require_root
  [[ -f $CONF_FILE && ! -e $DEGRADED_FLAG ]] || return 0
  load_conf
  if ! wait_answering 20; then
    event warning "SmartDNS is not answering; firewall rules left off (the watchdog retries)"
    return 0
  fi
  fw_apply
}

cmd_health() {
  require_root
  exec 9>"$LOCK_FILE"
  flock -n 9 || return 0 # another command is reconfiguring
  [[ -f $CONF_FILE ]] || return 0
  load_conf

  if [[ -e $DEGRADED_FLAG ]]; then
    # Failed open earlier: try to switch back at most every 5 minutes.
    (($(date +%s) - $(stat -c %Y "$DEGRADED_FLAG") >= 300)) || return 0
    rm -f "$DEGRADED_FLAG"
    if use_local_dns; then
      event warning "SmartDNS answers again; switched back to the local resolver"
    else
      use_original_dns
      touch "$DEGRADED_FLAG"
      event err "SmartDNS still failing; staying on the original DNS (next retry in 5 minutes)"
    fi
    return 0
  fi

  if answering; then
    # Alive but answering empty while the upstream has data: fail open after
    # three checks in a row.
    local bad_file="$STATE_DIR/empty-answers" bad
    if ! has_a 127.0.0.1 && has_a "${UPSTREAMS%% *}" "$BYPASS_USER"; then
      bad=$(($(cat "$bad_file" 2>/dev/null || echo 0) + 1))
      if ((bad < 3)); then
        echo "$bad" >"$bad_file"
        event warning "SmartDNS returned no A record for www.google.com ($bad/3)"
        return 0
      fi
      rm -f "$bad_file"
      use_original_dns
      touch "$DEGRADED_FLAG"
      event err "SmartDNS keeps returning empty answers; failed open to the original DNS setup"
      return 0
    fi
    rm -f "$bad_file"
    if ! notrack_active || { [[ $REDIRECT == yes ]] && ! fw_active; }; then
      fw_apply
      event notice "Firewall rules were missing (firewall reload?); re-applied"
    fi
    return 0
  fi

  event warning "SmartDNS is not answering; restarting it"
  systemctl restart smartdns >/dev/null 2>&1 || true
  if wait_answering 10; then
    event notice "SmartDNS recovered after a restart"
    return 0
  fi
  use_original_dns
  touch "$DEGRADED_FLAG"
  event err "SmartDNS is down; failed open to the original DNS setup (redirect off)"
}

svc_state() {
  local s
  s=$(systemctl is-active "$1" 2>/dev/null) || true
  if [[ $s == active ]]; then printf '%s%s%s' "$C_GRN" "$s" "$C_OFF"; else printf '%s%s%s' "$C_RED" "${s:-unknown}" "$C_OFF"; fi
}

cmd_status() {
  require_root
  load_conf
  local redirect qt
  if fw_active; then
    redirect="${C_GRN}on${C_OFF} ($(fw_redirected_count) DNS flows redirected so far)"
  elif [[ $REDIRECT == yes ]]; then
    redirect="${C_RED}configured but not active${C_OFF}"
  else
    redirect="off"
  fi
  printf '%s%s %s%s\n' "$C_BLD" "$PROG" "$VERSION" "$C_OFF"
  row "SmartDNS" "$(svc_state smartdns)  v$(smartdns_version)"
  row "Listening" "$(smartdns_listen)"
  row "Resolver" "$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf)"
  row "DNS redirect" "$redirect"
  if notrack_active; then
    row "Conntrack" "loopback DNS bypassed ($(notrack_count) packets so far)"
  else
    row "Conntrack" "${C_YLW}loopback DNS is tracked (bypass rules missing)${C_OFF}"
  fi
  row "Watchdog" "$(svc_state "$WATCHDOG_UNIT.timer")"
  if [[ -e $DEGRADED_FLAG ]]; then
    row "Mode" "${C_RED}FAILED OPEN since $(date -r "$DEGRADED_FLAG" '+%F %T')${C_OFF} (journalctl -t $PROG)"
  fi
  row "Upstreams" "$UPSTREAMS"
  row "Selection" "$RESPONSE_MODE, check=$SPEED_CHECK, max-ips=$MAX_IPS, ipv6=$IPV6, ecs=$ECS"
  if answering; then
    dig @127.0.0.1 +time=2 +tries=1 google.com A >/dev/null 2>&1 || true
    qt=$(dig @127.0.0.1 +time=2 +tries=1 google.com A 2>/dev/null | awk '/Query time/ {print $4 " ms"}')
    row "Cached query" "${qt:-?}"
  else
    row "Cached query" "${C_RED}SmartDNS not answering${C_OFF}"
  fi
  printf '%s  Recent events:%s\n' "$C_DIM" "$C_OFF"
  journalctl -t "$PROG" -n 5 --no-pager -o short-iso 2>/dev/null | sed 's/^/    /' || true
}

# measure <ip> -> "<ms> <method>", or "99999 timeout" when unreachable.
# Uses the minimum RTT of several probes: CDNs deprioritise ICMP, so single
# samples and averages jump by 10ms+ while the minimum stays stable.
measure() {
  local ip=$1 out p t
  out=$(ping -n -q -c 5 -i 0.2 -W 1 "$ip" 2>/dev/null) || true
  t=$(sed -n 's#^\(rtt\|round-trip\) [^=]*= \([0-9.]*\)/.*#\2#p' <<<"$out")
  if [[ -n $t ]]; then
    printf '%.1f icmp\n' "$t"
    return 0
  fi
  for p in 443 80; do
    t=$(tcp_ms "$ip" "$p")
    if [[ -n $t ]]; then
      printf '%s tcp:%s\n' "$t" "$p"
      return 0
    fi
  done
  printf '99999 timeout\n'
}

# tcp_ms <ip> <port> -> fastest of 3 TCP handshakes in ms, empty if closed.
tcp_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2" 2>/dev/null <<'PY' || true
import socket, sys, time
ip, port, best = sys.argv[1], int(sys.argv[2]), None
for _ in range(3):
    s = socket.socket(socket.AF_INET6 if ":" in ip else socket.AF_INET)
    s.settimeout(1)
    t = time.perf_counter()
    try:
        s.connect((ip, port))
        ms = (time.perf_counter() - t) * 1000
        best = ms if best is None else min(best, ms)
    except OSError:
        break
    finally:
        s.close()
if best is not None:
    print(f"{best:.1f}")
PY
  else
    local s e
    s=$(date +%s%N)
    timeout 1 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null || return 0
    e=$(date +%s%N)
    awk -v n=$((e - s)) 'BEGIN {printf "%.1f\n", n / 1e6}'
  fi
}

# Every A record any upstream returns, asked directly (bypassing the redirect).
upstream_ips() {
  local u
  for u in $UPSTREAMS; do
    runuser -u "$BYPASS_USER" -- dig +short +time=2 +tries=1 @"$u" "$1" A 2>/dev/null || true
  done | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true
}

test_domain() {
  local d=$1 line lat how ip mark shown best picked_lat=""
  local -a picked ips rows=()
  mapfile -t picked < <(dig +short +time=3 +tries=1 @127.0.0.1 "$d" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)
  mapfile -t ips < <({ upstream_ips "$d"; printf '%s\n' "${picked[@]}"; } | grep -E '^[0-9.]+$' | sort -u || true)

  printf '\n%s%s%s  %s(%d unique IPs from upstreams)%s\n' "$C_BLD" "$d" "$C_OFF" "$C_DIM" "${#ips[@]}" "$C_OFF"
  if ((${#ips[@]} == 0)); then
    warn "  no A records"
    return 0
  fi
  for ip in "${ips[@]}"; do rows+=("$(measure "$ip") $ip"); done
  mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort -k1,1n)
  best=${rows[0]%% *}

  for line in "${rows[@]}"; do
    read -r lat how ip <<<"$line"
    mark=""
    if [[ " ${picked[*]} " == *" $ip "* ]]; then
      mark="${C_GRN}<- returned to Xray${C_OFF}"
      if [[ -z $picked_lat ]]; then picked_lat=$lat; fi
    fi
    if [[ $lat == 99999 ]]; then shown="no reply"; else shown="$lat ms"; fi
    printf '  %-16s %10s  %-8s %s\n' "$ip" "$shown" "$how" "$mark"
  done

  if ((${#picked[@]} == 0)); then
    warn "  SmartDNS returned no A record"
  elif [[ $best == 99999 ]]; then
    printf '  %sNo IP answers ping or TCP 443/80 (typical for UDP-only game servers); SmartDNS keeps the upstream order.%s\n' "$C_DIM" "$C_OFF"
  elif awk -v a="$picked_lat" -v b="$best" 'BEGIN {exit !(a <= b * 1.15 + 1)}'; then
    printf '  %sOK: the fastest IP is the one Xray receives%s\n' "$C_GRN" "$C_OFF"
  else
    printf '  %sReturned IP is slower than the best right now; SmartDNS re-measures it within %ss.%s\n' "$C_YLW" "$REPLY_TTL" "$C_OFF"
  fi
}

cmd_test() {
  require_root
  load_conf
  answering || die "SmartDNS is not answering on 127.0.0.1; check: $PROG status"
  ensure_bypass_user
  local d
  if (($# == 0)); then
    # shellcheck disable=SC2086
    set -- $TEST_DOMAINS
  fi
  for d in "$@"; do test_domain "$d"; done
}

cmd_xray() {
  cat <<EOF
With the DNS redirect on (default), Xray needs no change: every DNS query
that Xray or its clients send on UDP port 53, to any server, is answered by
SmartDNS with the fastest IP.

To make Xray use it explicitly as well, set this in the Xray core config
(PasarGuard / Marzban: Settings -> Core):

  "dns": {
    "servers": ["localhost"],
    "queryStrategy": "UseIPv4",
    "disableCache": true
  }

  "localhost"      = the system resolver, i.e. SmartDNS on this node
                     (nodes without $PROG keep working with their own DNS).
  "disableCache"   = Xray asks SmartDNS every time, so it always gets the
                     current fastest IP (SmartDNS caches, answers in <1 ms).
  "queryStrategy"  = use "UseIP" instead if your clients need IPv6.

Avoid DoH/DoT servers (https://, tls://, quic://) in Xray's dns block:
encrypted DNS cannot be redirected and bypasses the latency selection.

Clients that resolve names themselves over encrypted DNS (Android "Private
DNS", iOS/Chrome secure DNS, DoH in the client app) send Xray an IP that was
not chosen here. Turn on sniffing in the inbounds so Xray reads the real
domain (TLS SNI, HTTP Host, QUIC) and resolves it through SmartDNS:

  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": false
  }

UDP game traffic carries no domain, so it is not affected by sniffing.
EOF
}

main() {
  local cmd=${1:-help}
  if (($#)); then shift; fi
  case $cmd in
    install | apply) cmd_install "$@" ;;
    status)          cmd_status ;;
    test)            cmd_test "$@" ;;
    redirect)        cmd_redirect "$@" ;;
    firewall-up | redirect-up) cmd_firewall_up ;;
    firewall-down | redirect-down) require_root; fw_down; notrack_down ;;
    xray)            cmd_xray ;;
    update)          cmd_update ;;
    uninstall)       cmd_uninstall "$@" ;;
    health)          cmd_health ;;
    version | -v | --version) echo "$PROG $VERSION" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
