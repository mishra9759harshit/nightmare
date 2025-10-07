#!/usr/bin/env bash
# termux_tui_dashboard_fixed.sh
# Live TUI Termux dashboard — token-based (.env) GitHub / Vercel / Render / Device status + quick-run tools
# Author: Secure Coder (modified for full dependency checks & tput fix)

set -euo pipefail
IFS=$'\n\t'

# ---------- CONFIG / DEFAULTS ----------
ENV_FILES=(./.env "$HOME/.termux_status.env")
REFRESH_INTERVAL=30          # overridden by .env REFRESH_INTERVAL (seconds)
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

# ---------- LOAD ENV ----------
load_env() {
    for f in "${ENV_FILES[@]}"; do
        [ -f "$f" ] || continue
        set -o allexport
        while IFS= read -r line || [ -n "$line" ]; do
            line_trim="$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            case "$line_trim" in
                ''|#*) continue ;;
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

    : "${REFRESH_INTERVAL:=${REFRESH_INTERVAL}}"
    if [ -n "${PROJECTS:-}" ]; then
        read -r -a PROJECTS <<<"$PROJECTS"
    fi
    : "${OSINT_SCRIPT:=$OSINT_SCRIPT}"
    : "${WIFI_TOOL_PY:=$WIFI_TOOL_PY}"
}

# ---------- DEPENDENCY CHECK ----------
check_deps(){
    local need=(curl jq python python3 nmap ncurses-utils)
    local missing=()
    for c in "${need[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing tools: ${missing[*]}"
        warn "Installing missing packages..."
        pkg update -y
        for m in "${missing[@]}"; do
            pkg install -y "$m"
        done
    fi
}

# ---------- SAFE HTTP HELPER ----------
http_get(){
    local url="$1"
    local token="$2"
    if [ -n "$token" ]; then
        curl -sS -H "Authorization: Bearer $token" -H "User-Agent: Termux-TUI/1.0" "$url"
    else
        curl -sS -H "User-Agent: Termux-TUI/1.0" "$url"
    fi
}

# ---------- GITHUB ----------
github_fetch(){
    if [ -z "${GITHUB_TOKEN:-}" ]; then echo "GITHUB_TOKEN not set"; return; fi
    local repos_json
    repos_json=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/user/repos?per_page=50&sort=updated")
    if [ -z "$repos_json" ]; then echo "Failed to query GitHub API"; return; fi
    echo "$repos_json" | jq -r '[.[] | {name:.full_name, private:.private, stars:.stargazers_count, updated:.updated_at, default_branch:.default_branch, url:.html_url}] | sort_by(.updated) | reverse | .[0:6] | .[] | "(.name) • (.private|tostring) • ★(.stars) • updated:(.updated) • (.url)"'
}

github_actions_status(){
    local repo="$1"
    [ -z "${GITHUB_TOKEN:-}" ] && { echo "GITHUB_TOKEN not set"; return; }
    local r
    r=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/${repo}/actions/runs?per_page=1")
    echo "$r" | jq -r '.workflow_runs[0] | "(.name // "workflow") — (.conclusion // .status) — (.html_url)"' 2>/dev/null || echo "—"
}

# ---------- VERCEL ----------
vercel_fetch(){
    [ -z "${VERCEL_TOKEN:-}" ] && { echo "VERCEL_TOKEN not set"; return; }
    local projects
    projects=$(curl -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "https://api.vercel.com/v8/projects")
    echo "$projects" | jq -r '.projects[0:6][] | "(.name) • id:(.id) • org:(.team?.name // "personal")"'
}

vercel_last_deploy(){
    local projectId="$1"
    [ -z "${VERCEL_TOKEN:-}" ] && [ -z "$projectId" ] && { echo "—"; return; }
    local r
    r=$(curl -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "https://api.vercel.com/v12/now/deployments?projectId=${projectId}&limit=1")
    echo "$r" | jq -r '.deployments[0] | "(.state // "unknown") — (.url // .name // "n/a") — created:(.createdAt // 0)"' 2>/dev/null || echo "—"
}

# ---------- RENDER ----------
render_fetch(){
    [ -z "${RENDER_TOKEN:-}" ] && { echo "RENDER_TOKEN not set"; return; }
    local r
    r=$(curl -sS -H "Authorization: Bearer ${RENDER_TOKEN}" "https://api.render.com/v1/services")
    echo "$r" | jq -r '.[] | "(.name) • state:(.state) • url:(.serviceDetails?.webURL // .url // "n/a")"'
}

# ---------- DEVICE ----------
device_summary(){
    local ips bat uptime_text load mem
    ips=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ' || true)
    [ -z "$ips" ] && ips=$(hostname -I 2>/dev/null || echo "N/A")
    bat="N/A"
    command -v termux-battery-status >/dev/null 2>&1 && bat=$(termux-battery-status | jq -r '"(.percentage)% ((.health // "unknown"))"')
    uptime_text=$(uptime -p 2>/dev/null || awk '{print int($1/3600)"h"}' /proc/uptime 2>/dev/null || echo "N/A")
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "N/A")
    mem=$(command -v free >/dev/null 2>&1 && free -h | awk 'NR==2{print $3"/"$2}' || echo "N/A")
    printf "IP(s): %s\nBattery: %s\nUptime: %s\nLoad: %s\nMemory: %s\n" "$ips" "$bat" "$uptime_text" "$load" "$mem"
}

# ---------- PORTS / NETWORK ----------
listening_sockets(){
    if command -v ss >/dev/null 2>&1; then
        ss -tulpen 2>/dev/null | sed -n '1,200p'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpen 2>/dev/null | sed -n '1,200p'
    else
        echo "ss/netstat not available"
    fi
}

nmap_scan_local(){
    command -v nmap >/dev/null 2>&1 || { echo "nmap not installed"; return; }
    local ip_local
    ip_local=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)
    [ -z "$ip_local" ] && { echo "Could not determine local IP"; return; }
    echo "Running quick nmap -sT -Pn -F on $ip_local"
    nmap -sT -Pn -F "$ip_local"
}

# ---------- EXTERNAL SCRIPTS ----------
run_osint(){ [ -x "$OSINT_SCRIPT" ] && "$OSINT_SCRIPT" & return 0 || { echo "OSINT script missing or not executable"; return 1; }; }
run_wifi(){
    [ -f "$WIFI_TOOL_PY" ] || { echo "WiFi tool missing"; return 1; }
    if command -v python3 >/dev/null 2>&1; then python3 "$WIFI_TOOL_PY" &
    elif command -v python >/dev/null 2>&1; then python "$WIFI_TOOL_PY" &
    else echo "Python not installed"; return 1; fi
}

# ---------- LOG SNAPSHOT ----------
mkdir -p "$LOG_DIR"
log_snapshot(){
    local stamp outfile
    stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    outfile="$LOG_DIR/$(date +%F).log"
    {
        printf "==== Snapshot %s ====\n" "$stamp"
        printf "-- Device --\n"
        device_summary
        printf "\n-- GitHub --\n"
        github_fetch | sed -n '1,20p'
        printf "\n-- Vercel --\n"
        vercel_fetch | sed -n '1,20p'
        printf "\n-- Render --\n"
        render_fetch | sed -n '1,20p'
        printf "\n-- Listening --\n"
        listening_sockets | sed -n '1,200p'
        printf "\n\n"
    } >>"$outfile"
    chmod 600 "$outfile" || true
}

# ---------- TUI ----------
tput_exists(){ command -v tput >/dev/null 2>&1; }

draw_header(){
    tput_exists && tput cup 0 0
    printf "%b" "${BOLD}${BLUE}Termux Live Status Dashboard${RESET}"
    tput_exists && tput cup 0 $(( $(tput cols) - 30 ))
    printf "%b" "${YELLOW}Refresh: ${REFRESH_INTERVAL}s${RESET}"
    tput_exists && tput cup 1 0
    printf "%b" "Press ${BOLD}G${RESET}=GitHub  ${BOLD}V${RESET}=Vercel  ${BOLD}R${RESET}=Render  ${BOLD}D${RESET}=Device  ${BOLD}P${RESET}=Ports  ${BOLD}O${RESET}=OSINT  ${BOLD}W${RESET}=WiFi  ${BOLD}Q${RESET}=Quit"
}

draw_section_box(){
    local r="$1" c="$2" w="$3" h="$4" title="$5"
    if tput_exists; then
        tput cup "$r" "$c"; printf "+"
        for ((i=1;i<w-1;i++)); do printf "-"; done
        printf "+"
        for ((row=r+1; row<r+h-1; row++)); do
            tput cup "$row" "$c"; printf "|"
            tput cup "$row" $((c+w-1)); printf "|"
        done
        tput cup $((r+h-1)) "$c"; printf "+"
        for ((i=1;i<w-1;i++)); do printf "-"; done
        tput cup "$r" $((c+2)); printf "%b" "${BOLD}${title}${RESET}"
    else
        echo "=== $title ==="
    fi
}

render_lines_into_box(){
    local start_row="$1" start_col="$2" box_w="$3" box_h="$4"; shift
    local -a lines=( "$@" )
    local max_lines=$((box_h-2))
    local i=0
    for line in "${lines[@]}"; do
        [ "$i" -ge "$max_lines" ] && break
        out=$(printf "%s" "$line" | cut -c1-$((box_w-2)))
        tput_exists && tput cup $((start_row+1+i)) $((start_col+1))
        printf "%b" "$out"
        i=$((i+1))
    done
}

cleanup(){
    tput_exists && tput cnorm
    clear
    echo "Exiting dashboard..."
}

# ---------- MAIN LOOP ----------
main_loop(){
    clear
    trap 'cleanup; exit 0' INT TERM
    while true; do
        draw_header
        sleep "$REFRESH_INTERVAL"
    done
}

# ---------- STARTUP ----------
load_env
check_deps
tput_exists && tput civis
main_loop