#!/usr/bin/env bash
# Wi-Fi diagnostic for macOS and Linux.
# Read-only: it measures and reports, it changes no settings.
# Usage: bash wifi-check.sh
set -u
OS=$(uname -s)
FINDINGS=()
add() { FINDINGS+=("$1"); }
hr() { printf '\n== %s ==\n' "$1"; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

# ---------- Router / gateway ----------
hr "Router"
if [ "$OS" = Darwin ]; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
else
  GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
  IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
fi
echo "Router address: ${GW:-unknown}   Interface: ${IFACE:-unknown}"
DEVICES=$(arp -an 2>/dev/null | grep -vc incomplete)
echo "Devices seen on the network: $DEVICES"

# ---------- Latency ----------
# ping_stats HOST -> sets LOSS AVG JIT
ping_stats() {
  local out
  out=$(ping -c 20 -i 0.2 "$1" 2>/dev/null) || out=$(ping -c 10 "$1" 2>/dev/null)
  LOSS=$(printf '%s\n' "$out" | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
  read -r AVG JIT < <(printf '%s\n' "$out" | tail -1 | awk -F'= ' '{print $2}' | awk -F'/' '{print $2, $4}')
  LOSS=${LOSS:-100}; AVG=${AVG:-0}; JIT=${JIT:-0}
}

hr "Latency (20 pings each)"
if [ -n "${GW:-}" ]; then
  ping_stats "$GW"; GW_AVG=$AVG
  printf 'To router:   avg %s ms, jitter %s ms, loss %s%%\n' "$AVG" "$JIT" "$LOSS"
  gt "$AVG" 10 && add "Slow link to the router (avg ${AVG} ms; should be under 5 ms). The problem is between this device and the router: weak signal or interference."
  gt "$LOSS" 1 && add "Packet loss to the router (${LOSS}%). Usually weak signal or interference. Move closer or reduce obstacles."
  gt "$JIT" 15 && add "Unstable link to the router (jitter ${JIT} ms). Usually a crowded channel or interference."
fi
ping_stats 1.1.1.1; NET_AVG=$AVG
printf 'To internet: avg %s ms, jitter %s ms, loss %s%%\n' "$AVG" "$JIT" "$LOSS"
gt "$AVG" 60 && add "High internet latency (${AVG} ms). If the router link above is fine, the delay is on the modem/ISP side."
gt "$LOSS" 1 && add "Packet loss to the internet (${LOSS}%). If the router link has none, contact your ISP or reboot the modem."

# ---------- Wi-Fi radio ----------
hr "Wi-Fi radio"
SIG=""; CHAN=""; BAND=""; RATE=""; SAME=0; NEARBY=0
if [ "$OS" = Darwin ]; then
  SP=$(system_profiler SPAirPortDataType 2>/dev/null)
  CUR=$(printf '%s\n' "$SP" | awk '/Current Network Information:/{f=1;next} /Other Local Wi-Fi Networks:/{f=0} f')
  SIG=$(printf '%s\n' "$CUR" | awk -F': ' '/Signal \/ Noise/{split($2,a," "); print a[1]; exit}')
  CHLINE=$(printf '%s\n' "$CUR" | awk -F': ' '/Channel:/{print $2; exit}')
  CHAN=${CHLINE%% *}
  case "$CHLINE" in *2GHz*) BAND=2.4;; *5GHz*) BAND=5;; *6GHz*) BAND=6;; esac
  RATE=$(printf '%s\n' "$CUR" | awk -F': ' '/Transmit Rate/{print $2; exit}')
  OTHER=$(printf '%s\n' "$SP" | awk '/Other Local Wi-Fi Networks:/{f=1} f && /Channel:/{split($0,a,": "); split(a[2],b," "); print b[1]}')
else
  if command -v iw >/dev/null && [ -n "${IFACE:-}" ]; then
    LINK=$(iw dev "$IFACE" link 2>/dev/null)
    SIG=$(printf '%s\n' "$LINK" | awk '/signal:/{print $2; exit}')
    FREQ=$(printf '%s\n' "$LINK" | awk '/freq:/{print int($2); exit}')
    RATE=$(printf '%s\n' "$LINK" | awk -F': ' '/tx bitrate/{print $2; exit}')
    if [ -n "${FREQ:-}" ]; then
      if [ "$FREQ" -lt 3000 ]; then BAND=2.4; elif [ "$FREQ" -lt 5925 ]; then BAND=5; else BAND=6; fi
    fi
  fi
  if command -v nmcli >/dev/null; then
    LIST=$(nmcli -t -f ACTIVE,CHAN,SIGNAL dev wifi list 2>/dev/null)
    CHAN=$(printf '%s\n' "$LIST" | awk -F: '$1=="yes"{print $2; exit}')
    if [ -z "$SIG" ]; then
      PCT=$(printf '%s\n' "$LIST" | awk -F: '$1=="yes"{print $3; exit}')
      [ -n "$PCT" ] && SIG=$(( PCT / 2 - 100 ))
    fi
    OTHER=$(printf '%s\n' "$LIST" | awk -F: '$1!="yes"{print $2}')
  fi
fi
if [ -n "${OTHER:-}" ]; then
  NEARBY=$(printf '%s\n' "$OTHER" | grep -c .)
  [ -n "$CHAN" ] && SAME=$(printf '%s\n' "$OTHER" | grep -cx "$CHAN")
fi
echo "Signal: ${SIG:-unknown} dBm   Band: ${BAND:-unknown} GHz   Channel: ${CHAN:-unknown}   Link rate: ${RATE:-unknown}"
echo "Other networks nearby: $NEARBY   On your channel: $SAME"

if [ -n "$SIG" ]; then
  if lt "$SIG" -70; then add "Weak signal (${SIG} dBm; good is above -60). Move the router to a central, raised, open spot, away from walls, metal, microwaves and fish tanks, or add a mesh node / access point."
  elif lt "$SIG" -60; then add "Fair signal (${SIG} dBm). Moving the router to a more central spot would help."; fi
fi
[ "$BAND" = "2.4" ] && add "You're on 2.4 GHz, which is slower and more crowded. If the router also broadcasts 5 GHz, connect to that one (give the bands separate names in the router settings if they're merged)."
if [ "$BAND" = "2.4" ] && [ -n "$CHAN" ] && ! printf '%s' "$CHAN" | grep -qxE '1|6|11'; then
  add "2.4 GHz channel $CHAN overlaps its neighbours. In the router settings, set the 2.4 GHz channel to 1, 6 or 11, whichever has fewest networks."
fi
[ "$SAME" -ge 3 ] && add "$SAME other networks share your channel $CHAN. In the router settings, pick a less crowded channel (or set it to Auto and reboot the router)."

# ---------- Speed and bufferbloat ----------
hr "Speed test (Cloudflare)"
DL=$(curl -s -o /dev/null -m 30 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000')
DL_MBPS=$(awk -v b="${DL:-0}" 'BEGIN{printf "%.1f", b*8/1e6}')
UL=$(head -c 10000000 /dev/zero | curl -s -o /dev/null -m 30 -w '%{speed_upload}' --data-binary @- https://speed.cloudflare.com/__up)
UL_MBPS=$(awk -v b="${UL:-0}" 'BEGIN{printf "%.1f", b*8/1e6}')
echo "Download: $DL_MBPS Mbps   Upload: $UL_MBPS Mbps"
echo "(Compare with the speed on your internet plan.)"

echo "Measuring latency while the line is busy..."
TMP=$(mktemp)
ping -c 15 -i 0.3 1.1.1.1 >"$TMP" 2>/dev/null &
PID=$!
curl -s -o /dev/null -m 15 'https://speed.cloudflare.com/__down?bytes=100000000'
wait "$PID" 2>/dev/null
LOADED=$(tail -1 "$TMP" | awk -F'= ' '{print $2}' | awk -F'/' '{print $2}')
rm -f "$TMP"
if [ -n "$LOADED" ]; then
  echo "Latency idle: ${NET_AVG} ms   while downloading: ${LOADED} ms"
  INC=$(awk -v a="$LOADED" -v b="$NET_AVG" 'BEGIN{printf "%d", a-b}')
  [ "$INC" -gt 100 ] && add "Bufferbloat: latency jumps by ${INC} ms when the line is busy, so calls/games lag whenever someone downloads. Turn on SQM / Smart Queue / QoS in the router settings."
fi

# ---------- Summary ----------
hr "What's slowing you down"
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  echo "No clear problems found. If it still feels slow, run this again while it's slow, and compare the speed above with your plan."
else
  i=1; for f in "${FINDINGS[@]}"; do printf '%d. %s\n' "$i" "$f"; i=$((i+1)); done
fi
echo
echo "Also worth doing: reboot the router and modem, update the router firmware, and check the router's device list for devices you don't recognise."
