#!/usr/bin/env bash

# Live TUI Termux dashboard — token-based (.env) GitHub / Vercel / Render / Device status + quick-run tools
# Author: Secure Coder (generated & fixed)

set -euo pipefail
IFS=$'\n\t'

---------- CONFIG / DEFAULTS ----------
ENV_FILES=(./.env "$HOME/.termux_status.env")
REFRESH_INTERVAL=30 # default refresh interval in seconds
LOG_DIR="$HOME/status_logs"
PROJECTS=() # space-separated URLs in .env PROJECTS
OSINT_SCRIPT="$HOME/nightmare_pro.sh"
WIFI_TOOL_PY="$HOME/wifitool.py"

---------- COLORS ----------
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

---------- UTILS ----------
info() { printf "%b\n" "${CYAN}[i]${RESET} $*\n"; }
warn() { printf "%b\n" "${YELLOW}[!]${RESET} $*\n"; }
err() { printf "%b\n" "${RED}[x]${RESET} $*\n"; }
success() { printf "%b\n" "${GREEN}[✓]${RESET} $*\n"; }

# Load .env files with safe parsing, export vars (supports KEY=VALUE, ignores comments and blank lines)
load_env() {
  for f in "${ENV_FILES[@]}"; do
    if [ -f "$f" ]; then
      info "Loading env from: $f"
      while IFS= read -r line || [ -n "$line" ]; do
        # trim whitespace
        line_trim="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # skip blank lines and comments
        [[ -z "$line_trim" || "$line_trim" =~ ^# ]] && continue
        # match KEY=VALUE pattern safely
        if [[ "$line_trim" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
          key="${BASH_REMATCH[1]}"
          val="${BASH_REMATCH[2]}"
          # remove optional surrounding quotes from val
          val="${val%\"}"
          val="${val#\"}"
          # export variable
          export "$key"="$val"
        fi
      done <"$f"
      break  # stop after first valid env file loaded
    fi
  done

  # Apply defaults and parse PROJECTS array if set
  : "${REFRESH_INTERVAL:=30}"
  if [ -n "${PROJECTS:-}" ]; then
    read -r -a PROJECTS <<<"$PROJECTS"
  fi
  : "${OSINT_SCRIPT:=$HOME/nightmare_pro.sh}"
  : "${WIFI_TOOL_PY:=$HOME/wifitool.py}"
}

# Check dependencies, suggest install commands for missing tools
check_deps() {
  local need=(curl jq tput ip termux-battery-status)
  local missing=()
  for c in "${need[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing tools: ${missing[*]}"
    warn "Install with: pkg update && pkg install -y ${missing[*]}"
  fi
}

mkdir -p "$LOG_DIR"

# Safe HTTP get helper with optional Bearer token header
http_get() {
  local url="$1"
  local token="$2"
  if [ -n "$token" ]; then
    curl -sS -H "Authorization: Bearer $token" -H "User-Agent: Termux-TUI/1.0" "$url"
  else
    curl -sS -H "User-Agent: Termux-TUI/1.0" "$url"
  fi
}

---------- API FETCHERS ----------

# GitHub: list repos + last commit + actions (best-effort)
github_fetch() {
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN not set"
    return
  fi
  local repos_json
  repos_json=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/user/repos?per_page=50&sort=updated")
  if [ -z "$repos_json" ]; then
    echo "Failed to query GitHub API"
    return
  fi
  echo "$repos_json" | jq -r '
    [ .[] | {name: .full_name, private: .private, stars: .stargazers_count, updated: .updated_at, default_branch: .default_branch, url: .html_url}]
    | sort_by(.updated) | reverse | .[0:6]
    | .[] | "\(.name) • \(.private) • ★\(.stars) • updated: \(.updated) • \(.url)"'
}

# GitHub: fetch Actions status for a repo (best-effort)
github_actions_status() {
  local repo="$1"
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN not set"
    return
  fi
  local api="https://api.github.com/repos/${repo}/actions/runs?per_page=1"
  local r
  r=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "$api")
  if [ -z "$r" ]; then
    echo "—"
    return
  fi
  echo "$r" | jq -r '.workflow_runs[0] | "\(.name // "workflow") — \(.conclusion // .status) — \(.html_url)"' 2>/dev/null || echo "—"
}

# Vercel: list projects (v8 endpoint)
vercel_fetch() {
  if [ -z "${VERCEL_TOKEN:-}" ]; then
    echo "VERCEL_TOKEN not set"
    return
  fi
  local projects
  projects=$(curl -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "https://api.vercel.com/v8/projects")
  if [ -z "$projects" ]; then
    echo "Failed to query Vercel API"
    return
  fi
  echo "$projects" | jq -r '.projects[0:6][] | "\(.name) • id:\(.id) • org:\(.team?.name // "personal")"'
}

# Vercel: last deployment for a project
vercel_last_deploy() {
  local projectId="$1"
  if [ -z "${VERCEL_TOKEN:-}" ] || [ -z "$projectId" ]; then
    echo "—"
    return
  fi
  local url="https://api.vercel.com/v12/now/deployments?projectId=${projectId}&limit=1"
  local r
  r=$(curl -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "$url")
  echo "$r" | jq -r '.deployments[0] | "\(.state // "unknown") — \(.url // .name // "n/a") — created: \(.createdAt // 0)"' 2>/dev/null || echo "—"
}

# Render: list services
render_fetch() {
  if [ -z "${RENDER_TOKEN:-}" ]; then
    echo "RENDER_TOKEN not set"
    return
  fi
  local r
  r=$(curl -sS -H "Authorization: Bearer ${RENDER_TOKEN}" "https://api.render.com/v1/services")
  if [ -z "$r" ]; then
    echo "Failed to query Render API"
    return
  fi
  echo "$r" | jq -r '.[] | "\(.name) • state:\(.state) • url: \(.serviceDetails?.webURL // .url // "n/a")"'
}

---------- DEVICE STATUS ----------

device_summary() {
  # IP(s)
  local ips
  ips=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ' || true)
  if [ -z "$ips" ]; then
    ips=$(hostname -I 2>/dev/null || echo "N/A")
  fi
  # Battery (termux-api)
  local bat="N/A"
  if command -v termux-battery-status >/dev/null 2>&1; then
    bat=$(termux-battery-status | jq -r '"\(.percentage)% ((\(.health // "unknown")))"')
  fi
  local uptime_text
  uptime_text=$(uptime -p 2>/dev/null || awk '{print int($1/3600)"h"}' /proc/uptime 2>/dev/null || echo "N/A")
  local load
  load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "N/A")
  local mem
  if command -v free >/dev/null 2>&1; then
    mem=$(free -h | awk 'NR==2{print $3"/"$2}')
  else
    mem="N/A"
  fi
  printf "IP(s): %s\nBattery: %s\nUptime: %s\nLoad: %s\nMemory: %s\n" "$ips" "$bat" "$uptime_text" "$load" "$mem"
}

---------- PORTS / NETWORK ----------

listening_sockets() {
  if command -v ss >/dev/null 2>&1; then
    ss -tulpen 2>/dev/null | head -n 200
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpen 2>/dev/null | head -n 200
  else
    echo "ss/netstat not available"
  fi
}

# Optional nmap quick scan on local IP
nmap_scan_local() {
  if ! command -v nmap >/dev/null 2>&1; then
    echo "nmap not installed"
    return
  fi
  local ip_local
  ip_local=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)
  if [ -z "$ip_local" ]; then
    echo "Could not determine local IP"
    return
  fi
  echo "Running quick nmap -sT -Pn -F on $ip_local"
  nmap -sT -Pn -F "$ip_local"
}

---------- RUN EXTERNAL SCRIPTS ----------

run_osint() {
  if [ -x "${OSINT_SCRIPT}" ]; then
    "${OSINT_SCRIPT}" &
    return 0
  else
    echo "OSINT script not found or not executable: ${OSINT_SCRIPT}"
    return 1
  fi
}

run_wifi() {
  if [ -f "${WIFI_TOOL_PY}" ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 "${WIFI_TOOL_PY}" &
      return 0
    elif command -v python >/dev/null 2>&1; then
      python "${WIFI_TOOL_PY}" &
      return 0
    else
      echo "Python not installed"
      return 1
    fi
  else
    echo "WiFi tool not found: ${WIFI_TOOL_PY}"
    return 1
  fi
}

---------- TUI DRAWING ----------

# Minimal box drawing using tput; updates every REFRESH_INTERVAL seconds

draw_header() {
  tput cup 0 0
  printf "%b" "${BOLD}${BLUE}Termux Live Status Dashboard${RESET}"
  tput cup 0 $(( COLUMNS - 30 ))
  printf "%b" "${YELLOW}Refresh: ${REFRESH_INTERVAL}s${RESET}"
  tput cup 1 0
  printf "%b" "Press ${BOLD}G${RESET}=GitHub ${BOLD}V${RESET}=Vercel ${BOLD}R${RESET}=Render ${BOLD}D${RESET}=Device ${BOLD}P${RESET}=Ports ${BOLD}O${RESET}=Run OSINT ${BOLD}W${RESET}=Run WiFi ${BOLD}Q${RESET}=Quit"
}

draw_section_box() {
  # draw a rectangle starting at row,col with width,height and title
  local r="$1" c="$2" w="$3" h="$4" title="$5"
  tput cup "$r" "$c"
  printf "+"
  for ((i=1;i<w-1;i++)); do printf "-"; done
  printf "+"
  for ((row=r+1; row<r+h-1; row++)); do
    tput cup "$row" "$c"
    printf "|"
    tput cup "$row" $((c+w-1))
    printf "|"
  done
  tput cup $((r+h-1)) "$c"
  printf "+"
  for ((i=1;i<w-1;i++)); do printf "-"; done
  printf "+"
  tput cup "$r" $((c+2))
  printf "%b" "${BOLD}${title}${RESET}"
}

render_lines_into_box() {
  local start_row="$1"
  local start_col="$2"
  local box_w="$3"
  local box_h="$4"
  shift
  local -a lines=( "$@" )
  local max_lines=$((box_h - 2))
  local i=0
  for line in "${lines[@]}"; do
    if [ "$i" -ge "$max_lines" ]; then
      break
    fi
    # truncate to width-2 chars
    local out
    out=$(printf "%s" "$line" | cut -c1-$((box_w - 2)))
    tput cup $((start_row + 1 + i)) $((start_col + 1))
    printf "%b" "${out}"
    i=$((i + 1))
  done
  # clear remaining lines inside box
  while [ "$i" -lt "$max_lines" ]; do
    tput cup $((start_row + 1 + i)) $((start_col + 1))
    printf "%${box_w}s" " "
    i=$((i + 1))
  done
}

---------- SNAPSHOT LOGGING ----------

log_snapshot() {
  local stamp
  stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local outfile="$LOG_DIR/$(date +%F).log"
  {
    printf "==== Snapshot %s ====\n" "$stamp"
    printf "-- Device --\n"
    device_summary
    printf "\n-- GitHub --\n"
    github_fetch | head -n 20
    printf "\n-- Vercel --\n"
    vercel_fetch | head -n 20
    printf "\n-- Render --\n"
    render_fetch | head -n 20
    printf "\n-- Listening --\n"
    listening_sockets | head -n 200
    printf "\n\n"
  } >>"$outfile"
  chmod 600 "$outfile" || true
}

---------- MAIN LOOP / KEY HANDLING ----------

cleanup() {
  tput cnorm    # show cursor
  clear
  echo "Exiting dashboard..."
}

main_loop() {
  clear
  trap 'cleanup; exit 0' INT TERM
  tput civis      # hide cursor

  while true; do
    COLUMNS=$(tput cols)
    LINES=$(tput lines)
    clear
    draw_header

    # compute layout: top box (left: github), right: vercel/render, bottom: device/ports
    local left_w=$(( COLUMNS / 2 - 2 ))
    local right_w=$(( COLUMNS - left_w - 4 ))
    local top_h=$(( (LINES - 6) / 2 ))
    local bottom_h=$(( LINES - top_h - 6 ))

    # draw section boxes
    draw_section_box 3 0 "$left_w" "$top_h" " GitHub (recent repos & actions) "
    draw_section_box 3 $((left_w + 2)) "$right_w" "$top_h" " Vercel (projects) / Render (services) "
    draw_section_box $((3 + top_h + 1)) 0 "$COLUMNS" $((bottom_h + 3)) " Device & Ports (press P for details) "

    # fetch data
    mapfile -t gh_lines < <(github_fetch 2>/dev/null || echo "Unable to fetch GitHub (token missing/timeout)")

    local gh_display=()
    for rline in "${gh_lines[@]}"; do
      local repo_name
      repo_name=$(printf "%s" "$rline" | awk -F' • ' '{print $1}')
      local act
      act=$(github_actions_status "$repo_name" 2>/dev/null || echo "—")
      gh_display+=("$rline")
      gh_display+=("   ↳ $act")
    done

    mapfile -t ver_lines < <(vercel_fetch 2>/dev/null || echo "Unable to fetch Vercel (token missing/timeout)")
    mapfile -t render_lines < <(render_fetch 2>/dev/null || echo "Unable to fetch Render (token missing/timeout)")
    mapfile -t dev_lines < <(device_summary | head -n 20)
    mapfile -t ports_lines < <(listening_sockets | head -n 20)

    render_lines_into_box 3 0 "$left_w" "$top_h" "${gh_display[@]:0:40}"

    # Combine vercel and render for the right box
    local right_box_lines=()
    right_box_lines+=("${ver_lines[@]:0:10}")
    right_box_lines+=("")
    right_box_lines+=("${render_lines[@]:0:10}")
    render_lines_into_box 3 $((left_w + 2)) "$right_w" "$top_h" "${right_box_lines[@]}"

    # bottom content box
    local bottom_content=()
    bottom_content+=("Device summary:")
    for ln in "${dev_lines[@]}"; do bottom_content+=("  $ln"); done
    bottom_content+=("")
    bottom_content+=("Listening sockets (top):")
    for ln in "${ports_lines[@]:0:10}"; do bottom_content+=("  $ln"); done
    bottom_content+=("")
    bottom_content+=("Shortcuts: [O] OSINT  [W] WiFi  [N] nmap quick  [L] Log snapshot  [Q] Quit")
    render_lines_into_box $((3 + top_h + 1)) 0 "$COLUMNS" $((bottom_h + 3)) "${bottom_content[@]}"

    # log snapshot asynchronously (avoid blocking UI)
    log_snapshot &>/dev/null &

    # wait for key press or timeout
    read -rsn1 -t "$REFRESH_INTERVAL" key 2>/dev/null || key=""

    case "$key" in
      G|g)
        clear
        echo "=== GitHub Detailed ==="
        github_fetch | head -n 200
        echo
        echo "Enter repo full name to view latest workflow status (or ENTER to return):"
        read -r repo_choice
        if [ -n "$repo_choice" ]; then
          echo "Latest workflow for $repo_choice:"
          github_actions_status "$repo_choice" | head -n 200
        fi
        echo "Press ENTER to continue..."
        read -r _
        ;;
      V|v)
        clear
        echo "=== Vercel Projects ==="
        vercel_fetch | head -n 200
        echo
        echo "To check last deployment for a projectId, enter projectId (or ENTER to return):"
        read -r pid
        if [ -n "$pid" ]; then
          vercel_last_deploy "$pid" | head -n 200
        fi
        echo "Press ENTER to continue..."
        read -r _
        ;;
      R|r)
        clear
        echo "=== Render Services ==="
        render_fetch | head -n 200
        echo "Press ENTER to continue..."
        read -r _
        ;;
      D|d)
        clear
        echo "=== Device Summary ==="
        device_summary | head -n 200
        echo
        echo "Press ENTER to continue..."
        read -r _
        ;;
      P|p)
        clear
        echo "=== Listening Sockets ==="
        listening_sockets | head -n 400
        echo
        echo "Options: [n] Run quick nmap on local IP (requires nmap), [ENTER] return"
        read -rsn1 -t 10 nmkey 2>/dev/null || nmkey=""
        if [[ "$nmkey" =~ ^[nN]$ ]]; then
          echo "Running quick nmap..."
          nmap_scan_local | head -n 400
          echo
          echo "Press ENTER to continue..."
          read -r _
        else
          echo "Returning..."
          sleep 1
        fi
        ;;
      O|o)
        clear
        echo "Launching OSINT script in background..."
        run_osint && echo "OSINT started." || echo "Failed to start OSINT."
        sleep 1
        ;;
      W|w)
        clear
        echo "Launching WiFi tool in background..."
        run_wifi && echo "WiFi tool started." || echo "Failed to start WiFi tool."
        sleep 1
        ;;
      N|n)
        clear
        echo "nmap quick scan (local)..."
        nmap_scan_local | head -n 400
        echo "Press ENTER to continue..."
        read -r _
        ;;
      L|l)
        echo "Forcing snapshot log..."
        log_snapshot && echo "Logged to $LOG_DIR/$(date +%F).log"
        sleep 1
        ;;
      Q|q)
        cleanup
        exit 0
        ;;
      *)
        # no key / timed out => refresh loop again
        ;;
    esac
  done
}

---------- STARTUP ----------

load_env
check_deps
main_loop
