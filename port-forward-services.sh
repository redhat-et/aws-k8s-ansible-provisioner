#!/bin/bash

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS_FILE="$SCRIPT_DIR/.port-forward-pids"
STATUS_FILE="$SCRIPT_DIR/.port-forward-status"

# Port forwarding configuration (compatible with bash 3.x)
get_service_config() {
    case "$1" in
        "prometheus") echo "monitoring:svc/prometheus-operated:9090:9090" ;;
        "llm-d") echo "llm-d:svc/llm-d-inference-gateway-istio:8080:80" ;;
        "grafana") echo "monitoring:svc/prometheus-grafana:3000:80" ;;
        *) echo "" ;;
    esac
}

get_local_port() {
    case "$1" in
        "prometheus") echo "9090" ;;
        "llm-d") echo "8080" ;;
        "grafana") echo "3000" ;;
        *) echo "" ;;
    esac
}

# Available services
AVAILABLE_SERVICES="prometheus llm-d grafana"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 [start|stop|status|restart] [service...]"
    echo ""
    echo "Commands:"
    echo "  start               Start port forwarding for all services or specified services"
    echo "  stop                Stop all port forwarding processes"
    echo "  status              Show status of port forwarding processes"
    echo "  restart             Restart port forwarding (stop then start)"
    echo ""
    echo "Services:"
    echo "  prometheus          Prometheus monitoring (port 9090)"
    echo "  grafana             Grafana dashboard (port 3000)"
    echo "  llm-d               LLM-D inference gateway (port 8080)"
    echo ""
    echo "Examples:"
    echo "  $0 start                    # Start all services"
    echo "  $0 start grafana            # Start only Grafana"
    echo "  $0 start prometheus grafana # Start Prometheus and Grafana"
    echo "  $0 stop                     # Stop all services"
    echo "  $0 status                   # Show status"
    echo ""
    echo "Access URLs after starting:"
    echo "  Grafana:    http://127.0.0.1:3000 (admin/admin)"
    echo "  Prometheus: http://127.0.0.1:9090"
    echo "  LLM-D:      http://127.0.0.1:8080"
    exit 1
}

# Function to find SSH connection details
get_ssh_details() {
    local details_file
    local public_ip
    local ssh_key
    
    # Find the most recent instance details file
    details_file=$(ls -rt instance-*-details.txt 2>/dev/null | tail -1)
    
    if [ -z "$details_file" ]; then
        echo -e "${RED}Error: No instance details file found!${NC}"
        echo "Make sure you have deployed a cluster first using ./deploy-k8s-cluster.sh"
        exit 1
    fi
    
    # Extract connection details
    public_ip=$(grep "Public IP:" "$details_file" | cut -d' ' -f3)
    ssh_key=$(grep "ssh -i" "$details_file" | grep -o '~/.ssh/[^[:space:]]*')
    
    if [ -z "$public_ip" ] || [ "$public_ip" = "N/A" ]; then
        echo -e "${RED}Error: Could not find public IP in $details_file${NC}"
        exit 1
    fi
    
    if [ -z "$ssh_key" ]; then
        echo -e "${RED}Error: Could not find SSH key in $details_file${NC}"
        exit 1
    fi
    
    # Expand tilde
    ssh_key="${ssh_key/#\~/$HOME}"
    
    echo "$public_ip|$ssh_key"
}

# Function to check if a process is still running
is_process_running() {
    local pid="$1"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to cleanup PIDs file
cleanup_pids() {
    if [ -f "$PIDS_FILE" ]; then
        # Remove entries for dead processes
        temp_file=$(mktemp)
        while IFS='|' read -r service_name pid_type pid; do
            if is_process_running "$pid"; then
                echo "$service_name|$pid_type|$pid" >> "$temp_file"
            fi
        done < "$PIDS_FILE"
        mv "$temp_file" "$PIDS_FILE"
        
        # Remove file if empty
        if [ ! -s "$PIDS_FILE" ]; then
            rm -f "$PIDS_FILE"
        fi
    fi
}

# Function to start port forwarding for a service
start_service() {
    local service_name="$1"
    local service_config
    local local_port
    
    service_config=$(get_service_config "$service_name")
    local_port=$(get_local_port "$service_name")
    
    if [ -z "$service_config" ]; then
        echo -e "${RED}Error: Unknown service '$service_name'${NC}"
        return 1
    fi
    
    # Parse service configuration
    IFS=':' read -r namespace svc_name remote_port target_port <<< "$service_config"
    
    # Get SSH connection details
    local ssh_details
    ssh_details=$(get_ssh_details)
    IFS='|' read -r public_ip ssh_key <<< "$ssh_details"
    
    echo -e "${BLUE}Starting port forwarding for $service_name...${NC}"
    
    # Check if service is already running
    if [ -f "$PIDS_FILE" ]; then
        if grep -q "^$service_name|" "$PIDS_FILE"; then
            local existing_pids
            existing_pids=$(grep "^$service_name|" "$PIDS_FILE")
            local all_running=true
            
            while IFS='|' read -r svc pid_type pid; do
                if ! is_process_running "$pid"; then
                    all_running=false
                    break
                fi
            done <<< "$existing_pids"
            
            if [ "$all_running" = true ]; then
                echo -e "${YELLOW}Service $service_name is already running${NC}"
                return 0
            else
                echo -e "${YELLOW}Cleaning up stale processes for $service_name...${NC}"
                stop_service "$service_name"
            fi
        fi
    fi
    
    # Start remote kubectl port-forward
    echo "  Starting remote kubectl port-forward..."
    local remote_cmd="kubectl port-forward -n $namespace --address 0.0.0.0 $svc_name $remote_port:$target_port"
    
    ssh -f -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@"$public_ip" "$remote_cmd" >/dev/null 2>&1
    
    # Get the PID of the remote process
    sleep 2
    local remote_pid
    remote_pid=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@"$public_ip" "pgrep -f 'kubectl port-forward.*$svc_name'" 2>/dev/null | tail -1)
    
    if [ -z "$remote_pid" ]; then
        echo -e "${RED}Failed to start remote port-forward for $service_name${NC}"
        return 1
    fi
    
    # Start local SSH tunnel
    echo "  Starting local SSH tunnel..."
    ssh -f -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -L "$local_port:localhost:$remote_port" \
        ubuntu@"$public_ip" -N >/dev/null 2>&1
    
    # Get the PID of the local SSH tunnel
    sleep 1
    local tunnel_pid
    tunnel_pid=$(pgrep -f "ssh.*-L $local_port:localhost:$remote_port.*ubuntu@$public_ip" | head -1)
    
    if [ -z "$tunnel_pid" ]; then
        echo -e "${RED}Failed to start SSH tunnel for $service_name${NC}"
        # Kill the remote process
        ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@"$public_ip" "kill $remote_pid" 2>/dev/null || true
        return 1
    fi
    
    # Save PIDs
    echo "$service_name|remote|$remote_pid" >> "$PIDS_FILE"
    echo "$service_name|tunnel|$tunnel_pid" >> "$PIDS_FILE"
    
    echo -e "${GREEN}✓ $service_name is now available at http://127.0.0.1:$local_port${NC}"
    
    # Update status
    echo "$(date): Started $service_name (remote PID: $remote_pid, tunnel PID: $tunnel_pid)" >> "$STATUS_FILE"
}

# Function to stop port forwarding for a service
stop_service() {
    local service_name="$1"
    
    if [ ! -f "$PIDS_FILE" ]; then
        echo -e "${YELLOW}No port forwarding processes found${NC}"
        return 0
    fi
    
    local found=false
    local temp_file
    temp_file=$(mktemp)
    
    # Get SSH connection details for remote cleanup
    local ssh_details
    ssh_details=$(get_ssh_details 2>/dev/null)
    local public_ip=""
    local ssh_key=""
    if [ $? -eq 0 ]; then
        IFS='|' read -r public_ip ssh_key <<< "$ssh_details"
    fi
    
    while IFS='|' read -r svc pid_type pid; do
        if [ "$svc" = "$service_name" ]; then
            found=true
            echo -e "${BLUE}Stopping $pid_type process for $service_name (PID: $pid)...${NC}"
            
            if [ "$pid_type" = "remote" ] && [ -n "$public_ip" ] && [ -n "$ssh_key" ]; then
                # Kill remote process
                ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    ubuntu@"$public_ip" "kill $pid" 2>/dev/null || true
            elif [ "$pid_type" = "tunnel" ]; then
                # Kill local tunnel
                kill "$pid" 2>/dev/null || true
            fi
        else
            echo "$svc|$pid_type|$pid" >> "$temp_file"
        fi
    done < "$PIDS_FILE"
    
    mv "$temp_file" "$PIDS_FILE"
    
    # Remove file if empty
    if [ ! -s "$PIDS_FILE" ]; then
        rm -f "$PIDS_FILE"
    fi
    
    if [ "$found" = true ]; then
        echo -e "${GREEN}✓ Stopped port forwarding for $service_name${NC}"
        echo "$(date): Stopped $service_name" >> "$STATUS_FILE"
    else
        echo -e "${YELLOW}No running processes found for $service_name${NC}"
    fi
}

# Function to stop all port forwarding
stop_all() {
    echo -e "${BLUE}Stopping all port forwarding processes...${NC}"
    
    if [ ! -f "$PIDS_FILE" ]; then
        echo -e "${YELLOW}No port forwarding processes found${NC}"
        return 0
    fi
    
    # Get SSH connection details for remote cleanup
    local ssh_details
    ssh_details=$(get_ssh_details 2>/dev/null)
    local public_ip=""
    local ssh_key=""
    if [ $? -eq 0 ]; then
        IFS='|' read -r public_ip ssh_key <<< "$ssh_details"
    fi
    
    while IFS='|' read -r service_name pid_type pid; do
        echo "  Stopping $pid_type process for $service_name (PID: $pid)..."
        
        if [ "$pid_type" = "remote" ] && [ -n "$public_ip" ] && [ -n "$ssh_key" ]; then
            # Kill remote process
            ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                ubuntu@"$public_ip" "kill $pid" 2>/dev/null || true
        elif [ "$pid_type" = "tunnel" ]; then
            # Kill local tunnel
            kill "$pid" 2>/dev/null || true
        fi
    done < "$PIDS_FILE"
    
    rm -f "$PIDS_FILE"
    echo -e "${GREEN}✓ All port forwarding processes stopped${NC}"
    echo "$(date): Stopped all services" >> "$STATUS_FILE"
}

# Function to show status
show_status() {
    echo -e "${BLUE}Port Forwarding Status${NC}"
    echo "======================"
    
    if [ ! -f "$PIDS_FILE" ]; then
        echo -e "${YELLOW}No port forwarding processes running${NC}"
        return 0
    fi
    
    cleanup_pids
    
    if [ ! -f "$PIDS_FILE" ]; then
        echo -e "${YELLOW}No port forwarding processes running${NC}"
        return 0
    fi
    
    local services_running=""
    
    while IFS='|' read -r service_name pid_type pid; do
        if is_process_running "$pid"; then
            if ! echo " $services_running " | grep -q " $service_name "; then
                services_running="$services_running $service_name"
            fi
        fi
    done < "$PIDS_FILE"
    
    # Trim leading space
    services_running=$(echo "$services_running" | sed 's/^ *//')
    
    if [ -z "$services_running" ]; then
        echo -e "${YELLOW}No active port forwarding processes${NC}"
        rm -f "$PIDS_FILE"
        return 0
    fi
    
    for service_name in $services_running; do
        local local_port
        local_port=$(get_local_port "$service_name")
        echo -e "${GREEN}✓ $service_name${NC} - http://127.0.0.1:$local_port"
        
        # Show detailed PID info
        while IFS='|' read -r svc pid_type pid; do
            if [ "$svc" = "$service_name" ]; then
                echo "  $pid_type PID: $pid"
            fi
        done < "$PIDS_FILE"
    done
    
    echo ""
    echo "Access URLs:"
    for service_name in $services_running; do
        local local_port
        local_port=$(get_local_port "$service_name")
        case "$service_name" in
            "grafana")
                echo "  Grafana:    http://127.0.0.1:$local_port (admin/admin)"
                ;;
            "prometheus")
                echo "  Prometheus: http://127.0.0.1:$local_port"
                ;;
            "llm-d")
                echo "  LLM-D:      http://127.0.0.1:$local_port"
                ;;
        esac
    done
}

# Function to start specified services or all services
start_services() {
    local services_to_start="$*"
    
    if [ -z "$services_to_start" ]; then
        # Start all services
        services_to_start="$AVAILABLE_SERVICES"
    fi
    
    echo -e "${BLUE}Starting port forwarding...${NC}"
    
    for service_name in $services_to_start; do
        start_service "$service_name"
    done
    
    echo ""
    show_status
}

# Cleanup function for script exit
cleanup_on_exit() {
    echo ""
    echo -e "${YELLOW}Script interrupted. Port forwarding processes are still running.${NC}"
    echo "Use '$0 stop' to stop them or '$0 status' to check status."
}

# Set up signal handlers
trap cleanup_on_exit INT TERM

# Main script logic
case "${1:-}" in
    start)
        shift
        start_services "$@"
        ;;
    stop)
        if [ $# -eq 1 ]; then
            stop_all
        elif [ $# -eq 2 ]; then
            stop_service "$2"
        else
            echo "Error: stop command accepts at most one service name"
            usage
        fi
        ;;
    status)
        show_status
        ;;
    restart)
        shift
        echo -e "${BLUE}Restarting port forwarding...${NC}"
        if [ $# -eq 0 ]; then
            stop_all
            sleep 2
            start_services
        else
            for service in "$@"; do
                stop_service "$service"
            done
            sleep 2
            start_services "$@"
        fi
        ;;
    -h|--help|help)
        usage
        ;;
    "")
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        ;;
esac 