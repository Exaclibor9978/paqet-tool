#!/bin/bash

# Paqet - Raw Packet Tunnel Deployment Script
# All-in-one script for Server (Foreign) and Client (Iran)
# Inspired by GFW-knocker/gfw_resist_tcp_proxy
# GitHub: https://github.com/hanselime/paqet

set -e

# ╔══════════════════════════════════════════════════════════════════╗
# ║                         CONFIGURATION                            ║
# ╚══════════════════════════════════════════════════════════════════╝

PAQET_VERSION="v1.0.0-alpha.19"
PAQET_DIR="/opt/paqet"
PAQET_BIN="${PAQET_DIR}/paqet"
PAQET_CONFIG="${PAQET_DIR}/config.yaml"
PAQET_SERVICE="/etc/systemd/system/paqet.service"
DEFAULT_PORT="9999"
DEFAULT_SOCKS_PORT="1080"
INSTANCES_DIR="${PAQET_DIR}/instances"
INSTANCES_REGISTRY="${PAQET_DIR}/instances.conf"

# ╔══════════════════════════════════════════════════════════════════╗
# ║                          COLORS                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ╔══════════════════════════════════════════════════════════════════╗
# ║                       HELPER FUNCTIONS                           ║
# ╚══════════════════════════════════════════════════════════════════╝

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                    ║"
    echo "║     ██████╗  █████╗  ██████╗ ███████╗████████╗                     ║"
    echo "║     ██╔══██╗██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝                     ║"
    echo "║     ██████╔╝███████║██║   ██║█████╗     ██║                        ║"
    echo "║     ██╔═══╝ ██╔══██║██║▄▄ ██║██╔══╝     ██║                        ║"
    echo "║     ██║     ██║  ██║╚██████╔╝███████╗   ██║                        ║"
    echo "║     ╚═╝     ╚═╝  ╚═╝ ╚══▀▀═╝ ╚══════╝   ╚═╝                        ║"
    echo "║                                                                    ║"
    echo "║            Raw Packet Tunnel - DPI Bypass Tool                     ║"
    echo "║                    Version: ${PAQET_VERSION}                              ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_step() {
    echo -e "${MAGENTA}[→]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_ubuntu() {
    if ! command -v apt &> /dev/null; then
        print_error "This script is designed for Ubuntu/Debian systems with apt package manager"
        exit 1
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

detect_network_interface() {
    # Get primary network interface
    local iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -z "$iface" ]]; then
        # Fallback: find first non-loopback interface
        iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
    fi
    echo "$iface"
}

detect_local_ip() {
    local iface=$1
    ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}

detect_public_ip() {
    # Try multiple services for reliability - force IPv4 with -4 flag
    curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
    curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null || \
    curl -4 -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || \
    echo ""
}

detect_gateway_ip() {
    ip route | grep default | awk '{print $3}' | head -n1
}

detect_gateway_mac() {
    local gateway_ip=$(detect_gateway_ip)
    local interface=$(detect_network_interface)
    local mac=""
    
    if [[ -z "$gateway_ip" ]]; then
        return
    fi
    
    # Method 1: Try ip neighbor (most reliable, works on cloud VPS)
    # First, ping to populate the neighbor table
    ping -c 2 -W 1 "$gateway_ip" &>/dev/null
    mac=$(ip neighbor show "$gateway_ip" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n1)
    
    if [[ -n "$mac" ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
        echo "$mac"
        return
    fi
    
    # Method 2: Try arping if available (forces ARP resolution)
    if command -v arping &>/dev/null && [[ -n "$interface" ]]; then
        mac=$(arping -c 1 -I "$interface" "$gateway_ip" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n1)
        if [[ -n "$mac" ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
            echo "$mac"
            return
        fi
    fi
    
    # Method 3: Fallback to arp command
    mac=$(arp -n "$gateway_ip" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n1)
    if [[ -n "$mac" ]] && [[ "$mac" != "00:00:00:00:00:00" ]]; then
        echo "$mac"
        return
    fi
    
    # Method 4: Try to get MAC from ip link for the interface itself (last resort for VPS with local gateway)
    # Some cloud providers use the interface's own subnet where gateway is virtual
    mac=$(ip link show "$interface" 2>/dev/null | grep -oE 'link/ether ([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | awk '{print $2}' | head -n1)
    if [[ -n "$mac" ]]; then
        # Only use this if we truly can't find the gateway - some VPS need this
        echo "$mac"
        return
    fi
}

generate_secret_key() {
    # Generate 32-byte (64 hex chars) secret key
    head -c 32 /dev/urandom | xxd -p | tr -d '\n'
}

is_paqet_installed() {
    [[ -f "$PAQET_BIN" ]] && ( [[ -f "$PAQET_CONFIG" ]] || [[ -d "$INSTANCES_DIR" ]] )
}

get_current_role() {
    if [[ -f "$PAQET_CONFIG" ]]; then
        grep -oP '(?<=role:\s")[^"]+' "$PAQET_CONFIG" 2>/dev/null || echo "unknown"
    elif [[ -f "$INSTANCES_REGISTRY" ]]; then
        echo "client"
    else
        echo "not_installed"
    fi
}

is_multi_instance() {
    [[ -f "$INSTANCES_REGISTRY" ]] && [[ -d "$INSTANCES_DIR" ]]
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                   MULTI-INSTANCE FUNCTIONS                       ║
# ╚══════════════════════════════════════════════════════════════════╝

get_instance_list() {
    # Returns list of instance names
    if [[ -f "$INSTANCES_REGISTRY" ]]; then
        cut -d'|' -f1 "$INSTANCES_REGISTRY" 2>/dev/null
    fi
}

get_instance_info() {
    # Get info for a specific instance: name|server_addr|socks_port
    local name=$1
    if [[ -f "$INSTANCES_REGISTRY" ]]; then
        grep "^${name}|" "$INSTANCES_REGISTRY" 2>/dev/null
    fi
}

get_instance_count() {
    if [[ -f "$INSTANCES_REGISTRY" ]]; then
        wc -l < "$INSTANCES_REGISTRY"
    else
        echo "0"
    fi
}

get_next_socks_port() {
    # Find next available SOCKS port (starting from 1080)
    local port=$DEFAULT_SOCKS_PORT
    if [[ -f "$INSTANCES_REGISTRY" ]]; then
        while grep -q "|${port}$" "$INSTANCES_REGISTRY" 2>/dev/null; do
            ((port++))
        done
    fi
    echo "$port"
}

generate_instance_name() {
    # Generate unique instance name based on server IP
    local server_ip=$1
    local base_name=$(echo "$server_ip" | tr '.' '-')
    local name="$base_name"
    local counter=1
    
    while [[ -f "${INSTANCES_DIR}/${name}.yaml" ]]; do
        name="${base_name}-${counter}"
        ((counter++))
    done
    echo "$name"
}

create_instance_config() {
    local name=$1
    local interface=$2
    local local_ip=$3
    local router_mac=$4
    local server_addr=$5
    local secret_key=$6
    local socks_port=$7
    
    mkdir -p "$INSTANCES_DIR"
    
    cat > "${INSTANCES_DIR}/${name}.yaml" << EOF
# Paqet Client Configuration - Instance: ${name}
# Generated by paqet.sh

role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:${socks_port}"

network:
  interface: "${interface}"
  ipv4:
    addr: "${local_ip}:0"
    router_mac: "${router_mac}"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]

server:
  addr: "${server_addr}"

transport:
  protocol: "kcp"
  conn: 2
  kcp:
    mode: "fast3"
    key: "${secret_key}"
    sndwnd: 1024
    rcvwnd: 1024
    acknodelay: true
    smuxbuf: 4194304
    streambuf: 2097152
EOF
}

create_instance_service() {
    local name=$1
    local service_file="/etc/systemd/system/paqet-${name}.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=Paqet - Raw Packet Tunnel (${name})
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PAQET_BIN} run -c ${INSTANCES_DIR}/${name}.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "paqet-${name}.service" &>/dev/null
}

register_instance() {
    local name=$1
    local server_addr=$2
    local socks_port=$3
    
    mkdir -p "$PAQET_DIR"
    echo "${name}|${server_addr}|${socks_port}" >> "$INSTANCES_REGISTRY"
}

unregister_instance() {
    local name=$1
    if [[ -f "$INSTANCES_REGISTRY" ]]; then
        grep -v "^${name}|" "$INSTANCES_REGISTRY" > "${INSTANCES_REGISTRY}.tmp" || true
        mv "${INSTANCES_REGISTRY}.tmp" "$INSTANCES_REGISTRY"
        
        # Remove registry if empty
        if [[ ! -s "$INSTANCES_REGISTRY" ]]; then
            rm -f "$INSTANCES_REGISTRY"
        fi
    fi
}

start_instance() {
    local name=$1
    systemctl start "paqet-${name}.service"
}

stop_instance() {
    local name=$1
    systemctl stop "paqet-${name}.service"
}

is_instance_running() {
    local name=$1
    systemctl is-active --quiet "paqet-${name}.service"
}

remove_instance() {
    local name=$1
    local confirm=$2
    
    if [[ "$confirm" != "force" ]]; then
        print_warning "This will remove instance: $name"
        read -p "Are you sure? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "Cancelled"
            return 1
        fi
    fi
    
    print_step "Stopping instance service..."
    systemctl stop "paqet-${name}.service" 2>/dev/null || true
    systemctl disable "paqet-${name}.service" 2>/dev/null || true
    
    print_step "Removing instance files..."
    rm -f "/etc/systemd/system/paqet-${name}.service"
    rm -f "${INSTANCES_DIR}/${name}.yaml"
    
    print_step "Updating registry..."
    unregister_instance "$name"
    
    systemctl daemon-reload
    
    print_status "Instance '$name' removed successfully"
}

migrate_legacy_to_multi_instance() {
    # Migrate existing legacy single-instance client to multi-instance format
    if [[ ! -f "$PAQET_CONFIG" ]]; then
        return
    fi
    
    # Check if it's a client config
    local role=$(grep -oP '(?<=role:\s")[^"]+' "$PAQET_CONFIG" 2>/dev/null)
    if [[ "$role" != "client" ]]; then
        return
    fi
    
    print_step "Migrating legacy client to multi-instance format..."
    
    # Extract info from existing config
    local server_addr=$(grep -oP '(?<=addr:\s")[^"]+' "$PAQET_CONFIG" 2>/dev/null | tail -n1)
    local socks_port=$(grep -oP '(?<=listen:\s"127\.0\.0\.1:)\d+' "$PAQET_CONFIG" 2>/dev/null || echo "1080")
    
    # Generate instance name from server address
    local server_ip=$(echo "$server_addr" | cut -d':' -f1)
    local instance_name=$(echo "$server_ip" | tr '.' '-')
    
    # Create instances directory
    mkdir -p "$INSTANCES_DIR"
    
    # Move config to instances directory
    print_step "Moving config to instances directory..."
    cp "$PAQET_CONFIG" "${INSTANCES_DIR}/${instance_name}.yaml"
    
    # Update config header
    sed -i "1s/.*/# Paqet Client Configuration - Instance: ${instance_name}/" "${INSTANCES_DIR}/${instance_name}.yaml"
    
    # Create new service for this instance
    print_step "Creating instance service..."
    create_instance_service "$instance_name"
    
    # Register the instance
    print_step "Registering instance..."
    register_instance "$instance_name" "$server_addr" "$socks_port"
    
    # Stop old service and start new one
    print_step "Switching to multi-instance service..."
    systemctl stop paqet.service 2>/dev/null || true
    systemctl disable paqet.service 2>/dev/null || true
    
    systemctl start "paqet-${instance_name}.service"
    sleep 2
    
    if is_instance_running "$instance_name"; then
        print_status "Migration complete! Legacy connection now running as instance: $instance_name"
    else
        print_warning "Migration complete but instance failed to start"
        print_info "Check logs with: journalctl -u paqet-${instance_name} -f"
    fi
    
    echo ""
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                     INSTALLATION FUNCTIONS                       ║
# ╚══════════════════════════════════════════════════════════════════╝

install_dependencies() {
    print_step "Installing dependencies..."
    apt update -qq || true
    
    local failed=""
    for pkg in libpcap-dev curl iptables net-tools; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            if ! apt install -y "$pkg"; then
                failed="$failed $pkg"
            fi
        fi
    done
    
    # xxd: standalone package on newer systems, vim-common on older ones
    if ! command -v xxd &>/dev/null; then
        if ! apt install -y xxd 2>/dev/null; then
            apt install -y vim-common 2>/dev/null || true
        fi
    fi
    
    if [[ -n "$failed" ]]; then
        print_warning "Could not install:$failed (may already be present or repos unreachable)"
    fi
    
    print_status "Dependencies installed"
}

download_paqet() {
    print_step "Detecting system architecture..."
    local arch=$(detect_arch)
    print_info "Architecture: ${arch}"
    
    mkdir -p "$PAQET_DIR"
    
    # Determine the directory where this script lives (for local source detection)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # ── Method 1: Pre-built binary next to script ──
    if [[ -f "${script_dir}/paqet" ]]; then
        print_step "Found local pre-built binary at ${script_dir}/paqet"
        cp "${script_dir}/paqet" "$PAQET_BIN"
        chmod +x "$PAQET_BIN"
        if "$PAQET_BIN" version &>/dev/null; then
            print_status "Paqet installed from local binary (verified)"
        else
            print_status "Paqet installed from local binary"
        fi
        return 0
    fi
    
    # ── Method 2: Local release tarball next to script ──
    local local_tarball=""
    # Try exact version match first, then any matching tarball
    if [[ -f "${script_dir}/paqet-linux-${arch}-${PAQET_VERSION}.tar.gz" ]]; then
        local_tarball="${script_dir}/paqet-linux-${arch}-${PAQET_VERSION}.tar.gz"
    else
        local_tarball=$(ls "${script_dir}"/paqet-linux-${arch}-*.tar.gz 2>/dev/null | head -n1)
    fi
    
    if [[ -n "$local_tarball" ]] && [[ -f "$local_tarball" ]]; then
        print_step "Found local tarball: $(basename "$local_tarball")"
        print_step "Extracting archive..."
        tar -xzf "$local_tarball" -C "$PAQET_DIR"
        
        # Find and move the binary
        local extracted_bin=$(find "$PAQET_DIR" -name "paqet*" -type f -executable 2>/dev/null | head -n1)
        if [[ -z "$extracted_bin" ]]; then
            extracted_bin=$(find "$PAQET_DIR" -type f -executable 2>/dev/null | head -n1)
        fi
        
        if [[ -n "$extracted_bin" ]] && [[ "$extracted_bin" != "$PAQET_BIN" ]]; then
            mv "$extracted_bin" "$PAQET_BIN"
        fi
        
        chmod +x "$PAQET_BIN"
        
        if "$PAQET_BIN" version &>/dev/null; then
            print_status "Paqet installed from local tarball (verified)"
        else
            print_status "Paqet installed from local tarball"
        fi
        return 0
    fi
    
    # ── Method 3: Build from paqet-master source directory ──
    if [[ -d "${script_dir}/paqet-master" ]] && [[ -f "${script_dir}/paqet-master/go.mod" ]]; then
        print_step "Found local paqet-master source directory"
        
        # Check if Go is installed
        if ! command -v go &>/dev/null; then
            print_warning "Go is not installed. Attempting to install Go..."
            local go_archive="/tmp/go-linux-${arch}.tar.gz"
            local go_version="1.25.0"
            
            # Try to download Go (may fail without internet)
            if curl -L --connect-timeout 10 -o "$go_archive" "https://go.dev/dl/go${go_version}.linux-${arch}.tar.gz" 2>/dev/null; then
                rm -rf /usr/local/go
                tar -C /usr/local -xzf "$go_archive"
                export PATH="/usr/local/go/bin:$PATH"
                rm -f "$go_archive"
                print_status "Go ${go_version} installed"
            else
                print_error "Go is required to build from source but is not installed and cannot be downloaded"
                print_info "Install Go manually: https://go.dev/dl/"
                print_info "Or place a pre-built 'paqet' binary next to this script"
                exit 1
            fi
        fi
        
        print_step "Building Paqet from source..."
        local build_dir="${script_dir}/paqet-master"
        
        # Use vendored dependencies if available (offline-friendly)
        local build_flags=""
        if [[ -d "${build_dir}/vendor" ]]; then
            build_flags="-mod=vendor"
            print_info "Using vendored dependencies (offline build)"
        else
            print_warning "No vendor directory found — Go will try to download dependencies"
            print_info "For fully offline builds, run 'go mod vendor' on a machine with internet"
            print_info "and include the vendor/ directory in paqet-master"
        fi
        
        if (cd "$build_dir" && CGO_ENABLED=0 go build ${build_flags} -o "$PAQET_BIN" ./cmd/); then
            chmod +x "$PAQET_BIN"
            if "$PAQET_BIN" version &>/dev/null; then
                print_status "Paqet built and installed from source (verified)"
            else
                print_status "Paqet built and installed from source"
            fi
            return 0
        else
            print_error "Failed to build Paqet from source"
            print_info "If dependencies are missing, run 'go mod vendor' on a machine with internet"
            print_info "and upload the vendor/ directory inside paqet-master/"
            exit 1
        fi
    fi
    
    # ── Method 4: Download from GitHub (fallback) ──
    local filename="paqet-linux-${arch}-${PAQET_VERSION}.tar.gz"
    local download_url="https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/${filename}"
    
    print_step "No local sources found. Downloading Paqet ${PAQET_VERSION} (${arch})..."
    
    local temp_file="/tmp/${filename}"
    
    if curl -L --progress-bar -o "$temp_file" "$download_url"; then
        print_step "Extracting archive..."
        tar -xzf "$temp_file" -C "$PAQET_DIR"
        
        # Find and move the binary
        local extracted_bin=$(find "$PAQET_DIR" -name "paqet*" -type f -executable 2>/dev/null | head -n1)
        if [[ -z "$extracted_bin" ]]; then
            extracted_bin=$(find "$PAQET_DIR" -type f -executable 2>/dev/null | head -n1)
        fi
        
        if [[ -n "$extracted_bin" ]] && [[ "$extracted_bin" != "$PAQET_BIN" ]]; then
            mv "$extracted_bin" "$PAQET_BIN"
        fi
        
        chmod +x "$PAQET_BIN"
        rm -f "$temp_file"
        
        if "$PAQET_BIN" version &>/dev/null; then
            print_status "Paqet downloaded and verified successfully"
        else
            print_status "Paqet downloaded successfully"
        fi
    else
        print_error "Failed to download Paqet from GitHub"
        print_warning "Your server appears to have no internet access."
        print_info "Upload one of the following next to paqet.sh on the server:"
        print_info "  1. Pre-built binary named 'paqet'"
        print_info "  2. Release tarball: ${filename}"
        print_info "  3. Source directory 'paqet-master/' (with 'vendor/' for offline build)"
        exit 1
    fi
}

configure_iptables_server() {
    local port=$1
    print_step "Configuring iptables for Paqet server..."
    
    # Remove any existing paqet rules first
    iptables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    
    # Add NOTRACK rules to bypass connection tracking
    iptables -t raw -A PREROUTING -p tcp --dport "$port" -j NOTRACK
    iptables -t raw -A OUTPUT -p tcp --sport "$port" -j NOTRACK
    
    # Drop RST packets to prevent kernel interference
    iptables -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
    
    # Persist iptables rules
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi
    
    print_status "iptables configured for port $port"
}

remove_iptables_rules() {
    local port=$1
    print_step "Removing iptables rules..."
    
    iptables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    print_status "iptables rules removed"
}

create_server_config() {
    local interface=$1
    local server_ip=$2
    local port=$3
    local router_mac=$4
    local secret_key=$5
    
    cat > "$PAQET_CONFIG" << EOF
# Paqet Server Configuration
# Generated by paqet.sh

role: "server"

log:
  level: "info"

listen:
  addr: ":${port}"

network:
  interface: "${interface}"
  ipv4:
    addr: "${server_ip}:${port}"
    router_mac: "${router_mac}"
  tcp:
    local_flag: ["PA"]

transport:
  protocol: "kcp"
  conn: 2
  kcp:
    mode: "fast3"
    key: "${secret_key}"
    sndwnd: 2048
    rcvwnd: 2048
    acknodelay: true
    smuxbuf: 4194304
    streambuf: 2097152
EOF

    print_status "Server configuration created"
}

create_client_config() {
    local interface=$1
    local local_ip=$2
    local router_mac=$3
    local server_addr=$4
    local secret_key=$5
    local socks_port=$6
    
    cat > "$PAQET_CONFIG" << EOF
# Paqet Client Configuration
# Generated by paqet.sh

role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:${socks_port}"

network:
  interface: "${interface}"
  ipv4:
    addr: "${local_ip}:0"
    router_mac: "${router_mac}"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]

server:
  addr: "${server_addr}"

transport:
  protocol: "kcp"
  conn: 2
  kcp:
    mode: "fast3"
    key: "${secret_key}"
    sndwnd: 1024
    rcvwnd: 1024
    acknodelay: true
    smuxbuf: 4194304
    streambuf: 2097152
EOF

    print_status "Client configuration created"
}

create_systemd_service() {
    print_step "Creating systemd service..."
    
    cat > "$PAQET_SERVICE" << EOF
[Unit]
Description=Paqet - Raw Packet Tunnel
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PAQET_BIN} run -c ${PAQET_CONFIG}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable paqet.service &>/dev/null
    print_status "Systemd service created and enabled"
}

start_paqet_service() {
    print_step "Starting Paqet service..."
    systemctl restart paqet.service
    sleep 2
    
    if systemctl is-active --quiet paqet.service; then
        print_status "Paqet service started successfully"
    else
        print_error "Paqet service failed to start"
        print_info "Check logs with: journalctl -u paqet -f"
        return 1
    fi
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                     SERVER INSTALLATION                          ║
# ╚══════════════════════════════════════════════════════════════════╝

install_server() {
    print_banner
    echo -e "${BOLD}${GREEN}=== SERVER INSTALLATION (Foreign Server) ===${NC}\n"
    
    # Detect network settings
    print_step "Detecting network configuration..."
    
    local interface=$(detect_network_interface)
    local local_ip=$(detect_local_ip "$interface")
    local public_ip=$(detect_public_ip)
    local gateway_mac=$(detect_gateway_mac)
    
    # Detect if we're in a NAT environment (cloud VPS)
    local is_nat="false"
    if [[ -n "$local_ip" ]] && [[ -n "$public_ip" ]] && [[ "$local_ip" != "$public_ip" ]]; then
        is_nat="true"
    fi
    
    echo ""
    print_info "Detected Network Interface: ${BOLD}$interface${NC}"
    print_info "Detected Local IP: ${BOLD}$local_ip${NC}"
    print_info "Detected Public IP: ${BOLD}$public_ip${NC}"
    print_info "Detected Gateway MAC: ${BOLD}$gateway_mac${NC}"
    
    if [[ "$is_nat" == "true" ]]; then
        echo ""
        print_warning "NAT environment detected (AWS/GCP/Azure/etc.)"
        print_info "Server will bind to local IP: ${BOLD}$local_ip${NC}"
        print_info "Clients will connect to public IP: ${BOLD}$public_ip${NC}"
    fi
    echo ""
    
    # Get user confirmation/input
    read -p "$(echo -e ${CYAN}"Network Interface [$interface]: "${NC})" input_interface
    interface="${input_interface:-$interface}"
    
    # For raw packets, always use local IP (the one bound to interface)
    local bind_ip="$local_ip"
    if [[ "$is_nat" == "true" ]]; then
        read -p "$(echo -e ${CYAN}"Bind IP (local) [$local_ip]: "${NC})" input_bind_ip
        bind_ip="${input_bind_ip:-$local_ip}"
        
        read -p "$(echo -e ${CYAN}"Public IP (for clients) [$public_ip]: "${NC})" input_public_ip
        public_ip="${input_public_ip:-$public_ip}"
    else
        # Non-NAT: local and public are same
        read -p "$(echo -e ${CYAN}"Server IP [$local_ip]: "${NC})" input_ip
        bind_ip="${input_ip:-$local_ip}"
        public_ip="$bind_ip"
    fi
    
    read -p "$(echo -e ${CYAN}"Gateway MAC [$gateway_mac]: "${NC})" input_mac
    gateway_mac="${input_mac:-$gateway_mac}"
    
    read -p "$(echo -e ${CYAN}"Server Port [$DEFAULT_PORT]: "${NC})" input_port
    local port="${input_port:-$DEFAULT_PORT}"
    
    echo ""
    
    # Validate inputs
    if [[ -z "$interface" ]] || [[ -z "$bind_ip" ]] || [[ -z "$gateway_mac" ]] || [[ -z "$port" ]]; then
        print_error "All fields are required. Please check your network configuration."
        exit 1
    fi
    
    # Generate secret key
    print_step "Generating secret key..."
    local secret_key=$(generate_secret_key)
    print_status "Secret key generated"
    
    # Install - use BIND IP (local) for server config
    install_dependencies
    download_paqet
    create_server_config "$interface" "$bind_ip" "$port" "$gateway_mac" "$secret_key"
    create_systemd_service
    configure_iptables_server "$port"
    start_paqet_service
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    SERVER INSTALLATION COMPLETE                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Save the following information for client setup:${NC}"
    echo ""
    echo -e "  ${CYAN}Server IP:${NC}    ${BOLD}$public_ip${NC}"
    echo -e "  ${CYAN}Server Port:${NC}  ${BOLD}$port${NC}"
    echo -e "  ${CYAN}Secret Key:${NC}   ${BOLD}$secret_key${NC}"
    echo ""
    echo -e "${YELLOW}[!] IMPORTANT: Share the secret key securely with the client!${NC}"
    echo ""
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                     CLIENT INSTALLATION                          ║
# ╚══════════════════════════════════════════════════════════════════╝

add_connection() {
    # Add a new connection (can be called during install or from management menu)
    local first_install=$1  # "true" if this is the first installation
    
    print_banner
    if [[ "$first_install" == "true" ]]; then
        echo -e "${BOLD}${GREEN}=== CLIENT INSTALLATION (Iran Server) ===${NC}\n"
    else
        echo -e "${BOLD}${GREEN}=== ADD NEW CONNECTION ===${NC}\n"
        print_info "Current connections: $(get_instance_count)"
        echo ""
    fi
    
    # Detect network settings
    print_step "Detecting network configuration..."
    
    local interface=$(detect_network_interface)
    local local_ip=$(detect_local_ip "$interface")
    local gateway_mac=$(detect_gateway_mac)
    
    echo ""
    print_info "Detected Network Interface: ${BOLD}$interface${NC}"
    print_info "Detected Local IP: ${BOLD}$local_ip${NC}"
    print_info "Detected Gateway MAC: ${BOLD}$gateway_mac${NC}"
    echo ""
    
    # Get user confirmation/input for local settings
    read -p "$(echo -e ${CYAN}"Network Interface [$interface]: "${NC})" input_interface
    interface="${input_interface:-$interface}"
    
    read -p "$(echo -e ${CYAN}"Local IP [$local_ip]: "${NC})" input_ip
    local_ip="${input_ip:-$local_ip}"
    
    read -p "$(echo -e ${CYAN}"Gateway MAC [$gateway_mac]: "${NC})" input_mac
    gateway_mac="${input_mac:-$gateway_mac}"
    
    echo ""
    echo -e "${BOLD}${YELLOW}Enter server connection details:${NC}"
    echo ""
    
    # Get server details
    read -p "$(echo -e ${CYAN}"Foreign Server IP: "${NC})" server_ip
    if [[ -z "$server_ip" ]]; then
        print_error "Server IP is required"
        return 1
    fi
    
    read -p "$(echo -e ${CYAN}"Foreign Server Port [$DEFAULT_PORT]: "${NC})" server_port
    server_port="${server_port:-$DEFAULT_PORT}"
    
    read -p "$(echo -e ${CYAN}"Secret Key (from server): "${NC})" secret_key
    if [[ -z "$secret_key" ]]; then
        print_error "Secret key is required"
        return 1
    fi
    
    # Auto-assign next available SOCKS port
    local next_port=$(get_next_socks_port)
    read -p "$(echo -e ${CYAN}"SOCKS5 Listen Port [$next_port]: "${NC})" socks_port
    socks_port="${socks_port:-$next_port}"
    
    echo ""
    
    # Validate
    if [[ -z "$interface" ]] || [[ -z "$local_ip" ]] || [[ -z "$gateway_mac" ]]; then
        print_error "Network configuration is incomplete. Please check your settings."
        return 1
    fi
    
    local server_addr="${server_ip}:${server_port}"
    
    # Generate instance name
    local instance_name=$(generate_instance_name "$server_ip")
    
    # Optionally allow custom name
    read -p "$(echo -e ${CYAN}"Instance name [$instance_name]: "${NC})" custom_name
    instance_name="${custom_name:-$instance_name}"
    
    # Check if instance already exists
    if [[ -f "${INSTANCES_DIR}/${instance_name}.yaml" ]]; then
        print_error "Instance '$instance_name' already exists"
        return 1
    fi
    
    echo ""
    
    # Install dependencies and binary only on first install
    if [[ "$first_install" == "true" ]]; then
        install_dependencies
        download_paqet
    fi
    
    # Create instance config and service
    print_step "Creating instance configuration..."
    create_instance_config "$instance_name" "$interface" "$local_ip" "$gateway_mac" "$server_addr" "$secret_key" "$socks_port"
    print_status "Instance configuration created"
    
    print_step "Creating instance service..."
    create_instance_service "$instance_name"
    print_status "Instance service created"
    
    print_step "Registering instance..."
    register_instance "$instance_name" "$server_addr" "$socks_port"
    print_status "Instance registered"
    
    print_step "Starting instance..."
    start_instance "$instance_name"
    sleep 2
    
    if is_instance_running "$instance_name"; then
        print_status "Instance '$instance_name' started successfully"
    else
        print_error "Instance failed to start"
        print_info "Check logs with: journalctl -u paqet-${instance_name} -f"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    if [[ "$first_install" == "true" ]]; then
        echo -e "${GREEN}║                    CLIENT INSTALLATION COMPLETE                    ║${NC}"
    else
        echo -e "${GREEN}║                    NEW CONNECTION ADDED                            ║${NC}"
    fi
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Connection Details:${NC}"
    echo -e "  ${CYAN}Instance:${NC}     ${BOLD}$instance_name${NC}"
    echo -e "  ${CYAN}Server:${NC}       ${BOLD}$server_addr${NC}"
    echo -e "  ${CYAN}SOCKS5:${NC}       ${BOLD}127.0.0.1:${socks_port}${NC}"
    echo ""
    echo -e "${BOLD}Test with:${NC}"
    echo -e "  curl --proxy socks5h://127.0.0.1:${socks_port} https://httpbin.org/ip"
    echo ""
    
    # On first install, ask if user wants to add more connections
    if [[ "$first_install" == "true" ]]; then
        echo ""
        read -p "$(echo -e ${CYAN}"Would you like to add another server connection? (y/N): "${NC})" add_more
        if [[ "$add_more" =~ ^[Yy]$ ]]; then
            add_connection "false"
        fi
    fi
}

install_client() {
    add_connection "true"
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                      MANAGEMENT FUNCTIONS                        ║
# ╚══════════════════════════════════════════════════════════════════╝

show_status() {
    echo ""
    print_info "Service Status:"
    systemctl status paqet.service --no-pager
    echo ""
}

show_logs() {
    echo ""
    print_info "Recent Logs (Ctrl+C to exit):"
    journalctl -u paqet -f --no-pager -n 50
}

show_config() {
    echo ""
    print_info "Current Configuration:"
    echo ""
    cat "$PAQET_CONFIG"
    echo ""
}

restart_service() {
    print_step "Restarting Paqet service..."
    systemctl restart paqet.service
    sleep 2
    if systemctl is-active --quiet paqet.service; then
        print_status "Paqet service restarted successfully"
    else
        print_error "Paqet service failed to restart"
    fi
}

toggle_service() {
    echo ""
    if systemctl is-active --quiet paqet.service; then
        # Service is running, offer to disable
        print_info "Paqet tunnel is currently: ${GREEN}ENABLED${NC} (running)"
        echo ""
        read -p "$(echo -e ${YELLOW}"Do you want to DISABLE the tunnel? (y/N): "${NC})" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_step "Stopping Paqet service..."
            systemctl stop paqet.service
            print_step "Disabling Paqet service..."
            systemctl disable paqet.service 2>/dev/null
            if ! systemctl is-active --quiet paqet.service; then
                print_status "Paqet tunnel has been DISABLED"
                print_info "The tunnel will not start on boot"
            else
                print_error "Failed to disable Paqet service"
            fi
        else
            print_info "Operation cancelled"
        fi
    else
        # Service is not running, offer to enable
        print_info "Paqet tunnel is currently: ${RED}DISABLED${NC} (stopped)"
        echo ""
        read -p "$(echo -e ${GREEN}"Do you want to ENABLE the tunnel? (y/N): "${NC})" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_step "Enabling Paqet service..."
            systemctl enable paqet.service 2>/dev/null
            print_step "Starting Paqet service..."
            systemctl start paqet.service
            sleep 2
            if systemctl is-active --quiet paqet.service; then
                print_status "Paqet tunnel has been ENABLED"
                print_info "The tunnel will auto-start on boot"
            else
                print_error "Failed to start Paqet service"
                print_info "Check logs with: journalctl -u paqet -f"
            fi
        else
            print_info "Operation cancelled"
        fi
    fi
    echo ""
}

test_connection() {
    print_step "Testing connection..."
    "$PAQET_BIN" ping -c "$PAQET_CONFIG"
}

uninstall_paqet() {
    echo ""
    print_warning "This will completely remove Paqet from this system."
    read -p "Are you sure? (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "Uninstall cancelled"
        return
    fi
    
    # Handle multi-instance client
    if is_multi_instance; then
        print_step "Removing all client instances..."
        while IFS='|' read -r name server_addr socks_port; do
            print_step "Removing instance: $name"
            systemctl stop "paqet-${name}.service" 2>/dev/null || true
            systemctl disable "paqet-${name}.service" 2>/dev/null || true
            rm -f "/etc/systemd/system/paqet-${name}.service"
        done < "$INSTANCES_REGISTRY"
        rm -rf "$INSTANCES_DIR"
        rm -f "$INSTANCES_REGISTRY"
    fi
    
    # Handle legacy single-instance
    print_step "Stopping and disabling service..."
    systemctl stop paqet.service 2>/dev/null || true
    systemctl disable paqet.service 2>/dev/null || true
    
    # Get port from config before removing
    local port=$(grep -oP '(?<=addr:\s":")\\d+' "$PAQET_CONFIG" 2>/dev/null || echo "$DEFAULT_PORT")
    
    print_step "Removing iptables rules..."
    remove_iptables_rules "$port"
    
    print_step "Removing files..."
    rm -f "$PAQET_SERVICE"
    rm -rf "$PAQET_DIR"
    
    systemctl daemon-reload
    
    print_status "Paqet has been completely uninstalled"
    echo ""
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                   CLIENT MULTI-CONNECTION MENU                   ║
# ╚══════════════════════════════════════════════════════════════════╝

display_connections() {
    echo ""
    echo -e "${BOLD}${CYAN}Connections:${NC}"
    echo ""
    
    if [[ ! -f "$INSTANCES_REGISTRY" ]] || [[ ! -s "$INSTANCES_REGISTRY" ]]; then
        echo -e "  ${YELLOW}No connections configured${NC}"
        return
    fi
    
    local count=1
    while IFS='|' read -r name server_addr socks_port; do
        if is_instance_running "$name"; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${count})${NC} ${name}"
            echo -e "     Server: ${server_addr}"
            echo -e "     SOCKS5: 127.0.0.1:${socks_port} ${GREEN}[RUNNING]${NC}"
        else
            echo -e "  ${RED}○${NC} ${BOLD}${count})${NC} ${name}"
            echo -e "     Server: ${server_addr}"
            echo -e "     SOCKS5: 127.0.0.1:${socks_port} ${RED}[STOPPED]${NC}"
        fi
        echo ""
        ((count++))
    done < "$INSTANCES_REGISTRY"
}

select_instance() {
    local prompt=$1
    local instances=()
    
    while IFS='|' read -r name server_addr socks_port; do
        instances+=("$name")
    done < "$INSTANCES_REGISTRY"
    
    if [[ ${#instances[@]} -eq 0 ]]; then
        print_error "No instances available"
        return 1
    fi
    
    echo ""
    local count=1
    for name in "${instances[@]}"; do
        echo -e "  ${BOLD}${count})${NC} ${name}"
        ((count++))
    done
    echo ""
    
    read -p "$(echo -e ${CYAN}"$prompt (1-${#instances[@]}): "${NC})" choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#instances[@]} ]]; then
        SELECTED_INSTANCE="${instances[$((choice-1))]}"
        return 0
    else
        print_error "Invalid selection"
        return 1
    fi
}

toggle_instance_menu() {
    if ! select_instance "Select connection to toggle"; then
        return
    fi
    
    local name="$SELECTED_INSTANCE"
    echo ""
    
    if is_instance_running "$name"; then
        print_info "Connection '$name' is currently: ${GREEN}RUNNING${NC}"
        read -p "$(echo -e ${YELLOW}"Stop this connection? (y/N): "${NC})" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_step "Stopping connection..."
            stop_instance "$name"
            systemctl disable "paqet-${name}.service" 2>/dev/null || true
            print_status "Connection '$name' stopped"
        fi
    else
        print_info "Connection '$name' is currently: ${RED}STOPPED${NC}"
        read -p "$(echo -e ${GREEN}"Start this connection? (y/N): "${NC})" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_step "Starting connection..."
            systemctl enable "paqet-${name}.service" 2>/dev/null || true
            start_instance "$name"
            sleep 2
            if is_instance_running "$name"; then
                print_status "Connection '$name' started"
            else
                print_error "Failed to start connection"
                print_info "Check logs with: journalctl -u paqet-${name} -f"
            fi
        fi
    fi
}

view_instance_logs() {
    if ! select_instance "Select connection to view logs"; then
        return
    fi
    
    echo ""
    print_info "Logs for '$SELECTED_INSTANCE' (Ctrl+C to exit):"
    journalctl -u "paqet-${SELECTED_INSTANCE}" -f --no-pager -n 50
}

view_instance_config() {
    if ! select_instance "Select connection to view config"; then
        return
    fi
    
    echo ""
    print_info "Configuration for '$SELECTED_INSTANCE':"
    echo ""
    cat "${INSTANCES_DIR}/${SELECTED_INSTANCE}.yaml"
    echo ""
}

remove_connection_menu() {
    if ! select_instance "Select connection to remove"; then
        return
    fi
    
    remove_instance "$SELECTED_INSTANCE"
}

restart_all_instances() {
    print_step "Restarting all connections..."
    
    while IFS='|' read -r name server_addr socks_port; do
        print_step "Restarting: $name"
        systemctl restart "paqet-${name}.service" 2>/dev/null || true
    done < "$INSTANCES_REGISTRY"
    
    sleep 2
    print_status "All connections restarted"
}

tune_kcp_parameters() {
    # Determine config file to tune
    local config_file=""
    local service_name=""
    local is_instance="false"
    
    if is_multi_instance; then
        if ! select_instance "Select connection to tune"; then
            return
        fi
        config_file="${INSTANCES_DIR}/${SELECTED_INSTANCE}.yaml"
        service_name="paqet-${SELECTED_INSTANCE}.service"
        is_instance="true"
    elif [[ -f "$PAQET_CONFIG" ]]; then
        config_file="$PAQET_CONFIG"
        service_name="paqet.service"
    else
        print_error "No configuration file found"
        return 1
    fi
    
    echo ""
    print_info "Tuning KCP parameters for: ${BOLD}$(basename "$config_file")${NC}"
    echo ""
    
    # ═══════════════════════════════════════════════════════════════
    #  PRESET SELECTION
    # ═══════════════════════════════════════════════════════════════
    echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║              KCP PARAMETER PRESETS                  ║${NC}"
    echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}${CYAN}1)${NC} ${GREEN}Lowest Latency${NC}   ${YELLOW}(Best ping / real-time)${NC}"
    echo -e "     mode=fast3  conn=1  sndwnd=128  rcvwnd=128  nodelay ACKs"
    echo -e "     ${YELLOW}Best for: gaming, RDP, SSH, VoIP${NC}"
    echo ""
    echo -e "  ${BOLD}${CYAN}2)${NC} ${GREEN}Highest Speed${NC}    ${YELLOW}(Max download / upload)${NC}"
    echo -e "     mode=fast2  conn=4  sndwnd=2048 rcvwnd=2048 16MB buffers"
    echo -e "     ${YELLOW}Best for: large transfers, streaming, torrents${NC}"
    echo ""
    echo -e "  ${BOLD}${CYAN}3)${NC} ${GREEN}Firewall Buster${NC}  ${YELLOW}(DPI evasion / censorship bypass)${NC}"
    echo -e "     mode=fast   conn=2  sndwnd=512  rcvwnd=512  batched ACKs"
    echo -e "     ${YELLOW}Best for: heavily censored networks (Iran DPI)${NC}"
    echo ""
    echo -e "  ${BOLD}${CYAN}4)${NC} Manual -- enter each value yourself"
    echo ""
    read -p "$(echo -e ${CYAN}"Select preset (1-4, or Enter to cancel): "${NC})" preset_choice

    local new_conn new_mode new_sndwnd new_rcvwnd new_acknodelay new_smuxbuf new_streambuf

    case "$preset_choice" in
        1)
            # Lowest Latency
            # fast3: nodelay=1 interval=10 resend=2 nc=1 (no congestion ctrl)
            # 1 connection -> no cross-stream head-of-line blocking
            # Tiny windows -> ACKs fly back immediately, zero bufferbloat
            # acknodelay=true -> every ACK sent at once, no Nagle batching
            # Minimal buffers prevent OS-level queue buildup
            new_conn=1
            new_mode="fast3"
            new_sndwnd=128
            new_rcvwnd=128
            new_acknodelay=true
            new_smuxbuf=1048576
            new_streambuf=524288
            echo ""
            echo -e "${GREEN}[+] Preset: Lowest Latency applied${NC}"
            echo -e "${YELLOW}    Trade-off: lower maximum throughput${NC}"
            ;;
        2)
            # Highest Speed
            # fast2: nodelay=1 interval=20 resend=1 nc=1
            # 4 parallel KCP sessions -> saturates the uplink
            # Large windows (2048) -> maximises in-flight data
            # 16 MB smuxbuf / 8 MB streambuf -> zero starvation on bulk IO
            new_conn=4
            new_mode="fast2"
            new_sndwnd=2048
            new_rcvwnd=2048
            new_acknodelay=true
            new_smuxbuf=16777216
            new_streambuf=8388608
            echo ""
            echo -e "${GREEN}[+] Preset: Highest Speed applied${NC}"
            echo -e "${YELLOW}    Trade-off: higher CPU and memory usage${NC}"
            ;;
        3)
            # Firewall Buster
            # fast mode: less aggressive retransmission -> traffic pattern is
            # steadier, harder for a DPI classifier to fingerprint as KCP
            # conn=2: redundancy without obvious burst signatures
            # sndwnd/rcvwnd=512: moderate datagrams, avoids large UDP packets
            # that trigger size-heuristics in Iran DPI boxes
            # acknodelay=false: batches ACKs like QUIC, less KCP-distinctive
            new_conn=2
            new_mode="fast"
            new_sndwnd=512
            new_rcvwnd=512
            new_acknodelay=false
            new_smuxbuf=4194304
            new_streambuf=2097152
            echo ""
            echo -e "${GREEN}[+] Preset: Firewall Buster applied${NC}"
            echo -e "${YELLOW}    Trade-off: slightly higher RTT than Lowest Latency${NC}"
            ;;
        4)
            new_conn=""
            ;;
        "")
            print_info "Cancelled"
            return 0
            ;;
        *)
            print_error "Invalid selection"
            return 1
            ;;
    esac

    # ── Read current values from config ────────────────────────────
    local cur_conn=$(grep -E '^\s*conn:' "$config_file" 2>/dev/null | awk '{print $2}' | head -n1)
    local cur_mode=$(grep -E '^\s*mode:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -n1)
    local cur_sndwnd=$(grep -E '^\s*sndwnd:' "$config_file" 2>/dev/null | awk '{print $2}' | head -n1)
    local cur_rcvwnd=$(grep -E '^\s*rcvwnd:' "$config_file" 2>/dev/null | awk '{print $2}' | head -n1)
    local cur_acknodelay=$(grep -E '^\s*acknodelay:' "$config_file" 2>/dev/null | awk '{print $2}' | head -n1)
    local cur_smuxbuf=$(grep -E '^\s*smuxbuf:' "$config_file" 2>/dev/null | awk '{print $2}' | head -n1)
    local cur_streambuf=$(grep -E '^\s*streambuf:' "$config_file" 2>/dev/null | awk '{print $2}' | head -n1)
    
    cur_conn=${cur_conn:-2}
    cur_mode=${cur_mode:-fast3}
    cur_sndwnd=${cur_sndwnd:-1024}
    cur_rcvwnd=${cur_rcvwnd:-1024}
    cur_acknodelay=${cur_acknodelay:-true}
    cur_smuxbuf=${cur_smuxbuf:-4194304}
    cur_streambuf=${cur_streambuf:-2097152}

    # Manual mode: prompt for each value
    if [[ "$preset_choice" == "4" ]]; then
        echo ""
        echo -e "${BOLD}${YELLOW}Current KCP Parameters:${NC}"
        echo -e "  ${CYAN}1)${NC} Connections (conn):    ${BOLD}${cur_conn}${NC}    ${YELLOW}(parallel sessions, 1-256)${NC}"
        echo -e "  ${CYAN}2)${NC} KCP Mode (mode):      ${BOLD}${cur_mode}${NC}  ${YELLOW}(normal/fast/fast2/fast3)${NC}"
        echo -e "  ${CYAN}3)${NC} Send Window (sndwnd):  ${BOLD}${cur_sndwnd}${NC}  ${YELLOW}(larger = more throughput)${NC}"
        echo -e "  ${CYAN}4)${NC} Recv Window (rcvwnd):  ${BOLD}${cur_rcvwnd}${NC}  ${YELLOW}(larger = more throughput)${NC}"
        echo -e "  ${CYAN}5)${NC} ACK No Delay:         ${BOLD}${cur_acknodelay}${NC}  ${YELLOW}(true = lower latency)${NC}"
        echo -e "  ${CYAN}6)${NC} SMUX Buffer:          ${BOLD}${cur_smuxbuf}${NC}  ${YELLOW}(mux buffer bytes)${NC}"
        echo -e "  ${CYAN}7)${NC} Stream Buffer:        ${BOLD}${cur_streambuf}${NC}  ${YELLOW}(stream buffer bytes)${NC}"
        echo ""
        
        read -p "$(echo -e ${CYAN}"Connections [$cur_conn]: "${NC})" new_conn
        new_conn=${new_conn:-$cur_conn}
        
        echo -e "  ${YELLOW}Modes: normal (conservative), fast, fast2, fast3 (most aggressive)${NC}"
        read -p "$(echo -e ${CYAN}"KCP Mode [$cur_mode]: "${NC})" new_mode
        new_mode=${new_mode:-$cur_mode}
        
        read -p "$(echo -e ${CYAN}"Send Window [$cur_sndwnd]: "${NC})" new_sndwnd
        new_sndwnd=${new_sndwnd:-$cur_sndwnd}
        
        read -p "$(echo -e ${CYAN}"Recv Window [$cur_rcvwnd]: "${NC})" new_rcvwnd
        new_rcvwnd=${new_rcvwnd:-$cur_rcvwnd}
        
        read -p "$(echo -e ${CYAN}"ACK No Delay (true/false) [$cur_acknodelay]: "${NC})" new_acknodelay
        new_acknodelay=${new_acknodelay:-$cur_acknodelay}
        
        read -p "$(echo -e ${CYAN}"SMUX Buffer [$cur_smuxbuf]: "${NC})" new_smuxbuf
        new_smuxbuf=${new_smuxbuf:-$cur_smuxbuf}
        
        read -p "$(echo -e ${CYAN}"Stream Buffer [$cur_streambuf]: "${NC})" new_streambuf
        new_streambuf=${new_streambuf:-$cur_streambuf}
    fi
    
    echo ""
    
    # ── Apply changes via sed ──────────────────────────────────────
    print_step "Applying new KCP parameters..."
    
    sed -i "s/^\(\s*\)conn:.*/\1conn: ${new_conn}/" "$config_file"
    sed -i "s/^\(\s*\)mode:.*/\1mode: \"${new_mode}\"/" "$config_file"
    
    if grep -qE '^\s*sndwnd:' "$config_file"; then
        sed -i "s/^\(\s*\)sndwnd:.*/\1sndwnd: ${new_sndwnd}/" "$config_file"
    else
        sed -i "/^\s*mode:/a\\    sndwnd: ${new_sndwnd}" "$config_file"
    fi
    
    if grep -qE '^\s*rcvwnd:' "$config_file"; then
        sed -i "s/^\(\s*\)rcvwnd:.*/\1rcvwnd: ${new_rcvwnd}/" "$config_file"
    else
        sed -i "/^\s*sndwnd:/a\\    rcvwnd: ${new_rcvwnd}" "$config_file"
    fi
    
    if grep -qE '^\s*acknodelay:' "$config_file"; then
        sed -i "s/^\(\s*\)acknodelay:.*/\1acknodelay: ${new_acknodelay}/" "$config_file"
    else
        sed -i "/^\s*rcvwnd:/a\\    acknodelay: ${new_acknodelay}" "$config_file"
    fi
    
    if grep -qE '^\s*smuxbuf:' "$config_file"; then
        sed -i "s/^\(\s*\)smuxbuf:.*/\1smuxbuf: ${new_smuxbuf}/" "$config_file"
    else
        sed -i "/^\s*acknodelay:/a\\    smuxbuf: ${new_smuxbuf}" "$config_file"
    fi
    
    if grep -qE '^\s*streambuf:' "$config_file"; then
        sed -i "s/^\(\s*\)streambuf:.*/\1streambuf: ${new_streambuf}/" "$config_file"
    else
        sed -i "/^\s*smuxbuf:/a\\    streambuf: ${new_streambuf}" "$config_file"
    fi
    
    print_status "KCP parameters updated"
    echo ""
    print_info "Updated configuration:"
    echo ""
    cat "$config_file"
    echo ""
    
    read -p "$(echo -e ${CYAN}"Restart service to apply changes? (Y/n): "${NC})" restart_confirm
    if [[ ! "$restart_confirm" =~ ^[Nn]$ ]]; then
        print_step "Restarting service..."
        systemctl restart "$service_name" 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet "$service_name"; then
            print_status "Service restarted successfully with new KCP settings"
        else
            print_error "Service failed to restart"
            print_info "Check logs with: journalctl -u $service_name -f"
        fi
    else
        print_info "Remember to restart the service manually to apply changes"
    fi
}

client_management_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}${CYAN}=== PAQET CLIENT - MULTI-CONNECTION MENU ===${NC}"
        echo -e "Total Connections: ${BOLD}$(get_instance_count)${NC}"
        
        display_connections
        
        echo -e "  ${BOLD}1)${NC} Add New Connection"
        echo -e "  ${BOLD}2)${NC} Remove Connection"
        echo -e "  ${BOLD}3)${NC} Start/Stop Connection"
        echo -e "  ${BOLD}4)${NC} View Connection Logs"
        echo -e "  ${BOLD}5)${NC} View Connection Config"
        echo -e "  ${BOLD}6)${NC} ${YELLOW}Tune KCP Parameters${NC}"
        echo -e "  ${BOLD}7)${NC} Restart All Connections"
        echo -e "  ${BOLD}8)${NC} Uninstall All"
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        
        read -p "$(echo -e ${CYAN}"Select option: "${NC})" choice
        
        case $choice in
            1) add_connection "false"; read -p "Press Enter to continue..." ;;
            2) remove_connection_menu; read -p "Press Enter to continue..." ;;
            3) toggle_instance_menu; read -p "Press Enter to continue..." ;;
            4) view_instance_logs ;;
            5) view_instance_config; read -p "Press Enter to continue..." ;;
            6) tune_kcp_parameters; read -p "Press Enter to continue..." ;;
            7) restart_all_instances; read -p "Press Enter to continue..." ;;
            8) 
                uninstall_paqet
                exit 0
                ;;
            0) exit 0 ;;
            *) print_error "Invalid option" ;;
        esac
    done
}

management_menu() {
    local role=$(get_current_role)
    
    # Route to appropriate menu based on role
    if [[ "$role" == "client" ]] && is_multi_instance; then
        client_management_menu
        return
    fi
    
    # Server or legacy single-instance menu
    while true; do
        print_banner
        echo -e "${BOLD}${CYAN}=== PAQET MANAGEMENT MENU ===${NC}"
        echo -e "Current Role: ${BOLD}${role}${NC}"
        
        # Show current tunnel status
        if systemctl is-active --quiet paqet.service; then
            echo -e "Tunnel Status: ${GREEN}● ENABLED${NC} (running)\n"
        else
            echo -e "Tunnel Status: ${RED}● DISABLED${NC} (stopped)\n"
        fi
        
        echo -e "  ${BOLD}1)${NC} View Status"
        echo -e "  ${BOLD}2)${NC} View Logs"
        echo -e "  ${BOLD}3)${NC} Show Configuration"
        echo -e "  ${BOLD}4)${NC} Restart Service"
        if systemctl is-active --quiet paqet.service; then
            echo -e "  ${BOLD}5)${NC} ${RED}Disable Tunnel${NC}"
        else
            echo -e "  ${BOLD}5)${NC} ${GREEN}Enable Tunnel${NC}"
        fi
        echo -e "  ${BOLD}6)${NC} Test Connection (Ping)"
        echo -e "  ${BOLD}7)${NC} ${YELLOW}Tune KCP Parameters${NC}"
        # Show Add Connection option only for clients
        if [[ "$role" == "client" ]]; then
            echo -e "  ${BOLD}8)${NC} ${GREEN}Add Another Server Connection${NC}"
            echo -e "  ${BOLD}9)${NC} Reinstall"
            echo -e "  ${BOLD}10)${NC} Uninstall"
        else
            echo -e "  ${BOLD}8)${NC} Reinstall"
            echo -e "  ${BOLD}9)${NC} Uninstall"
        fi
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        
        read -p "$(echo -e ${CYAN}"Select option: "${NC})" choice
        
        if [[ "$role" == "client" ]]; then
            case $choice in
                1) show_status; read -p "Press Enter to continue..." ;;
                2) show_logs ;;
                3) show_config; read -p "Press Enter to continue..." ;;
                4) restart_service; read -p "Press Enter to continue..." ;;
                5) toggle_service; read -p "Press Enter to continue..." ;;
                6) test_connection; read -p "Press Enter to continue..." ;;
                7) tune_kcp_parameters; read -p "Press Enter to continue..." ;;
                8) 
                    # Migrate legacy to multi-instance and add connection
                    migrate_legacy_to_multi_instance
                    add_connection "false"
                    # Now switch to multi-instance menu
                    client_management_menu
                    return
                    ;;
                9) 
                    uninstall_paqet
                    main_menu
                    return
                    ;;
                10) 
                    uninstall_paqet
                    exit 0
                    ;;
                0) exit 0 ;;
                *) print_error "Invalid option" ;;
            esac
        else
            # Server menu
            case $choice in
                1) show_status; read -p "Press Enter to continue..." ;;
                2) show_logs ;;
                3) show_config; read -p "Press Enter to continue..." ;;
                4) restart_service; read -p "Press Enter to continue..." ;;
                5) toggle_service; read -p "Press Enter to continue..." ;;
                6) test_connection; read -p "Press Enter to continue..." ;;
                7) tune_kcp_parameters; read -p "Press Enter to continue..." ;;
                8) 
                    uninstall_paqet
                    main_menu
                    return
                    ;;
                9) 
                    uninstall_paqet
                    exit 0
                    ;;
                0) exit 0 ;;
                *) print_error "Invalid option" ;;
            esac
        fi
    done
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                         MAIN MENU                                ║
# ╚══════════════════════════════════════════════════════════════════╝

main_menu() {
    print_banner
    
    # Check if already installed
    if is_paqet_installed; then
        local role=$(get_current_role)
        echo -e "${GREEN}Paqet is already installed as: ${BOLD}${role}${NC}\n"
        echo -e "  ${BOLD}1)${NC} Manage Existing Installation"
        echo -e "  ${BOLD}2)${NC} Reinstall as Server"
        echo -e "  ${BOLD}3)${NC} Reinstall as Client"
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        
        read -p "$(echo -e ${CYAN}"Select option: "${NC})" choice
        
        case $choice in
            1) management_menu ;;
            2) 
                uninstall_paqet
                install_server
                ;;
            3) 
                uninstall_paqet
                install_client
                ;;
            0) exit 0 ;;
            *) print_error "Invalid option"; main_menu ;;
        esac
    else
        echo -e "${BOLD}Select installation mode:${NC}\n"
        echo -e "  ${BOLD}1)${NC} Server (Foreign/VPS - receives connections)"
        echo -e "  ${BOLD}2)${NC} Client (Iran - connects to foreign server)"
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        
        read -p "$(echo -e ${CYAN}"Select option: "${NC})" choice
        
        case $choice in
            1) install_server ;;
            2) install_client ;;
            0) exit 0 ;;
            *) print_error "Invalid option"; main_menu ;;
        esac
    fi
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║                           ENTRY POINT                            ║
# ╚══════════════════════════════════════════════════════════════════╝

check_root
check_ubuntu
main_menu
