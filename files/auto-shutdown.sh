#!/bin/bash

# Auto-shutdown script for idle AWS instances.
# Shuts down the OS, triggering the instance to stop.

# --- Configuration (from systemd environment variables) ---
# How many minutes of inactivity before shutting down.
IDLE_TIME_MINUTES=${IDLE_TIME_MINUTES:-60}

# Whether the auto-shutdown feature is enabled.
ENABLED=${ENABLED:-true}

# How often (in minutes) to check for activity.
CHECK_INTERVAL_MINUTES=${CHECK_INTERVAL_MINUTES:-5}

# --- Script Internals ---
LOG_FILE="/var/log/auto-shutdown.log"
IDLE_START_TIME_FILE="/tmp/idle_start_time"

# Log messages to a dedicated log file.
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check for active SSH sessions, excluding self.
is_system_idle() {
    # Check 1: Current active sessions
    local current_sessions
    current_sessions=$(who | wc -l)
    if [ "$current_sessions" -gt 0 ]; then
        return 1 # Not idle - active sessions
    fi
    
    # Check 2: Recent login activity (within the last check interval + buffer)
    local check_period_seconds=$((CHECK_INTERVAL_MINUTES * 60 + 120))  # Add 2-minute buffer
    local recent_logins
    recent_logins=$(last -s "-${check_period_seconds} seconds" -n 10 2>/dev/null | grep -c "pts/" || echo "0")
    if [ "$recent_logins" -gt 0 ]; then
        return 1 # Not idle - recent login detected
    fi
    
    return 0 # System appears idle
}

# Shut down the OS.
shutdown_os() {
    log_message "Instance has been idle for over ${IDLE_TIME_MINUTES} minutes. Shutting down OS."
    /sbin/shutdown -h now
}

# --- Main Loop ---
main() {
    log_message "Auto-shutdown service started. Checking for inactivity every ${CHECK_INTERVAL_MINUTES} minutes."
    log_message "Instance will be stopped after ${IDLE_TIME_MINUTES} minutes of inactivity by shutting down the OS."

    while true; do
        if is_system_idle; then
            # If the system is idle, check if we've already marked the start time.
            if [ ! -f "$IDLE_START_TIME_FILE" ]; then
                log_message "System is idle. Starting idle timer."
                date +%s > "$IDLE_START_TIME_FILE"
            else
                # If the timer has started, check how long it's been.
                start_time=$(cat "$IDLE_START_TIME_FILE")
                current_time=$(date +%s)
                idle_duration_minutes=$(((current_time - start_time) / 60))

                log_message "System has been idle for ${idle_duration_minutes} minute(s)."

                if [ "$idle_duration_minutes" -ge "$IDLE_TIME_MINUTES" ]; then
                    shutdown_os
                    exit 0
                fi
            fi
        else
            # If the system is not idle, remove the timer file.
            if [ -f "$IDLE_START_TIME_FILE" ]; then
                log_message "Activity detected. Resetting idle timer."
                rm "$IDLE_START_TIME_FILE"
            fi
        fi

        sleep $((CHECK_INTERVAL_MINUTES * 60))
    done
}

# --- Entry Point ---
if [ "$ENABLED" != "true" ]; then
    log_message "Auto-shutdown is disabled by configuration."
    exit 0
fi

main 