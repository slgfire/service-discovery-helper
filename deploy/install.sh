#!/usr/bin/env bash
set -euo pipefail

# Service Discovery Helper — Install Script
# Installs dependencies, builds sdh-proxy, generates config interactively,
# and optionally sets up systemd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PREFIX="${PREFIX:-/usr/local}"
SYSCONFDIR="$REPO_DIR"
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

# ── Cleanup on abort ──────────────────────────────────────────────────────
cleanup() {
    echo ""
    warn "Aborted."
    exit 1
}
trap cleanup INT TERM

# ── CLI flags ─────────────────────────────────────────────────────────────
AUTO_YES=0
DO_UNINSTALL=0

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -y, --yes            Non-interactive mode (skip all prompts, use defaults)"
    echo "  --uninstall          Remove sdh-proxy binary, service, and config"
    echo "  -h, --help           Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)       AUTO_YES=1; shift ;;
        --uninstall)    DO_UNINSTALL=1; shift ;;
        -h|--help)      usage ;;
        *)              error "Unknown option: $1"; usage ;;
    esac
done

# Helper: prompt user or auto-accept
# Usage: confirm "question" [default_yes|default_no]
confirm() {
    local question="$1"
    local default="${2:-default_no}"

    if [[ "$AUTO_YES" -eq 1 ]]; then
        if [[ "$default" == "default_yes" ]]; then
            return 0
        else
            return 1
        fi
    fi

    if [[ "$default" == "default_yes" ]]; then
        ask "$question [Y/n]"
    else
        ask "$question [y/N]"
    fi

    local answer=""
    read -r answer || true
    if [[ "$default" == "default_yes" ]]; then
        [[ ! "$answer" =~ ^[Nn]$ ]]
    else
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

# Helper: read input or return empty in auto mode
read_input() {
    local answer=""
    if [[ "$AUTO_YES" -eq 1 ]]; then
        echo ""
        return
    fi
    read -r answer || true
    echo "$answer"
}

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

# ── Uninstall ─────────────────────────────────────────────────────────────
uninstall() {
    echo -e "\n${BOLD}── Uninstalling sdh-proxy ──${NC}\n"

    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        exit 1
    fi

    # Stop and disable service
    if [[ -d /run/systemd/system ]]; then
        if systemctl is-active sdh-proxy &>/dev/null; then
            systemctl stop sdh-proxy
            info "Service stopped"
        fi
        if systemctl is-enabled sdh-proxy &>/dev/null; then
            systemctl disable sdh-proxy
            info "Service disabled"
        fi
        if [[ -f "$SYSTEMD_UNIT_DIR/sdh-proxy.service" ]]; then
            rm -f "$SYSTEMD_UNIT_DIR/sdh-proxy.service"
            systemctl daemon-reload
            info "Removed $SYSTEMD_UNIT_DIR/sdh-proxy.service"
        fi
    fi

    if [[ -f "$PREFIX/bin/sdh-proxy" ]]; then
        rm -f "$PREFIX/bin/sdh-proxy"
        info "Removed $PREFIX/bin/sdh-proxy"
    else
        warn "Binary not found at $PREFIX/bin/sdh-proxy"
    fi

    if [[ -f "$CONF_FILE" ]]; then
        if confirm "Remove config at $CONF_FILE?" "default_no"; then
            rm -f "$CONF_FILE"
            info "Removed $CONF_FILE"
        else
            info "Kept $CONF_FILE"
        fi
        # Also clean up any backup
        if [[ -f "$CONF_FILE.bak" ]]; then
            rm -f "$CONF_FILE.bak"
            info "Removed $CONF_FILE.bak"
        fi
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
    echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
    echo -e "\n${BOLD}── Pre-flight checks ──${NC}\n"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        exit 1
    fi
    info "Running as root"

    # Check for pre-built binary (release package) or Makefile (git clone)
    if [[ -f "$REPO_DIR/sdh-proxy" ]]; then
        info "Pre-built binary found at $REPO_DIR/sdh-proxy"
        PREBUILT=1
    elif [[ -f "$REPO_DIR/Makefile" ]]; then
        info "Repository found at $REPO_DIR"
        PREBUILT=0
    else
        error "Cannot find sdh-proxy binary or Makefile in $REPO_DIR"
        error "Run this script from the deploy/ directory inside the extracted package or git repo."
        exit 1
    fi

    # Check for existing installation
    if [[ -f "$PREFIX/bin/sdh-proxy" ]]; then
        warn "Existing sdh-proxy found at $PREFIX/bin/sdh-proxy — will be overwritten."
    fi
    if [[ -f "$CONF_FILE" ]]; then
        warn "Existing config found at $CONF_FILE"
        if confirm "Overwrite config?" "default_no"; then
            # Backup existing config
            cp "$CONF_FILE" "$CONF_FILE.bak"
            info "Backup saved to $CONF_FILE.bak"
        else
            SKIP_CONFIG=1
        fi
    fi

    echo ""
}

# ── Detect package manager and install dependencies ─────────────────────────
install_deps() {
    echo -e "${BOLD}── Installing dependencies ──${NC}\n"

    if command -v apt-get &>/dev/null; then
        info "Detected Debian/Ubuntu (apt)"
        apt-get update -qq
        apt-get install -y gcc make libpcap-dev
    elif command -v dnf &>/dev/null; then
        info "Detected Fedora/RHEL (dnf)"
        dnf install -y gcc make libpcap-devel
    elif command -v yum &>/dev/null; then
        info "Detected CentOS/RHEL (yum)"
        yum install -y gcc make libpcap-devel
    elif command -v pacman &>/dev/null; then
        info "Detected Arch Linux (pacman)"
        pacman -S --needed --noconfirm gcc make libpcap
    elif command -v zypper &>/dev/null; then
        info "Detected openSUSE (zypper)"
        zypper install -y gcc make libpcap-devel
    elif command -v apk &>/dev/null; then
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
    # Use /sys/class/net for reliable names (ip -o link show appends @parent on VLANs)
    mapfile -t AVAILABLE_IFACES < <(ls /sys/class/net/ | grep -v '^lo$' | sort)

    if [[ ${#AVAILABLE_IFACES[@]} -eq 0 ]]; then
        error "No network interfaces found (besides lo)."
        exit 1
    fi

    echo "  Available interfaces:"
    echo ""
    for i in "${!AVAILABLE_IFACES[@]}"; do
        iface="${AVAILABLE_IFACES[$i]}"
        # Get link state
        local state
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        # Get IP if assigned
        local ip_addr
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)

        local details=""
        if [[ "$state" != "up" ]]; then
            details="${YELLOW}${state}${NC}"
            if [[ -n "$ip_addr" ]]; then
                details="$details, $ip_addr"
            fi
        elif [[ -n "$ip_addr" ]]; then
            details="$ip_addr"
        else
            details="no IPv4"
        fi
        echo -e "    ${BOLD}$((i+1)))${NC} $iface  ($details)"
    done
    echo -e "    ${BOLD}a)${NC} All interfaces"
    echo ""

    if [[ "$AUTO_YES" -eq 1 ]]; then
        # Non-interactive: select all UP interfaces with IPv4
        SELECTED_IFACES=()
        for iface in "${AVAILABLE_IFACES[@]}"; do
            local state
            state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
            if [[ "$state" == "up" ]]; then
                SELECTED_IFACES+=("$iface")
            fi
        done
        if [[ ${#SELECTED_IFACES[@]} -lt 2 ]]; then
            # Fall back to all interfaces if less than 2 are UP
            SELECTED_IFACES=("${AVAILABLE_IFACES[@]}")
        fi
        info "Auto-selected: ${SELECTED_IFACES[*]}"
        echo ""
        return
    fi

    ask "Select interfaces (comma-separated numbers, or 'a' for all):"
    local iface_input
    iface_input=$(read_input)

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
        if ! confirm "Continue anyway?" "default_no"; then
            exit 1
        fi
    fi

    info "Selected: ${SELECTED_IFACES[*]}"
    echo ""
}

# ── Interactive port/game selection ─────────────────────────────────────────
select_ports() {
    echo -e "${BOLD}── Port configuration ──${NC}\n"

    # All known game ports are included by default
    SELECTED_PORTS=()
    for name in "${GAME_NAMES[@]}"; do
        SELECTED_PORTS+=("${GAME_PORTS[$name]}")
    done

    echo "  The following game discovery ports are included by default:"
    echo ""
    for i in "${!GAME_NAMES[@]}"; do
        name="${GAME_NAMES[$i]}"
        ports="${GAME_PORTS[$name]}"
        echo -e "    ${GREEN}+${NC} $name  [$ports]"
    done
    echo ""

    if [[ "$AUTO_YES" -eq 1 ]]; then
        info "Selected ports: ${SELECTED_PORTS[*]}"
        echo ""
        return
    fi

    ask "Additional custom ports? (comma-separated, e.g. '7777,8080-8090', or empty to skip):"
    local custom_ports
    custom_ports=$(read_input)
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

    info "Selected ports: ${SELECTED_PORTS[*]}"
    echo ""
}

# ── Summary & confirmation before writing config ──────────────────────────
confirm_config() {
    echo -e "${BOLD}── Configuration summary ──${NC}\n"

    echo "  Interfaces:  ${SELECTED_IFACES[*]}"
    echo "  Ports:       ${SELECTED_PORTS[*]}"
    echo "  Config file: $CONF_FILE"
    echo ""

    if ! confirm "Write config?" "default_yes"; then
        warn "Skipped — config not written. You can create it manually at $CONF_FILE"
        echo ""
        return 1
    fi
    echo ""
    return 0
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

    if confirm "Enable sdh-proxy to start on boot?" "default_no"; then
        systemctl enable sdh-proxy
        info "Service enabled"

        if confirm "Start sdh-proxy now?" "default_no"; then
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
    # Handle --uninstall early
    if [[ "$DO_UNINSTALL" -eq 1 ]]; then
        uninstall
        exit 0
    fi

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  Service Discovery Helper — Installer        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    SKIP_CONFIG=0

    preflight

    if [[ "$PREBUILT" -eq 0 ]]; then
        install_deps
        build
    else
        # Ensure runtime dependency (libpcap) is available
        if ! ldconfig -p 2>/dev/null | grep -q libpcap; then
            echo -e "${BOLD}── Installing runtime dependencies ──${NC}\n"
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y libpcap0.8
            elif command -v dnf &>/dev/null; then
                dnf install -y libpcap
            elif command -v yum &>/dev/null; then
                yum install -y libpcap
            elif command -v pacman &>/dev/null; then
                pacman -S --needed --noconfirm libpcap
            elif command -v zypper &>/dev/null; then
                zypper install -y libpcap1
            elif command -v apk &>/dev/null; then
                apk add libpcap
            else
                warn "libpcap not found — please install it manually (e.g. apt install libpcap0.8)"
            fi
        fi
    fi

    echo -e "${BOLD}── Install ──${NC}\n"
    echo "  The following will be installed:"
    echo ""
    echo "    Binary:   $PREFIX/bin/sdh-proxy"
    if [[ -d /run/systemd/system ]]; then
        echo "    Service:  $SYSTEMD_UNIT_DIR/sdh-proxy.service"
    fi
    echo ""
    if confirm "Proceed with installation?" "default_yes"; then
        echo ""
        install_files
    else
        warn "Skipped — you can install manually:"
        echo "    cp $REPO_DIR/sdh-proxy $PREFIX/bin/sdh-proxy"
        if [[ -d /run/systemd/system ]]; then
            echo "    cp $REPO_DIR/deploy/sdh-proxy.service $SYSTEMD_UNIT_DIR/sdh-proxy.service"
        fi
        echo ""
    fi

    if [[ "$SKIP_CONFIG" -eq 0 ]]; then
        select_interfaces
        select_ports
        if confirm_config; then
            generate_config
        fi
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
