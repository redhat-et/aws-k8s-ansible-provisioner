#!/bin/bash

# Auto-shutdown script for idle AWS instances
# This script monitors system activity and shuts down the instance when idle

# Configuration
IDLE_TIME_MINUTES=${IDLE_TIME_MINUTES:-60}  # Default 60 minutes
CHECK_INTERVAL_MINUTES=${CHECK_INTERVAL_MINUTES:-5}  # Check every 5 minutes
LOG_FILE="/var/log/auto-shutdown.log"
DISABLE_FILE="/tmp/disable-auto-shutdown"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check if auto-shutdown is disabled
is_disabled() {
    if [ -f "$DISABLE_FILE" ]; then
        log_message "Auto-shutdown is disabled (file $DISABLE_FILE exists)"
        return 0
    fi
    return 1
}

# Function to check SSH connections
check_ssh_activity() {
    # Count active SSH sessions (excluding the current script)
    local ssh_count=$(who | grep -v "$(whoami)" | wc -l)
    echo $ssh_count
}

# Function to check system load
check_system_load() {
    # Get 1-minute load average
    local load=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    echo $load
}

# Function to check network activity
check_network_activity() {
    # Check for recent network connections on common ports
    local connections=$(netstat -tn | grep -E ':22|:80|:443|:8080|:3000|:9090' | grep ESTABLISHED | wc -l)
    echo $connections
}

# Function to check GPU utilization
check_gpu_activity() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        # Check if any GPU has utilization > 5%
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | awk '{if($1>5) print $1}' | wc -l)
        echo $gpu_util
    else
        echo 0
    fi
}

# Function to check Kubernetes pod activity
check_k8s_activity() {
    if command -v kubectl >/dev/null 2>&1; then
        # Check if there are any running pods that are not system pods
        local user_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running 2>/dev/null | grep -v -E "kube-system|kube-public|kube-node-lease|local-path-storage|gpu-operator" | wc -l)
        # Subtract 1 for header line
        echo $((user_pods - 1))
    else
        echo 0
    fi
}

# Function to check if system is idle
is_system_idle() {
    local ssh_sessions=$(check_ssh_activity)
    local system_load=$(check_system_load)
    local network_connections=$(check_network_activity)
    local gpu_activity=$(check_gpu_activity)
    local k8s_activity=$(check_k8s_activity)
    
    log_message "Activity check - SSH sessions: $ssh_sessions, Load: $system_load, Network: $network_connections, GPU active: $gpu_activity, K8s pods: $k8s_activity"
    
    # System is considered idle if:
    # - No SSH sessions (except system processes)
    # - System load < 0.5
    # - No active network connections on monitored ports
    # - No GPU activity
    # - No user workload pods running
    
    if [ "$ssh_sessions" -eq 0 ] && \
       [ "$(echo "$system_load < 0.5" | bc -l 2>/dev/null || echo 0)" -eq 1 ] && \
       [ "$network_connections" -eq 0 ] && \
       [ "$gpu_activity" -eq 0 ] && \
       [ "$k8s_activity" -eq 0 ]; then
        return 0  # System is idle
    else
        return 1  # System is active
    fi
}

# Function to shutdown the instance
shutdown_instance() {
    log_message "System has been idle for $IDLE_TIME_MINUTES minutes. Initiating shutdown..."
    
    # Try to get instance ID from metadata
    local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
    log_message "Shutting down instance: $instance_id"
    
    # Send a wall message to any logged-in users
    wall "System is shutting down due to inactivity. Instance will be stopped to save costs."
    
    # Wait a moment for the message to be delivered
    sleep 10
    
    # Shutdown the system
    /sbin/shutdown -h now "Auto-shutdown due to inactivity"
}

# Main monitoring loop
main() {
    log_message "Auto-shutdown monitor started (idle time: ${IDLE_TIME_MINUTES}m, check interval: ${CHECK_INTERVAL_MINUTES}m)"
    
    local idle_count=0
    local checks_needed=$((IDLE_TIME_MINUTES / CHECK_INTERVAL_MINUTES))
    
    while true; do
        # Check if auto-shutdown is disabled
        if is_disabled; then
            idle_count=0
            sleep $((CHECK_INTERVAL_MINUTES * 60))
            continue
        fi
        
        if is_system_idle; then
            idle_count=$((idle_count + 1))
            log_message "System idle check $idle_count/$checks_needed"
            
            if [ $idle_count -ge $checks_needed ]; then
                shutdown_instance
                exit 0
            fi
        else
            if [ $idle_count -gt 0 ]; then
                log_message "System activity detected, resetting idle counter"
            fi
            idle_count=0
        fi
        
        sleep $((CHECK_INTERVAL_MINUTES * 60))
    done
}

# Handle script arguments
case "${1:-}" in
    "start")
        main
        ;;
    "stop")
        pkill -f "auto-shutdown.sh"
        log_message "Auto-shutdown monitor stopped"
        ;;
    "disable")
        touch "$DISABLE_FILE"
        log_message "Auto-shutdown disabled until next reboot or manual enable"
        ;;
    "enable")
        rm -f "$DISABLE_FILE"
        log_message "Auto-shutdown enabled"
        ;;
    "status")
        if is_disabled; then
            echo "Auto-shutdown is DISABLED"
        else
            echo "Auto-shutdown is ENABLED"
        fi
        if pgrep -f "auto-shutdown.sh" >/dev/null; then
            echo "Auto-shutdown monitor is RUNNING"
        else
            echo "Auto-shutdown monitor is NOT RUNNING"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|disable|enable|status}"
        echo ""
        echo "Environment variables:"
        echo "  IDLE_TIME_MINUTES - Minutes of inactivity before shutdown (default: 60)"
        echo "  CHECK_INTERVAL_MINUTES - How often to check activity (default: 5)"
        echo ""
        echo "To disable temporarily: touch $DISABLE_FILE"
        echo "To view logs: tail -f $LOG_FILE"
        exit 1
        ;;
esac 