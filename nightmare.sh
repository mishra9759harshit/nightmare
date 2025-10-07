#!/usr/bin/env bash
#
# termux_tui_dashboard.sh
# Live TUI Termux dashboard — token-based (.env) GitHub / Vercel / Render / Device status + quick-run tools
# Author: Secure Coder (updated)
# NOTE: Tokens are read from a .env file and NOT stored inside the script.

set -euo pipefail
IFS=$'\n\t'

# ---------- CONFIG / DEFAULTS ----------
ENV_FILES=(./.env "$HOME/.termux_status.env")
REFRESH_INTERVAL=10          # overridden by .env REFRESH_INTERVAL (seconds)
LOG_DIR="$HOME/status_logs"
PROJECTS=()                  # space-separated URLs in .env PROJECTS
OSINT_SCRIPT="$HOME/nightmare_pro.sh"
WIFI_TOOL_PY="$HOME/wifitool.py"

# ---------- COLORS ----------
ESC="$(printf '\033')"
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
RED="${ESC}[31m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
BLUE="${ESC}[34m"
MAGENTA="${ESC}[35m"
CYAN="${ESC}[36m"
WHITE="${ESC}[37m"

# ---------- UTILS ----------
info()    { printf "%b\n" "${CYAN}[i]${RESET} $*"; }
warn()    { printf "%b\n" "${YELLOW}[!]${RESET} $*"; }
err()     { printf "%b\n" "${RED}[x]${RESET} $*"; }
success() { printf "%b\n" "${GREEN}[✓]${RESET} $*"; }

# Load .env
load_env() {
  for f in "${ENV_FILES[@]}"; do
    [ -f "$f" ] || continue
    set -o allexport
    while IFS= read -r line || [ -n "$line" ]; do
      line_trim="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      case "$line_trim" in
        ''|\#*) continue ;;
        *=*)
          key=$(printf "%s" "$line_trim" | sed -E 's/=.*//')
          val=$(printf "%s" "$line_trim" | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
          [[ "$key" =~ ^[A-Z0-9_]+$ ]] && export "$key"="$val"
          ;;
      esac
    done <"$f"
    set +o allexport
    info "Loaded env from: $f"
    break
  done

  : "${REFRESH_INTERVAL:=$REFRESH_INTERVAL}"
  if [ -n "${PROJECTS:-}" ]; then
    read -r -a PROJECTS <<<"$PROJECTS"
  fi
}

# Dependency check
check_deps(){
  local need=(curl jq ip ss)
  local missing=()
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing tools: ${missing[*]}"
    warn "Install with: pkg update && pkg install -y ${missing[*]}"
  fi
}

# Create log dir
mkdir -p "$LOG_DIR"

# Safe HTTP helper
http_get(){
  local url="$1"
  local token="$2"
  [ -n "$token" ] && curl -sS -H "Authorization: Bearer $token" -H "User-Agent: Termux-TUI/1.0" "$url" || curl -sS -H "User-Agent: Termux-TUI/1.0" "$url"
}

# ---------- API FETCHERS ----------
github_fetch(){
  [ -z "${GITHUB_TOKEN:-}" ] && echo "GITHUB_TOKEN not set" && return
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/user/repos?per_page=50&sort=updated" \
    | jq -r '[.[] | {name:.full_name, private:.private, stars:.stargazers_count, updated:.updated_at, url:.html_url}] | sort_by(.updated) | reverse | .[0:6][] | "\(.name) • \(.private|tostring) • ★\(.stars) • updated:\(.updated) • \(.url)"'
}

github_actions_status(){
  local repo="$1"
  [ -z "${GITHUB_TOKEN:-}" ] && echo "GITHUB_TOKEN not set" && return
  local r=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/${repo}/actions/runs?per_page=1")
  echo "$r" | jq -r '.workflow_runs[0] | "\(.name // "workflow") — \(.conclusion // .status) — \(.html_url)"' 2>/dev/null || echo "—"
}

vercel_fetch(){
  [ -z "${VERCEL_TOKEN:-}" ] && echo "VERCEL_TOKEN not set" && return
  local projects=$(curl -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "https://api.vercel.com/v8/projects")
  echo "$projects" | jq -r '.projects[0:6][] | "\(.name) • id:\(.id) • org:\(.team?.name // "personal")"'
}

vercel_last_deploy(){
  local projectId="$1"
  [ -z "${VERCEL_TOKEN:-}" ] && echo "—" && return
  local r=$(curl -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "https://api.vercel.com/v12/now/deployments?projectId=${projectId}&limit=1")
  echo "$r" | jq -r '.deployments[0] | "\(.state // "unknown") — \(.url // .name // "n/a") — created:\(.createdAt // 0)"' 2>/dev/null || echo "—"
}

render_fetch(){
  [ -z "${RENDER_TOKEN:-}" ] && echo "RENDER_TOKEN not set" && return
  local r=$(curl -sS -H "Authorization: Bearer ${RENDER_TOKEN}" "https://api.render.com/v1/services")
  echo "$r" | jq -r '.[] | "\(.name) • state:\(.state) • url:\(.serviceDetails?.webURL // .url // "n/a")"'
}

# ---------- DEVICE STATUS ----------
device_summary(){
  local ips=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ' || true)
  [ -z "$ips" ] && ips=$(hostname -I 2>/dev/null || echo "N/A")
  local bat="N/A"
  command -v termux-battery-status >/dev/null 2>&1 && bat=$(termux-battery-status | jq -r '"\(.percentage)% (\(.health // "unknown"))"')
  local uptime_text=$(uptime -p 2>/dev/null || echo "N/A")
  local load=$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo "N/A")
  local mem=$(command -v free >/dev/null 2>&1 && free -h | awk 'NR==2{print $3"/"$2}' || echo "N/A")
  printf "IP(s): %s\nBattery: %s\nUptime: %s\nLoad: %s\nMemory: %s\n" "$ips" "$bat" "$uptime_text" "$load" "$mem"
}

# ---------- PORTS / NETWORK ----------
listening_sockets(){
  command -v ss >/dev/null 2>&1 && ss -tulpen 2>/dev/null || command -v netstat >/dev/null 2>&1 && netstat -tulpen 2>/dev/null || echo "ss/netstat not available"
}

nmap_scan_local(){
  command -v nmap >/dev/null 2>&1 || { echo "nmap not installed"; return; }
  local ip_local=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)
  [ -z "$ip_local" ] && { echo "Could not determine local IP"; return; }
  echo "Running quick nmap -sT -Pn -F on $ip_local"
  nmap -sT -Pn -F "$ip_local"
}

run_osint(){ [ -x "${OSINT_SCRIPT}" ] && "${OSINT_SCRIPT}" & || echo "OSINT script missing or not executable"; }
run_wifi(){
  [ -f "${WIFI_TOOL_PY}" ] || { echo "WiFi tool not found"; return 1; }
  (command -v python3 >/dev/null && python3 "${WIFI_TOOL_PY}" & ) || (command -v python && python "${WIFI_TOOL_PY}" & )
}

# ---------- LOGGING ----------
log_snapshot(){
  local stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local outfile="$LOG_DIR/$(date +%F).log"
  {
    printf "==== Snapshot %s ====\n" "$stamp"
    printf "-- Device --\n"; device_summary
    printf "\n-- GitHub --\n"; github_fetch | sed -n '1,20p'
    printf "\n-- Vercel --\n"; vercel_fetch | sed -n '1,20p'
    printf "\n-- Render --\n"; render_fetch | sed -n '1,20p'
    printf "\n-- Listening --\n"; listening_sockets | sed -n '1,20p'
    printf "\n\n"
  } >>"$outfile"
  chmod 600 "$outfile" || true
}

# ---------- TUI ----------
draw_header(){
  tput cup 0 0
  printf "%b" "${BOLD}${BLUE}Termux Live Dashboard${RESET}"
  tput cup 0 $(( COLUMNS - 30 ))
  printf "%b" "${YELLOW}Refresh: ${REFRESH_INTERVAL}s${RESET}"
  tput cup 1 0
  printf "%b" "Press ${BOLD}G${RESET}=GitHub  ${BOLD}V${RESET}=Vercel  ${BOLD}R${RESET}=Render  ${BOLD}D${RESET}=Device  ${BOLD}P${RESET}=Ports  ${BOLD}O${RESET}=OSINT  ${BOLD}W${RESET}=WiFi  ${BOLD}N${RESET}=nmap  ${BOLD}L${RESET}=Log  ${BOLD}Q${RESET}=Quit"
}

draw_box(){
  local r="$1" c="$2" w="$3" h="$4" title="$5"
  tput cup "$r" "$c"; printf "+"; for ((i=1;i<w-1;i++)); do printf "-"; done; printf "+"
  for ((row=r+1;row<r+h-1;row++)); do tput cup $row "$c"; printf "|"; tput cup $row $((c+w-1)); printf "|"; done
  tput cup $((r+h-1)) "$c"; printf "+"; for ((i=1;i<w-1;i++)); do printf "-"; done; printf "+"
  tput cup "$r" $((c+2)); printf "%b" "${BOLD}${title}${RESET}"
}

render_lines_box(){
  local r="$1" c="$2" w="$3" h="$4"; shift; local lines=( "$@" ); local max=$((h-2))
  for i in $(seq 0 $((max-1))); do
    tput cup $((r+1+i)) $((c+1))
    [ $i -lt ${#lines[@]} ] && printf "%-${w}s" "${lines[$i]:0:$((w-2))}" || printf "%-${w}s" " "
  done
}

# ---------- MAIN LOOP ----------
main_loop(){
  trap 'tput cnorm; clear; exit' INT TERM EXIT
  tput civis
  while true; do
    clear
    COLUMNS=$(tput cols || echo 80)
    LINES=$(tput lines || echo 24)
    left_w=$((COLUMNS/2-2)); [ "$left_w" -lt 20 ] && left_w=20
    right_w=$((COLUMNS-left_w-4)); [ "$right_w" -lt 20 ] && right_w=20
    top_h=$(( (LINES-6)/2 )); [ "$top_h" -lt 5 ] && top_h=5
    bottom_h=$((LINES-top_h-6)); [ "$bottom_h" -lt 5 ] && bottom_h=5

    draw_header
    draw_box 3 0 $left_w $top_h "GitHub"
    draw_box 3 $((left_w+2)) $right_w $top_h "Vercel / Render"
    draw_box $((3+top_h+1)) 0 $COLUMNS $((bottom_h+3)) "Device & Ports"

    mapfile -t gh_lines < <(github_fetch 2>/dev/null || echo "No GitHub data")
    mapfile -t ver_lines < <(vercel_fetch 2>/dev/null || echo "No Vercel data")
    mapfile -t render_lines < <(render_fetch 2>/dev/null || echo "No Render data")
    mapfile -t dev_lines < <(device_summary)
    mapfile -t ports_lines < <(listening_sockets | head -n20)

    render_lines_box 3 0 $left_w $top_h "${gh_lines[@]}"
    render_lines_box 3 $((left_w+2)) $right_w $top_h "${ver_lines[@]}" "${render_lines[@]}"
    bottom_content=()
    bottom_content+=("Device summary:")
    bottom_content+=("${dev_lines[@]}")
    bottom_content+=("")
    bottom_content+=("Listening sockets:")
    bottom_content+=("${ports_lines[@]}")
    bottom_content+=("")
    bottom_content+=("Shortcuts: [O] OSINT  [W] WiFi  [N] nmap  [L] Log snapshot  [Q] Quit")
    render_lines_box $((3+top_h+1)) 0 $COLUMNS $((bottom_h+3)) "${bottom_content[@]}"

    log_snapshot &>/dev/null &

    read -rsn1 -t "$REFRESH_INTERVAL" key 2>/dev/null || key=""
    case "$key" in
      G|g) clear; github_fetch; echo "Press ENTER"; read -r _;;
      V|v) clear; vercel_fetch; echo "Press ENTER"; read -r _;;
      R|r) clear; render_fetch; echo "Press ENTER"; read -r _;;
      D|d) clear; device_summary; echo "Press ENTER"; read -r _;;
      P|p) clear; listening_sockets; echo "Press ENTER"; read -r _;;
      O|o) run_osint;;
      W|w) run_wifi;;
      N|n) nmap_scan_local;;
      L|l) log_snapshot;;
      Q|q) break;;
    esac
  done
  tput cnorm
  clear
}

# ---------- START ----------
load_env
check_deps
main_loop