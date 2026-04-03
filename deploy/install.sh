#!/usr/bin/env bash
set -euo pipefail

# Service Discovery Helper — Install Script
# Installs dependencies, builds sdh-proxy, generates config interactively,
# and optionally sets up systemd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PREFIX="${PREFIX:-/usr/local}"
SYSCONFDIR="${SYSCONFDIR:-/etc}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/lib/systemd/system}"
CONF_FILE="$SYSCONFDIR/sdh-proxy.conf"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
ask()   { echo -en "${CYAN}[?]${NC} $* "; }

# ── Known game discovery ports ──────────────────────────────────────────────
declare -A GAME_PORTS=(
    ["Source Engine (TF2, CS:GO, CS:S, HL2DM)"]="27015-27020"
    ["Steam Client"]="27036"
    ["Warcraft 3 / Frozen Throne"]="6112"
    ["ARMA 2 / DayZ"]="2302-2470"
    ["Trackmania / Shootmania"]="2350-2360"
    ["Unreal Tournament 2004"]="10777"
    ["Warsow"]="44400"
    ["Blur"]="50001"
    ["FlatOut 2"]="23757"
)

# Ordered list of game names for consistent display
GAME_NAMES=(
    "Source Engine (TF2, CS:GO, CS:S, HL2DM)"
    "Steam Client"
    "Warcraft 3 / Frozen Throne"
    "ARMA 2 / DayZ"
    "Trackmania / Shootmania"
    "Unreal Tournament 2004"
    "Warsow"
    "Blur"
    "FlatOut 2"
)

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
    echo -e "\n${BOLD}── Pre-flight checks ──${NC}\n"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        exit 1
    fi
    info "Running as root"

    # Check that repo directory looks right
    if [[ ! -f "$REPO_DIR/Makefile" ]]; then
        error "Cannot find Makefile in $REPO_DIR — run this script from the deploy/ directory."
        exit 1
    fi
    info "Repository found at $REPO_DIR"

    # Check for existing installation
    if [[ -f "$PREFIX/bin/sdh-proxy" ]]; then
        warn "Existing sdh-proxy found at $PREFIX/bin/sdh-proxy — will be overwritten."
    fi
    if [[ -f "$CONF_FILE" ]]; then
        warn "Existing config found at $CONF_FILE"
        ask "Overwrite config? [y/N]"
        read -r overwrite_conf
        if [[ ! "$overwrite_conf" =~ ^[Yy]$ ]]; then
            SKIP_CONFIG=1
        fi
    fi

    echo ""
}

# ── Detect package manager and install dependencies ─────────────────────────
install_deps() {
    echo -e "${BOLD}── Installing dependencies ──${NC}\n"

    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
        info "Detected Debian/Ubuntu (apt)"
        apt-get update -qq
        apt-get install -y gcc make libpcap-dev
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        info "Detected Fedora/RHEL (dnf)"
        dnf install -y gcc make libpcap-devel
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        info "Detected CentOS/RHEL (yum)"
        yum install -y gcc make libpcap-devel
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
        info "Detected Arch Linux (pacman)"
        pacman -S --needed --noconfirm gcc make libpcap
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
        info "Detected openSUSE (zypper)"
        zypper install -y gcc make libpcap-devel
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"
        info "Detected Alpine (apk)"
        apk add gcc make musl-dev libpcap-dev
    else
        error "Could not detect package manager. Please install manually: gcc, make, libpcap-dev"
        exit 1
    fi

    info "Dependencies installed"
    echo ""
}

# ── Build ───────────────────────────────────────────────────────────────────
build() {
    echo -e "${BOLD}── Building sdh-proxy ──${NC}\n"

    make -C "$REPO_DIR" clean 2>/dev/null || true
    make -C "$REPO_DIR"

    if [[ ! -f "$REPO_DIR/sdh-proxy" ]]; then
        error "Build failed — sdh-proxy binary not found."
        exit 1
    fi

    info "Build successful"
    echo ""
}

# ── Interactive interface selection ─────────────────────────────────────────
select_interfaces() {
    echo -e "${BOLD}── Interface configuration ──${NC}\n"

    # List available interfaces (excluding lo)
    mapfile -t AVAILABLE_IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | sort)

    if [[ ${#AVAILABLE_IFACES[@]} -eq 0 ]]; then
        error "No network interfaces found (besides lo)."
        exit 1
    fi

    echo "  Available interfaces:"
    echo ""
    for i in "${!AVAILABLE_IFACES[@]}"; do
        iface="${AVAILABLE_IFACES[$i]}"
        # Get IP if assigned
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        if [[ -n "$ip_addr" ]]; then
            echo -e "    ${BOLD}$((i+1)))${NC} $iface  ($ip_addr)"
        else
            echo -e "    ${BOLD}$((i+1)))${NC} $iface  (no IPv4)"
        fi
    done
    echo -e "    ${BOLD}a)${NC} All interfaces"
    echo ""

    ask "Select interfaces (comma-separated numbers, or 'a' for all):"
    read -r iface_input

    SELECTED_IFACES=()
    if [[ "$iface_input" =~ ^[Aa]$ ]]; then
        SELECTED_IFACES=("${AVAILABLE_IFACES[@]}")
    else
        IFS=',' read -ra selections <<< "$iface_input"
        for sel in "${selections[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#AVAILABLE_IFACES[@]} )); then
                SELECTED_IFACES+=("${AVAILABLE_IFACES[$((sel-1))]}")
            else
                warn "Ignoring invalid selection: $sel"
            fi
        done
    fi

    if [[ ${#SELECTED_IFACES[@]} -lt 2 ]]; then
        warn "Less than 2 interfaces selected — sdh-proxy needs at least 2 to forward between."
        ask "Continue anyway? [y/N]"
        read -r cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    info "Selected: ${SELECTED_IFACES[*]}"
    echo ""
}

# ── Interactive port/game selection ─────────────────────────────────────────
select_ports() {
    echo -e "${BOLD}── Port configuration ──${NC}\n"
    echo "  Known game discovery ports:"
    echo ""

    for i in "${!GAME_NAMES[@]}"; do
        name="${GAME_NAMES[$i]}"
        ports="${GAME_PORTS[$name]}"
        echo -e "    ${BOLD}$((i+1)))${NC} $name  [$ports]"
    done
    echo ""
    echo -e "    ${BOLD}a)${NC} All of the above"
    echo ""

    ask "Select games (comma-separated numbers, or 'a' for all):"
    read -r game_input

    SELECTED_PORTS=()
    if [[ "$game_input" =~ ^[Aa]$ ]]; then
        for name in "${GAME_NAMES[@]}"; do
            SELECTED_PORTS+=("${GAME_PORTS[$name]}")
        done
    else
        IFS=',' read -ra selections <<< "$game_input"
        for sel in "${selections[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#GAME_NAMES[@]} )); then
                name="${GAME_NAMES[$((sel-1))]}"
                SELECTED_PORTS+=("${GAME_PORTS[$name]}")
            else
                warn "Ignoring invalid selection: $sel"
            fi
        done
    fi

    echo ""
    ask "Additional custom ports? (comma-separated, e.g. '7777,8080-8090', or empty to skip):"
    read -r custom_ports
    if [[ -n "$custom_ports" ]]; then
        IFS=',' read -ra extras <<< "$custom_ports"
        for p in "${extras[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            if [[ "$p" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
                SELECTED_PORTS+=("$p")
            else
                warn "Ignoring invalid port: $p"
            fi
        done
    fi

    if [[ ${#SELECTED_PORTS[@]} -eq 0 ]]; then
        error "No ports selected. At least one port is required."
        exit 1
    fi

    info "Selected ports: ${SELECTED_PORTS[*]}"
    echo ""
}

# ── Generate config file ───────────────────────────────────────────────────
generate_config() {
    echo -e "${BOLD}── Generating config ──${NC}\n"

    cat > "$CONF_FILE" <<CONF
# Service Discovery Helper configuration
# Generated by install.sh on $(date -Iseconds)

[interfaces]
$(printf '%s\n' "${SELECTED_IFACES[@]}")

[ports]
$(printf '%s\n' "${SELECTED_PORTS[@]}")

[settings]
rate_limit = yes
rate_limit_timeout = 1000
log_stats = no
syslog = no
debug = no
CONF

    chmod 644 "$CONF_FILE"
    info "Config written to $CONF_FILE"
    echo ""
}

# ── Install binary and service file ─────────────────────────────────────────
install_files() {
    echo -e "${BOLD}── Installing files ──${NC}\n"

    install -D -m 755 "$REPO_DIR/sdh-proxy" "$PREFIX/bin/sdh-proxy"
    info "Binary installed to $PREFIX/bin/sdh-proxy"

    if [[ -d /run/systemd/system ]]; then
        install -D -m 644 "$REPO_DIR/deploy/sdh-proxy.service" "$SYSTEMD_UNIT_DIR/sdh-proxy.service"
        systemctl daemon-reload
        info "Systemd unit installed to $SYSTEMD_UNIT_DIR/sdh-proxy.service"
    else
        warn "Systemd not detected — service file not installed."
    fi

    echo ""
}

# ── Systemd setup (optional) ───────────────────────────────────────────────
setup_systemd() {
    if [[ ! -d /run/systemd/system ]]; then
        return
    fi

    echo -e "${BOLD}── Systemd setup ──${NC}\n"
    echo "  You can enable and start the service now, or do it later with:"
    echo ""
    echo "    sudo systemctl enable sdh-proxy"
    echo "    sudo systemctl start sdh-proxy"
    echo ""

    ask "Enable sdh-proxy to start on boot? [y/N]"
    read -r enable_svc
    if [[ "$enable_svc" =~ ^[Yy]$ ]]; then
        systemctl enable sdh-proxy
        info "Service enabled"

        ask "Start sdh-proxy now? [y/N]"
        read -r start_svc
        if [[ "$start_svc" =~ ^[Yy]$ ]]; then
            systemctl start sdh-proxy
            info "Service started"
        fi
    else
        info "Skipped — you can enable/start later with the commands above."
    fi

    echo ""
}

# ── Verify installation ────────────────────────────────────────────────────
verify() {
    echo -e "${BOLD}── Verification ──${NC}\n"

    if [[ -x "$PREFIX/bin/sdh-proxy" ]]; then
        info "Binary:  $PREFIX/bin/sdh-proxy"
    else
        error "Binary not found at $PREFIX/bin/sdh-proxy"
    fi

    if [[ -f "$CONF_FILE" ]]; then
        info "Config:  $CONF_FILE"
    else
        warn "Config file not found at $CONF_FILE"
    fi

    if [[ -d /run/systemd/system ]] && systemctl is-enabled sdh-proxy &>/dev/null; then
        info "Systemd: enabled"
        if systemctl is-active sdh-proxy &>/dev/null; then
            info "Status:  running"
        else
            info "Status:  not running"
        fi
    fi

    echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  Service Discovery Helper — Installer        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    SKIP_CONFIG=0

    preflight
    install_deps
    build
    install_files

    if [[ "$SKIP_CONFIG" -eq 0 ]]; then
        select_interfaces
        select_ports
        generate_config
    else
        info "Keeping existing config at $CONF_FILE"
        echo ""
    fi

    setup_systemd
    verify

    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo ""
}

main "$@"
