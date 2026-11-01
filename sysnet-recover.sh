#!/usr/bin/env bash
# sysnet-recover.sh - offline system + network diagnosis and safe recovery.
#
# One self-contained script. It never installs packages, downloads anything,
# or contacts the internet. Network probes are limited to the local link
# (interface state, addresses, routes, neighbour table, local gateway ICMP,
# and the local resolver stub).
#
# Usage:
#   sysnet-recover.sh [diagnose|recover] [options]
#
#   diagnose   Read-only checks (default). Exit 2 when failures are found.
#   recover    Apply safe fixes, then verify. Needs root unless --dry-run.
#
# Options:
#   --dry-run             Show what recover would do; change nothing.
#   --allow-disruptive    Allow restarting NetworkManager/renewing DHCP even
#                         when connected over SSH (can drop the session).
#   --iface NAME          Focus checks/recovery on one interface.
#   --export DIR          Write a diagnostic bundle for USB/offline transfer.
#   --no-probe            Do not send even the local gateway ICMP probe.
#   --quiet               Show only warnings, failures, fixes and summary.
#   --version             Print version.
#   -h, --help            This help.
#
# Safety:
#   * No package installs, no downloads, no firewall changes, no reboots.
#   * No files deleted outside the systemd journal vacuum when disk >= 95%.
#   * The SSH path interface is protected from disruptive actions.
#   * apt cache is deliberately left alone: offline, it may be the only
#     package source.
#
# Exit codes:
#   0 healthy, 1 warnings only, 2 failures remain, 3 usage error,
#   4 missing prerequisite or not root for recover.
#
# Logs: /var/log/sysnet-recover (root) or ~/.local/state/sysnet-recover.

set -uo pipefail
umask 077
export LC_ALL=C

VERSION="1.0.0"
ACTION="diagnose"          # diagnose | recover
DRY_RUN=0
ALLOW_DISRUPTIVE=0
NO_PROBE=0
QUIET=0
IFACE=""
EXPORT_DIR=""
LOG=""

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
FIX_COUNT=0
SKIP_COUNT=0
WARN_MSGS=()
FAIL_MSGS=()

FAILED_UNITS=()
DEFAULT_ROUTES=()
PHYS_IFACES=()
DEFAULT_IFACE=""
DEFAULT_GW=""
TARGET_IFACE=""
PROTECTED_IFACE=""
DNS_BAD=0

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit "${2:-3}"
}

section() {
  say ""
  say "== $* =="
}

say() {
  if [[ -n $LOG && -w $LOG ]]; then
    printf '%s\n' "$*" | tee -a "$LOG"
  else
    printf '%s\n' "$*"
  fi
}

record() {
  local level="$1" msg="$2" detail="${3:-}" tag
  case "$level" in
    OK)   OK_COUNT=$((OK_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)); WARN_MSGS+=("$msg") ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL_MSGS+=("$msg") ;;
    FIX)  FIX_COUNT=$((FIX_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    INFO) : ;;
    *)    level="INFO" ;;
  esac

  if ((QUIET == 1)) && [[ $level == OK || $level == INFO ]]; then
    return 0
  fi

  case "$level" in
    OK)   tag=" OK " ;;
    WARN) tag="WARN" ;;
    FAIL) tag="FAIL" ;;
    FIX)  tag="FIX " ;;
    SKIP) tag="SKIP" ;;
    *)    tag="INFO" ;;
  esac

  say "[$tag] $msg"
  if [[ -n $detail ]]; then
    while IFS= read -r line; do
      [[ -n $line ]] && say "       $line"
    done <<< "$detail"
  fi
}

reset_counts() {
  OK_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; FIX_COUNT=0; SKIP_COUNT=0
  WARN_MSGS=(); FAIL_MSGS=()
}

have() { command -v "$1" >/dev/null 2>&1; }

cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

route_field() {
  # route_field <key> : value following key on stdin
  awk -v key="$1" '{ for (i = 1; i <= NF; i++) if ($i == key) { print $(i + 1); exit } }'
}

list_phys_ifaces() {
  local p i
  for p in /sys/class/net/*; do
    [[ -e $p ]] || continue
    i="${p##*/}"
    case "$i" in
      lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tailscale*|dummy*|p2p-dev-*) continue ;;
    esac
    if [[ -e "$p/device" || -e "$p/wireless" ]]; then
      printf '%s\n' "$i"
    fi
  done
}

is_wireless() { [[ -e "/sys/class/net/$1/wireless" ]]; }

link_admin_up() {
  local flags
  flags=$(ip -o link show dev "$1" 2>/dev/null | sed -n 's/.*<\([^>]*\)>.*/\1/p')
  case ",$flags," in
    *,UP,*) return 0 ;;
    *) return 1 ;;
  esac
}

link_has_carrier() {
  [[ $(cat "/sys/class/net/$1/carrier" 2>/dev/null || echo 0) == 1 ]]
}

has_ipv4() {
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | grep -q ' inet '
}

nm_con_name() {
  timeout 5 nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null | head -n 1
}

nm_active() {
  have nmcli && systemctl is-active --quiet NetworkManager 2>/dev/null
}

can_disrupt() {
  # Never risk the interface carrying the current SSH session.
  local target="$1"
  (( ALLOW_DISRUPTIVE == 1 )) && return 0
  [[ -z ${SSH_CONNECTION:-} ]] && return 0
  [[ -n $PROTECTED_IFACE && $target != "$PROTECTED_IFACE" ]]
}

max_disk_pct() {
  timeout 10 df -PT 2>/dev/null | awk '
    NR > 1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|efivarfs|ramfs|fuse.*|nsfs)$/ {
      gsub("%", "", $6); if (($6 + 0) > m) m = $6 + 0
    }
    END { print m + 0 }'
}

fs_pct() {
  timeout 5 df -P "$1" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 + 0 }'
}

mem_avail_pct() {
  awk '
    /^MemTotal:/ { t = $2 }
    /^MemAvailable:/ { a = $2 }
    END { if (t > 0) printf "%d", (a * 100) / t; else print 100 }' /proc/meminfo
}

load1() { awk '{ print $1 }' /proc/loadavg; }

max_thermal_c() {
  local f v max=0 c
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r $f ]] || continue
    v=$(cat "$f" 2>/dev/null || echo 0)
    [[ $v =~ ^-?[0-9]+$ ]] || continue
    c=$((v / 1000))
    (( c > max )) && max=$c
  done
  echo "$max"
}

init_log() {
  local dir
  if (( EUID == 0 )); then
    dir="/var/log/sysnet-recover"
  else
    dir="${HOME:-/tmp}/.local/state/sysnet-recover"
  fi

  if ! mkdir -p -- "$dir" 2>/dev/null; then
    dir="${TMPDIR:-/tmp}/sysnet-recover-${UID:-0}"
    if ! mkdir -p -- "$dir" 2>/dev/null; then
      LOG="/dev/null"
      return
    fi
  fi

  LOG="$dir/run-$(date +%Y%m%d-%H%M%S)-$$.log"
  if ! : > "$LOG" 2>/dev/null; then
    LOG="/dev/null"
    return
  fi
  chmod 600 -- "$LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# System checks
# ---------------------------------------------------------------------------

check_load() {
  local l1 l5 l15 ncpu detail
  read -r l1 l5 l15 _ < /proc/loadavg
  ncpu=$(cpu_count)
  detail="load ${l1}/${l5}/${l15} over ${ncpu} CPU(s)"

  if awk -v l="$l1" -v n="$ncpu" 'BEGIN { exit !(l > n * 4) }'; then
    record FAIL "system load is critically high" "$detail"
  elif awk -v l="$l1" -v n="$ncpu" 'BEGIN { exit !(l > n * 2) }'; then
    record WARN "system load is high" "$detail"
  else
    record OK "load normal" "$detail"
  fi
}

check_memory() {
  local total avail pct sw_total sw_free sw_used_pct swap_high=0 detail
  read -r total avail < <(awk '
    /^MemTotal:/ { t = $2 }
    /^MemAvailable:/ { a = $2 }
    END { print t, a }' /proc/meminfo)
  [[ -n ${total:-} && -n ${avail:-} && $total -gt 0 ]] || { record SKIP "memory information unavailable"; return; }
  pct=$(( avail * 100 / total ))
  total=$(( total / 1024 ))
  avail=$(( avail / 1024 ))
  detail="RAM available: ${avail} MiB of ${total} MiB (${pct}%)"

  read -r sw_total sw_free < <(awk '
    /^SwapTotal:/ { t = $2 }
    /^SwapFree:/ { f = $2 }
    END { print t, f }' /proc/meminfo)
  if [[ ${sw_total:-0} -gt 0 ]]; then
    sw_used_pct=$(( (sw_total - sw_free) * 100 / sw_total ))
    detail+=$'\n'"swap used: ${sw_used_pct}%"
    if (( sw_used_pct >= 90 )); then
      detail+=$'\n'"swap is nearly exhausted"
      swap_high=1
    fi
  fi

  if (( pct < 3 )); then
    record FAIL "available memory is critically low" "$detail"
  elif (( pct < 10 )); then
    record WARN "available memory is low" "$detail"
  elif (( swap_high == 1 )); then
    record WARN "swap is nearly exhausted" "$detail"
  else
    record OK "memory normal" "$detail"
  fi
}

check_disk() {
  local fs type size used avail cap mnt pct worst=0 worst_mnt="" found=0 saw=0 saw_i=0
  while IFS=' ' read -r fs type size used avail cap mnt; do
    [[ -n ${mnt:-} ]] || continue
    pct="${cap%\%}"
    [[ $pct =~ ^[0-9]+$ ]] || continue
    saw=1
    (( pct > worst )) && { worst=$pct; worst_mnt=$mnt; }
    if (( pct >= 97 )); then
      record FAIL "filesystem almost full: ${mnt} (${pct}%)" "${avail} KiB free"
      found=1
    elif (( pct >= 90 )); then
      record WARN "filesystem nearly full: ${mnt} (${pct}%)" "${avail} KiB free"
      found=1
    fi
  done < <(timeout 10 df -PT 2>/dev/null | awk '
    NR > 1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|efivarfs|ramfs|fuse.*|nsfs)$/')
  if (( saw == 0 )); then
    record WARN "filesystem usage unavailable" "df timed out or returned no data (stale network mount?)"
  elif (( found == 0 )); then
    record OK "disk space normal" "fullest filesystem: ${worst_mnt} at ${worst}%"
  fi

  # Inodes are a separate failure mode on many-small-files systems.
  found=0
  while IFS=' ' read -r fs type inodes iused ifree ipct mnt; do
    [[ -n ${mnt:-} ]] || continue
    pct="${ipct%\%}"
    [[ $pct =~ ^[0-9]+$ ]] || continue
    saw_i=1
    if (( pct >= 97 )); then
      record FAIL "inodes almost exhausted: ${mnt} (${pct}%)" "${ifree} inodes free"
      found=1
    elif (( pct >= 90 )); then
      record WARN "inodes nearly exhausted: ${mnt} (${pct}%)"
      found=1
    fi
  done < <(timeout 10 df -PiT 2>/dev/null | awk '
    NR > 1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|efivarfs|ramfs|fuse.*|nsfs)$/')
  if (( saw_i == 0 )); then
    record INFO "inode usage not reported by the filesystem(s)"
  elif (( found == 0 )); then
    record OK "inode usage normal"
  fi
}

check_ro_mounts() {
  local dev mnt type opts found=0
  while read -r dev mnt type opts _; do
    case "$type" in
      ext2|ext3|ext4|xfs|btrfs|vfat|exfat) ;;
      *) continue ;;
    esac
    case ",$opts," in
      *,ro,*) ;;
      *) continue ;;
    esac
    if [[ $mnt == "/" ]]; then
      record FAIL "root filesystem is mounted read-only" \
        "writes and logs will fail; recover cannot remount safely. Check dmesg for I/O errors, then fsck from rescue media."
    else
      record WARN "filesystem mounted read-only: ${mnt} (${type})"
    fi
    found=1
  done < /proc/mounts
  (( found == 0 )) && record OK "no unexpected read-only filesystems"
}

check_failed_units() {
  FAILED_UNITS=()
  if ! have systemctl; then
    record SKIP "systemctl not available; unit checks skipped"
    return
  fi
  mapfile -t FAILED_UNITS < <(
    timeout 10 systemctl list-units --state=failed --no-legend --plain 2>/dev/null |
      awk 'NF { print $1 }'
  )
  if (( ${#FAILED_UNITS[@]} == 0 )); then
    record OK "no failed systemd units"
    return
  fi
  local detail="" u
  for u in "${FAILED_UNITS[@]:0:10}"; do
    detail+="${u}"$'\n'
  done
  (( ${#FAILED_UNITS[@]} > 10 )) && detail+="... $(( ${#FAILED_UNITS[@]} - 10 )) more"
  record FAIL "${#FAILED_UNITS[@]} failed systemd unit(s)" "${detail%$'\n'}"
}

check_journal() {
  if ! timeout 8 journalctl -b -n 1 --no-pager -q >/dev/null 2>&1; then
    record SKIP "journal not readable; run as root for log checks"
    return
  fi

  local errors crit oom top_src
  errors=$(timeout 15 journalctl -b -p 3 -o short-iso --no-pager -q 2>/dev/null |
    grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' || true)
  [[ $errors =~ ^[0-9]+$ ]] || errors=0

  # Group by log source instead of quoting messages, which may contain
  # unrelated local details or multi-line backtraces.
  top_src=$(timeout 15 journalctl -b -p 3 -o short-iso --no-pager -q 2>/dev/null |
    grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' |
    awk '{
      src = $3
      sub(/\[[0-9]+\]:$/, "", src)
      sub(/:$/, "", src)
      count[src]++
    }
    END { for (s in count) print count[s], s }' |
    sort -rn | head -n 3)

  if (( errors > 0 )); then
    local detail="top sources (count, unit):"
    [[ -n $top_src ]] && detail+=$'\n'"$top_src"
    record INFO "${errors} error-level journal messages in this boot" "$detail"
  else
    record OK "no error-level journal entries in this boot"
  fi

  crit=$(timeout 15 journalctl -k -b --no-pager -q 2>/dev/null |
    grep -Ei 'I/O error|EXT4-fs error|XFS .*error|BTRFS error|blk_update_request|medium error|Unrecovered read error' |
    tail -n 4 | cut -c1-180)
  if [[ -n $crit ]]; then
    record FAIL "storage subsystem reported errors" "$crit"
  fi

  oom=$(timeout 15 journalctl -k -b --no-pager -q 2>/dev/null |
    grep -Eci 'oom-kill|Out of memory' || true)
  if [[ ${oom:-0} =~ ^[0-9]+$ ]] && (( oom > 0 )); then
    record WARN "OOM killer fired ${oom} time(s) in this boot" \
      "memory pressure occurred; identify consumers with: ps -eo pid,rss,comm --sort=-rss | head"
  fi
}

check_hardware() {
  local hw
  if ! timeout 8 journalctl -k -b -n 1 --no-pager -q >/dev/null 2>&1; then
    record SKIP "kernel log not readable; hardware check skipped"
    return
  fi
  hw=$(timeout 15 journalctl -k -b --no-pager -q 2>/dev/null |
    grep -Ei 'machine check|Hardware Error|EDAC .*: .*(error|fail)|CPU[0-9]+: .*temperature above threshold|pcieport.*AER: (corrected|uncorrected|received)|thermal.*critical|kernel BUG at|Oops:' |
    grep -Evi 'In-kernel MCE decoding' |
    tail -n 4 | cut -c1-180)
  if [[ -n $hw ]]; then
    record WARN "kernel reported hardware/temperature events" "$hw"
  else
    record OK "no hardware error events in kernel log"
  fi
}

check_thermal() {
  local max
  max=$(max_thermal_c)
  if (( max == 0 )); then
    record INFO "no thermal zones exposed by firmware"
  elif (( max >= 95 )); then
    record FAIL "critical temperature: ${max}C" "check cooling/fans before sustained load"
  elif (( max >= 80 )); then
    record WARN "high temperature: ${max}C"
  else
    record OK "temperature normal" "max thermal zone: ${max}C"
  fi
}

check_clock() {
  local now year
  now=$(date +%s)
  year=$(date +%Y)
  if (( now < 1577836800 )) || (( now > 4102444800 )); then
    record WARN "system clock is implausible: ${year}" \
      "offline mode cannot sync time; fix before TLS/package work"
  else
    record OK "system clock plausible" "$(date -Is)"
  fi
}

check_processes() {
  local zombies fds fmax pct
  zombies=$(ps -eo stat= 2>/dev/null | grep -c '^[[:space:]]*Z' || true)
  [[ ${zombies:-0} =~ ^[0-9]+$ ]] || zombies=0
  if (( zombies > 5 )); then
    record WARN "${zombies} zombie processes" "parent processes are not reaping children"
  else
    record OK "no significant zombie accumulation"
  fi

  if [[ -r /proc/sys/fs/file-nr && -r /proc/sys/fs/file-max ]]; then
    fds=$(awk '{ print $1 }' /proc/sys/fs/file-nr)
    fmax=$(cat /proc/sys/fs/file-max)
    if [[ $fmax =~ ^[0-9]+$ ]] && (( fmax > 0 )); then
      pct=$(( fds * 100 / fmax ))
      if (( pct >= 80 )); then
        record WARN "file descriptor table is ${pct}% full" "${fds} of ${fmax} allocated"
      else
        record OK "file descriptor usage normal" "${pct}% allocated"
      fi
    fi
  fi
}

check_system() {
  check_load
  check_memory
  check_disk
  check_ro_mounts
  check_failed_units
  check_journal
  check_hardware
  check_thermal
  check_clock
  check_processes
}

# ---------------------------------------------------------------------------
# Network checks
# ---------------------------------------------------------------------------

discover_network() {
  DEFAULT_ROUTES=()
  PHYS_IFACES=()
  DEFAULT_IFACE=""
  DEFAULT_GW=""

  mapfile -t DEFAULT_ROUTES < <(ip -4 route show default 2>/dev/null)
  if (( ${#DEFAULT_ROUTES[@]} > 0 )); then
    DEFAULT_IFACE=$(printf '%s\n' "${DEFAULT_ROUTES[0]}" | route_field dev)
    DEFAULT_GW=$(printf '%s\n' "${DEFAULT_ROUTES[0]}" | route_field via)
  fi
  mapfile -t PHYS_IFACES < <(list_phys_ifaces)
  TARGET_IFACE="${IFACE:-$DEFAULT_IFACE}"
}

check_links() {
  if (( ${#PHYS_IFACES[@]} == 0 )) && [[ -z $IFACE ]]; then
    record WARN "no physical network interfaces detected"
    return
  fi

  local focus="${TARGET_IFACE:-${PHYS_IFACES[0]:-}}" i state carrier speed detail
  local -a candidates=("${PHYS_IFACES[@]}")
  [[ -n $IFACE ]] && candidates=("$IFACE")

  local found=0
  for i in "${candidates[@]}"; do
    [[ $i == "$focus" ]] || continue
    found=1
    state=$(cat "/sys/class/net/$i/operstate" 2>/dev/null || echo unknown)
    link_has_carrier "$i" && carrier=1 || carrier=0
    speed=""
    if [[ -r "/sys/class/net/$i/speed" ]]; then
      speed=$(cat "/sys/class/net/$i/speed" 2>/dev/null || true)
      [[ $speed =~ ^[0-9]+$ ]] && speed="${speed} Mb/s"
    fi

    if ! link_admin_up "$i"; then
      record FAIL "interface ${i} is administratively down" "state=${state}${speed:+, $speed}"
    elif (( carrier == 0 )); then
      record WARN "interface ${i} has no carrier" \
        "state=${state}; check cable/switch or Wi-Fi association${IFACE:+ (focused iface)}"
    elif [[ $state == up || $state == unknown ]]; then
      detail="state=${state}${speed:+, $speed}"
      record OK "link up: ${i}" "$detail"
    else
      record WARN "interface ${i} state is ${state}" "carrier present but link not up"
    fi
  done

  if (( found == 0 )); then
    record WARN "focused interface not found among physical interfaces: ${focus}"
  fi
}

check_addresses() {
  local addrs first i all
  if [[ -n $TARGET_IFACE ]]; then
    all=$(ip -4 -o addr show dev "$TARGET_IFACE" 2>/dev/null | awk '{ print $4 }' | paste -sd', ' -)
    addrs=$(ip -4 -o addr show dev "$TARGET_IFACE" scope global 2>/dev/null | awk '{ print $4 }' | paste -sd', ' -)
    if [[ -z $addrs ]]; then
      if [[ $all == *169.254.* ]]; then
        record WARN "only link-local address on ${TARGET_IFACE}: ${all}" "DHCP did not assign a routable address"
      else
        record FAIL "no global IPv4 address on ${TARGET_IFACE}" \
          "DHCP may have failed; recover can reapply/renew when safe"
      fi
    elif [[ $addrs == 169.254.* ]]; then
      record WARN "only link-local address on ${TARGET_IFACE}: ${addrs}" "DHCP did not assign a routable address"
    else
      record OK "IPv4 address present on ${TARGET_IFACE}" "$addrs"
    fi
  else
    first=""
    for i in "${PHYS_IFACES[@]}"; do
      addrs=$(ip -4 -o addr show dev "$i" scope global 2>/dev/null | awk '{ print $4 }' | paste -sd', ' -)
      if [[ -n $addrs ]]; then
        first="${i}: ${addrs}"
        break
      fi
    done
    if [[ -n $first ]]; then
      record OK "global IPv4 address present" "$first (no default route)"
    else
      record WARN "no global IPv4 address on any physical interface"
    fi
  fi
}

check_default_route() {
  if (( ${#DEFAULT_ROUTES[@]} == 0 )); then
    record WARN "no IPv4 default route" "normal for an isolated/air-gapped host; external reachability unavailable"
    return
  fi

  local detail="" r
  for r in "${DEFAULT_ROUTES[@]}"; do
    detail+="${r}"$'\n'
  done
  if (( ${#DEFAULT_ROUTES[@]} > 1 )); then
    record INFO "multiple IPv4 default routes" "${detail%$'\n'}"
  else
    record OK "default route present" "${DEFAULT_ROUTES[0]}"
  fi
}

check_gateway() {
  if (( NO_PROBE == 1 )); then
    record SKIP "gateway probe disabled (--no-probe)"
    return
  fi
  if [[ -n $IFACE && $IFACE != "$DEFAULT_IFACE" ]]; then
    record SKIP "focused interface ${IFACE} carries no default route"
    return
  fi
  if [[ -z $DEFAULT_GW || -z $DEFAULT_IFACE ]]; then
    record SKIP "no gateway to probe"
    return
  fi
  if ! have ping; then
    record SKIP "ping not installed; gateway probe skipped"
    return
  fi

  local neigh
  if timeout 4 ping -c 1 -W 1 -I "$DEFAULT_IFACE" "$DEFAULT_GW" >/dev/null 2>&1; then
    record OK "gateway reachable: ${DEFAULT_GW} via ${DEFAULT_IFACE}"
    return
  fi

  neigh=$(ip neigh show "$DEFAULT_GW" dev "$DEFAULT_IFACE" 2>/dev/null | head -n 1)
  if [[ $neigh == *lladdr* ]]; then
    record WARN "gateway does not answer ICMP but is present on L2" \
      "${DEFAULT_GW} via ${DEFAULT_IFACE}: ${neigh}"
  else
    record WARN "gateway unreachable: ${DEFAULT_GW} via ${DEFAULT_IFACE}" \
      "local probe only; no internet traffic was generated"
  fi
}

check_dns() {
  local ns_list resolved_state detail
  DNS_BAD=0
  if [[ ! -r /etc/resolv.conf ]]; then
    record FAIL "/etc/resolv.conf is missing or unreadable" "recover can restore the systemd-resolved stub when available"
    DNS_BAD=1
    return
  fi

  ns_list=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ { print $2 }' /etc/resolv.conf 2>/dev/null | paste -sd' ' -)
  if [[ -z $ns_list ]]; then
    record FAIL "/etc/resolv.conf contains no nameserver" "recover can restore the systemd-resolved stub when available"
    DNS_BAD=1
    return
  fi

  resolved_state=$(systemctl is-active systemd-resolved 2>/dev/null || true)
  if [[ $ns_list == *127.0.0.53* ]]; then
    if [[ $resolved_state == active ]]; then
      if have resolvectl && timeout 4 resolvectl query --legend=no localhost >/dev/null 2>&1; then
        record OK "local DNS stub is answering" "systemd-resolved on 127.0.0.53; external names not probed offline"
      else
        record WARN "systemd-resolved is active but the local stub did not answer" "nameservers: ${ns_list}"
        DNS_BAD=1
      fi
    else
      record FAIL "resolv.conf points to 127.0.0.53 but systemd-resolved is ${resolved_state:-unknown}" \
        "recover will restart the resolver"
      DNS_BAD=1
    fi
  elif [[ $resolved_state == active ]]; then
    record OK "systemd-resolved active with custom nameservers" "nameservers: ${ns_list}"
  else
    record INFO "static DNS configuration (offline, not probed)" "nameservers: ${ns_list}"
  fi

  detail=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
  if [[ -n $detail && $detail != /etc/resolv.conf ]]; then
    record INFO "resolv.conf target: ${detail}"
  fi

  if ! awk '$1 == "hosts:" { found=1; for (i = 2; i <= NF; i++) if ($i == "dns") dns=1 } END { exit !(found && dns) }' \
      /etc/nsswitch.conf 2>/dev/null; then
    record WARN "NSS hosts lookup does not include dns" "check /etc/nsswitch.conf hosts: line"
  fi
}

check_networkmanager() {
  if ! have nmcli; then
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
      record OK "systemd-networkd is active (NetworkManager not installed)"
    else
      record SKIP "no NetworkManager or active systemd-networkd"
    fi
    return
  fi

  if ! systemctl is-active --quiet NetworkManager 2>/dev/null &&
     systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    record OK "systemd-networkd is active (NetworkManager inactive)"
    return
  fi

  local state radio wifi_if="" i
  state=$(timeout 5 nmcli -t -f STATE general 2>/dev/null || true)
  if [[ -z $state ]]; then
    record WARN "NetworkManager is not responding to nmcli"
  elif [[ $state == connected ]]; then
    record OK "NetworkManager state: connected"
  elif [[ -z $DEFAULT_IFACE ]]; then
    record INFO "NetworkManager state: ${state} (no default route expected offline)"
  else
    record WARN "NetworkManager state: ${state}" "a default route exists, so connectivity may be partial"
  fi

  for i in "${PHYS_IFACES[@]}"; do
    if is_wireless "$i"; then wifi_if="$i"; break; fi
  done
  if [[ -n $wifi_if ]]; then
    radio=$(timeout 3 nmcli radio wifi 2>/dev/null || true)
    if [[ $radio == disabled ]]; then
      record WARN "Wi-Fi radio is disabled" "interface ${wifi_if} exists but radio is off"
    fi
  fi
}

check_link_errors() {
  local i="${TARGET_IFACE:-${DEFAULT_IFACE:-}}" stats err drop
  [[ -n $i ]] || return 0
  stats=$(ip -s link show dev "$i" 2>/dev/null | awk '
    /^[[:space:]]+RX:/ { rx = 1; tx = 0; next }
    /^[[:space:]]+TX:/ { tx = 1; rx = 0; next }
    rx && NF >= 6 { rx_err += $3; rx_drop += $4; rx = 0 }
    tx && NF >= 6 { tx_err += $3; tx_drop += $4; tx = 0 }
    END { print rx_err + tx_err, rx_drop + tx_drop }')
  read -r err drop <<< "${stats:-0 0}"
  if [[ $err =~ ^[0-9]+$ ]] && (( err > 100 )); then
    record WARN "interface ${i} reports ${err} errors" "counters are cumulative; check cable/driver"
  elif [[ $drop =~ ^[0-9]+$ ]] && (( drop > 1000 )); then
    record WARN "interface ${i} reports ${drop} dropped packets" "counters are cumulative; check link saturation"
  else
    record OK "interface error counters normal: ${i}"
  fi
}

check_conntrack() {
  local count max pct
  [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]] || return 0
  [[ -r /proc/sys/net/netfilter/nf_conntrack_max ]] || return 0
  count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
  max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
  if [[ $max =~ ^[0-9]+$ ]] && (( max > 0 )); then
    pct=$(( count * 100 / max ))
    if (( pct >= 85 )); then
      record WARN "conntrack table is ${pct}% full" "${count} of ${max} entries"
    else
      record OK "conntrack usage normal" "${pct}%"
    fi
  fi
}

check_network() {
  discover_network
  check_links
  check_addresses
  check_default_route
  check_gateway
  check_dns
  check_networkmanager
  check_link_errors
  check_conntrack
}

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

restart_unit() {
  local unit="$1" why="$2"
  if (( DRY_RUN == 1 )); then
    record FIX "would restart ${unit} (${why})"
    return 0
  fi
  if timeout 30 systemctl restart "$unit" 2>/dev/null; then
    record FIX "restarted ${unit} (${why})"
    return 0
  fi
  record WARN "could not restart ${unit}" "inspect: systemctl status ${unit}"
  return 1
}

recover_system() {
  local actions=0 u mnt opts pct maxc jpath="/var/log/journal" jpct=0
  section "System recovery"
  [[ -d $jpath ]] || jpath="/run/log/journal"
  [[ -d $jpath ]] && { jpct=$(fs_pct "$jpath"); [[ $jpct =~ ^[0-9]+$ ]] || jpct=0; }

  if [[ -d $jpath ]] && (( jpct >= 95 )); then
    actions=$((actions + 1))
    if (( DRY_RUN == 1 )); then
      record FIX "would vacuum the systemd journal to 200 MiB"
    elif have journalctl && systemctl is-active --quiet systemd-journald 2>/dev/null; then
      if timeout 90 journalctl --vacuum-size=200M >/dev/null 2>&1; then
        record FIX "vacuumed the systemd journal to 200 MiB"
      else
        record WARN "journal vacuum failed" "free space manually; offline apt cache was deliberately preserved"
      fi
    else
      record SKIP "disk is full but journald is unavailable" "offline apt cache preserved; free space manually"
    fi
  elif (( $(max_disk_pct) >= 95 )); then
    record SKIP "a filesystem is >= 95% full outside the journal" \
      "free space manually; offline apt cache was deliberately preserved"
    actions=$((actions + 1))
  fi

  mnt="/"
  if have findmnt; then
    opts=$(timeout 5 findmnt -no OPTIONS "$mnt" 2>/dev/null || true)
  fi
  [[ -n $opts ]] || opts=$(awk '$2 == "/" { print $4 }' /proc/mounts)
  if [[ ,$opts, == *,ro,* ]]; then
    record SKIP "root filesystem is read-only" \
      "not auto-remounted: check dmesg for I/O errors and fsck from rescue media"
    actions=$((actions + 1))
  fi

  for u in "${FAILED_UNITS[@]}"; do
    case "$u" in
      systemd-resolved|systemd-timesyncd|systemd-journald)
        restart_unit "$u" "failed unit"
        actions=$((actions + 1))
        ;;
      NetworkManager|systemd-networkd)
        : # handled by network recovery
        ;;
      *)
        record SKIP "failed unit needs manual review: ${u}" "inspect: systemctl status ${u}"
        actions=$((actions + 1))
        ;;
    esac
  done

  pct=$(mem_avail_pct)
  if (( pct < 10 )); then
    record SKIP "memory is low (${pct}% available)" \
      "no process is killed automatically; inspect: ps -eo pid,rss,comm --sort=-rss | head"
    actions=$((actions + 1))
  fi

  if awk -v l="$(load1)" -v n="$(cpu_count)" 'BEGIN { exit !(l > n * 2) }'; then
    record SKIP "system load is high" "no processes are killed automatically; inspect top/ps"
    actions=$((actions + 1))
  fi

  maxc=$(max_thermal_c)
  if (( maxc >= 85 )); then
    record SKIP "temperature is high (${maxc}C)" "improve cooling before adding load"
    actions=$((actions + 1))
  fi

  if (( $(date +%s) < 1577836800 || $(date +%s) > 4102444800 )); then
    record SKIP "system clock is implausible" "offline mode cannot sync time; set it manually"
    actions=$((actions + 1))
  fi

  (( actions == 0 )) && record OK "no system action required"
}

recover_link() {
  local target="$1" activated=0
  section "Network recovery (${target})"

  if ! link_admin_up "$target"; then
    if (( DRY_RUN == 1 )); then
      record FIX "would bring ${target} up"
    elif timeout 10 ip link set dev "$target" up 2>/dev/null; then
      record FIX "brought ${target} up"
      sleep 1
    else
      record WARN "could not bring ${target} up"
    fi
  fi

  if ! link_has_carrier "$target"; then
    if is_wireless "$target"; then
      if nm_active; then
        if [[ $(timeout 3 nmcli radio wifi 2>/dev/null || true) == disabled ]]; then
          if (( DRY_RUN == 1 )); then
            record FIX "would enable the Wi-Fi radio"
          elif timeout 10 nmcli radio wifi on >/dev/null 2>&1; then
            record FIX "enabled the Wi-Fi radio"
            sleep 2
          else
            record WARN "could not enable the Wi-Fi radio"
          fi
        fi
        if ! link_has_carrier "$target" && can_disrupt "$target"; then
          if (( DRY_RUN == 1 )); then
            record FIX "would ask NetworkManager to connect ${target}"
          elif timeout 30 nmcli device connect "$target" >/dev/null 2>&1; then
            record FIX "asked NetworkManager to connect ${target}"
            sleep 3
          else
            record WARN "NetworkManager could not connect ${target}"
          fi
        elif ! link_has_carrier "$target"; then
          record SKIP "Wi-Fi is not associated; connection attempt blocked (SSH path)" \
            "rerun locally or with --allow-disruptive"
        fi
      else
        record SKIP "Wi-Fi has no carrier and NetworkManager is not active" "start NetworkManager or associate manually"
      fi
    else
      record SKIP "${target} has no carrier" "check the cable/switch; no software fix"
    fi
  fi

  if ! has_ipv4 "$target"; then
    if ! link_has_carrier "$target"; then
      record SKIP "no IPv4 on ${target}: link has no carrier" \
        "fix the physical link first; DHCP cannot assign an address"
    elif nm_active; then
      if can_disrupt "$target"; then
        if (( DRY_RUN == 1 )); then
          record FIX "would reapply NetworkManager device ${target}"
        elif timeout 20 nmcli device reapply "$target" >/dev/null 2>&1; then
          record FIX "reapplied NetworkManager device ${target}"
          sleep 2
        else
          record WARN "NetworkManager reapply failed for ${target}"
        fi

        if ! has_ipv4 "$target"; then
          local con
          con=$(nm_con_name "$target")
          if [[ -n $con && $con != "--" && $con != "-- " ]]; then
            if (( DRY_RUN == 1 )); then
              record FIX "would activate NetworkManager connection '${con}'"
              activated=1
            elif timeout 30 nmcli connection up "$con" >/dev/null 2>&1; then
              record FIX "activated NetworkManager connection '${con}'"
              activated=1
              sleep 2
            else
              record WARN "could not activate connection '${con}'"
            fi
          fi
        fi
      else
        record SKIP "no IPv4 on ${target}; disruptive DHCP recovery blocked (SSH path)" \
          "rerun locally or with --allow-disruptive"
      fi
    elif have dhclient && can_disrupt "$target"; then
      if (( DRY_RUN == 1 )); then
        record FIX "would renew DHCP on ${target} with dhclient"
      elif timeout 25 dhclient -1 "$target" >/dev/null 2>&1; then
        record FIX "renewed DHCP on ${target}"
        sleep 1
      else
        record WARN "dhclient failed on ${target}"
      fi
    elif have dhclient; then
      record SKIP "no IPv4 on ${target}; DHCP recovery blocked (SSH path)" \
        "rerun locally or with --allow-disruptive"
    else
      record SKIP "no IPv4 on ${target} and no DHCP client available"
    fi
  fi

  discover_network
  if [[ -z $DEFAULT_IFACE && $activated -eq 0 ]] && nm_active && can_disrupt "$target"; then
    local con
    con=$(nm_con_name "$target")
    if [[ -n $con && $con != "--" && $con != "-- " ]]; then
      if (( DRY_RUN == 1 )); then
        record FIX "would reactivate '${con}' to restore the default route"
      elif timeout 30 nmcli connection up "$con" >/dev/null 2>&1; then
        record FIX "reactivated '${con}' to restore the default route"
        sleep 2
      else
        record WARN "default route still missing after activating '${con}'"
      fi
    fi
  fi

  if [[ -z $DEFAULT_IFACE ]] && systemctl is-failed --quiet NetworkManager 2>/dev/null; then
    if can_disrupt "$target"; then
      restart_unit NetworkManager "no default route and unit failed"
    else
      record SKIP "NetworkManager failed but restart is blocked (SSH path)"
    fi
  fi

  if [[ -z $DEFAULT_IFACE ]] && systemctl is-failed --quiet systemd-networkd 2>/dev/null; then
    if can_disrupt "$target"; then
      restart_unit systemd-networkd "no default route and unit failed"
    else
      record SKIP "systemd-networkd failed but restart is blocked (SSH path)"
    fi
  fi
}

recover_dns() {
  section "DNS recovery"

  if (( DNS_BAD == 0 )); then
    record OK "DNS configuration usable; no action required"
    return
  fi

  if have systemctl && systemctl cat systemd-resolved.service >/dev/null 2>&1; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      if (( DNS_BAD == 1 )); then
        if (( DRY_RUN == 1 )); then
          record FIX "would flush the systemd-resolved cache"
        elif have resolvectl && timeout 5 resolvectl flush-caches >/dev/null 2>&1; then
          record FIX "flushed the systemd-resolved cache"
        else
          record WARN "could not flush the DNS cache"
        fi
      fi
    else
      restart_unit systemd-resolved "resolver inactive"
    fi
  fi

  local rc="/etc/resolv.conf" ts
  if [[ ! -s $rc ]] || ! grep -qE '^[[:space:]]*nameserver[[:space:]]+' "$rc" 2>/dev/null; then
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
      if (( DRY_RUN == 1 )); then
        record FIX "would restore ${rc} -> /run/systemd/resolve/stub-resolv.conf"
      else
        ts=$(date +%Y%m%d-%H%M%S)
        if [[ -e $rc || -L $rc ]]; then
          cp -a -- "$rc" "${rc}.bak.${ts}" 2>/dev/null || true
        fi
        rm -f -- "$rc"
        if ln -s /run/systemd/resolve/stub-resolv.conf "$rc" 2>/dev/null; then
          record FIX "restored ${rc} to the systemd-resolved stub" "backup: ${rc}.bak.${ts}"
        else
          record WARN "could not restore ${rc}"
        fi
      fi
    else
      record SKIP "${rc} has no usable nameserver" "no resolved stub available; configure DNS manually"
    fi
  fi
}

recover_network() {
  PROTECTED_IFACE=""
  local net_fix_before=$FIX_COUNT
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    local client="${SSH_CONNECTION%% *}"
    PROTECTED_IFACE=$(ip -4 route get "$client" 2>/dev/null | route_field dev)
  fi

  local target="${IFACE:-$DEFAULT_IFACE}"
  if [[ -z $target ]]; then
    # No default route: prefer a live link, then a wireless interface that
    # can be associated, then fall back to the first physical interface.
    local i
    for i in "${PHYS_IFACES[@]}"; do
      if link_admin_up "$i" && link_has_carrier "$i"; then target="$i"; break; fi
    done
    if [[ -z $target ]]; then
      for i in "${PHYS_IFACES[@]}"; do
        if is_wireless "$i"; then target="$i"; break; fi
      done
    fi
    [[ -z $target && ${#PHYS_IFACES[@]} -gt 0 ]] && target="${PHYS_IFACES[0]}"
  fi

  if [[ -n $target ]]; then
    local fix_before=$FIX_COUNT skip_before=$SKIP_COUNT
    recover_link "$target"
    if (( FIX_COUNT == fix_before && SKIP_COUNT == skip_before )); then
      record OK "no link/IP action required on ${target}"
    fi
  else
    section "Network recovery"
    record SKIP "no physical interface available" "check hardware/rfkill; DNS recovery continues"
  fi

  # A link/IP change can invalidate cached resolver state.
  (( FIX_COUNT > net_fix_before )) && DNS_BAD=1

  recover_dns
}

# ---------------------------------------------------------------------------
# Export bundle
# ---------------------------------------------------------------------------

collect_to() {
  local file="$1"; shift
  {
    printf '$ %s\n' "$*"
    timeout 15 "$@" 2>&1
  } > "$file" || true
}

export_bundle() {
  local ts out dir="$EXPORT_DIR"
  ts=$(date +%Y%m%d-%H%M%S)
  out="${dir}/sysnet-${ts}"

  if ! mkdir -p -- "$dir" 2>/dev/null || ! mkdir -m 700 -- "$out" 2>/dev/null; then
    record WARN "cannot write export bundle to ${dir}"
    return 1
  fi

  {
    echo "sysnet-recover export"
    echo "time: $(date -Is)"
    echo "host: $(hostname 2>/dev/null || echo unknown)"
    echo "kernel: $(uname -a)"
    echo "action: ${ACTION} dry_run=${DRY_RUN}"
    echo "counts: ok=${OK_COUNT} warn=${WARN_COUNT} fail=${FAIL_COUNT} fix=${FIX_COUNT} skip=${SKIP_COUNT}"
    echo "note: may contain local addresses, interface names and MACs; review before sharing"
  } > "$out/00-summary.txt"

  collect_to "$out/10-ip-addr.txt" ip addr show
  collect_to "$out/11-ip-route.txt" ip route show
  collect_to "$out/12-ip-neigh.txt" ip neigh show
  collect_to "$out/13-ip-link-stats.txt" ip -s link show
  collect_to "$out/20-resolv.txt" cat /etc/resolv.conf
  collect_to "$out/21-nsswitch.txt" cat /etc/nsswitch.conf
  have resolvectl && collect_to "$out/22-resolvectl.txt" resolvectl status
  have nmcli && collect_to "$out/30-nm-general.txt" nmcli general status
  have nmcli && collect_to "$out/31-nm-devices.txt" nmcli device status
  have nmcli && collect_to "$out/32-nm-active.txt" nmcli connection show --active
  have systemctl && collect_to "$out/40-systemd-failed.txt" systemctl --failed --no-pager
  collect_to "$out/41-journal-errors.txt" journalctl -b -p 3 -n 500 --no-pager
  collect_to "$out/42-kernel-log.txt" journalctl -k -b -n 500 --no-pager
  collect_to "$out/50-df.txt" df -hT
  collect_to "$out/51-inodes.txt" df -i
  collect_to "$out/52-free.txt" free -m
  collect_to "$out/53-uptime.txt" uptime
  collect_to "$out/54-lsblk.txt" lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,RO
  have ss && collect_to "$out/60-sockets.txt" ss -s
  have sensors && collect_to "$out/61-sensors.txt" sensors
  collect_to "$out/70-timedate.txt" timedatectl

  [[ -r $LOG ]] && cp -- "$LOG" "$out/90-run.log" 2>/dev/null || true
  chmod -R go-rwx -- "$out" 2>/dev/null || true

  if have tar && timeout 30 tar -C "$dir" -czf "${out}.tar.gz" "$(basename "$out")" 2>/dev/null; then
    chmod 600 -- "${out}.tar.gz" 2>/dev/null || true
    say "Diagnostic bundle: ${out}.tar.gz"
  else
    say "Diagnostic bundle directory: ${out}"
  fi
}

# ---------------------------------------------------------------------------
# Summary / main
# ---------------------------------------------------------------------------

print_summary() {
  section "Summary"
  say "OK=${OK_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT} FIX=${FIX_COUNT} SKIP=${SKIP_COUNT}"
  if (( ${#FAIL_MSGS[@]} > 0 )); then
    if [[ $ACTION == "recover" ]]; then
      say "Remaining failures:"
    else
      say "Failures:"
    fi
    local m
    for m in "${FAIL_MSGS[@]}"; do say "  - ${m}"; done
  fi
  if (( ${#WARN_MSGS[@]} > 0 )); then
    say "Warnings:"
    local n=0 m
    for m in "${WARN_MSGS[@]}"; do
      say "  - ${m}"
      n=$((n + 1))
      (( n >= 10 )) && { say "  ..."; break; }
    done
  fi
  say "Log: ${LOG}"
  say "Offline-safe: no downloads, package installs, firewall changes or reboots."
  if [[ $ACTION == "diagnose" ]] && (( FAIL_COUNT > 0 )); then
    say "Next: sysnet-recover.sh recover --dry-run (add sudo for a real recovery)."
  fi
}

main() {
  if (( $# == 0 )); then
    ACTION="diagnose"
  else
    case "$1" in
      diagnose|check|status) ACTION="diagnose"; shift ;;
      recover|fix|repair)    ACTION="recover"; shift ;;
      -h|--help)             usage; exit 0 ;;
      --version)             printf 'sysnet-recover %s\n' "$VERSION"; exit 0 ;;
      -*)                    : ;;
      *) die "unknown action: $1 (use diagnose or recover)" ;;
    esac
  fi

  while (( $# > 0 )); do
    case "$1" in
      --dry-run)          DRY_RUN=1 ;;
      --allow-disruptive) ALLOW_DISRUPTIVE=1 ;;
      --no-probe)         NO_PROBE=1 ;;
      --quiet)            QUIET=1 ;;
      --iface)            [[ $# -ge 2 && -n $2 ]] || die "--iface needs an interface name"; IFACE="$2"; shift ;;
      --iface=*)          IFACE="${1#*=}"; [[ -n $IFACE ]] || die "--iface needs an interface name" ;;
      --export)           [[ $# -ge 2 && -n $2 ]] || die "--export needs a directory"; EXPORT_DIR="$2"; shift ;;
      --export=*)         EXPORT_DIR="${1#*=}"; [[ -n $EXPORT_DIR ]] || die "--export needs a directory" ;;
      -h|--help)          usage; exit 0 ;;
      --version)          printf 'sysnet-recover %s\n' "$VERSION"; exit 0 ;;
      *)                  die "unknown option: $1" ;;
    esac
    shift
  done

  [[ -n $IFACE && ! -e "/sys/class/net/$IFACE" ]] && die "interface not found: ${IFACE}"

  for c in ip df free awk sed grep timeout date paste tee; do
    have "$c" || die "required command missing: ${c}" 4
  done

  if [[ $ACTION == "recover" ]] && (( EUID != 0 )) && (( DRY_RUN == 0 )); then
    die "recover requires root; re-run the same command with sudo" 4
  fi

  init_log

  say "sysnet-recover ${VERSION} - action=${ACTION} dry_run=${DRY_RUN}"
  say "Host: $(hostname 2>/dev/null || echo unknown) | Kernel: $(uname -r)"
  say "Mode: offline-safe (local probes only; no internet access required)"
  say "Log: ${LOG}"

  section "System checks"
  check_system
  section "Network checks"
  check_network

  local pre="" pre_fix=0 pre_skip=0
  if [[ $ACTION == "recover" ]]; then
    pre="OK=${OK_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT} FIX=${FIX_COUNT} SKIP=${SKIP_COUNT}"
    section "Recovery"
    recover_system
    recover_network

    if (( DRY_RUN == 0 )) && (( FIX_COUNT > 0 )); then
      pre_fix=$FIX_COUNT
      pre_skip=$SKIP_COUNT
      reset_counts
      section "Verification"
      check_system
      check_network
      FIX_COUNT=$((FIX_COUNT + pre_fix))
      SKIP_COUNT=$((SKIP_COUNT + pre_skip))
    fi
  fi

  if [[ -n $EXPORT_DIR ]]; then
    section "Export"
    export_bundle
  fi

  if [[ $ACTION == "recover" ]]; then
    say ""
    say "Before recovery: ${pre}"
  fi
  print_summary

  if (( FAIL_COUNT > 0 )); then exit 2; fi
  if (( WARN_COUNT > 0 )); then exit 1; fi
  exit 0
}

main "$@"
