#!/bin/bash
# keep-alive.sh - Keep session alive and show countdown

set -e

# Duration in hours (default 2)
DURATION_HOURS="${DURATION_HOURS:-2}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-300}" # 5 minutes in seconds
WARNING_15MIN="${WARNING_15MIN:-true}"
WARNING_5MIN="${WARNING_5MIN:-true}"

# Calculate end time
DURATION_SECONDS=$((DURATION_HOURS * 3600))
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SECONDS))

# RustDesk watchdog: the remote user gets frozen out when the host app dies.
# Each keep-alive cycle checks the process and respawns it if it crashed.
ensure_rustdesk() {
    if ! pgrep -f "RustDesk.app/Contents/MacOS/RustDesk" >/dev/null 2>&1; then
        echo ""
        echo "🔄 RustDesk died — respawning at $(date '+%H:%M:%S')"
        open -a RustDesk 2>/dev/null || /Applications/RustDesk.app/Contents/MacOS/rustdesk >/dev/null 2>&1 &
        sleep 5
        if pgrep -f "RustDesk.app/Contents/MacOS/RustDesk" >/dev/null 2>&1; then
            echo "🔄 RustDesk respawned OK"
        else
            echo "⚠️ RustDesk respawn attempt failed"
        fi
    fi
}

echo ""
echo "⏱️  Session keep-alive started"
echo "   Duration: ${DURATION_HOURS} hour(s)"
echo "   End time: $(date -r ${END_TIME} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

warned_15min=false
warned_5min=false

while true; do
    CURRENT_TIME=$(date +%s)
    REMAINING=$((END_TIME - CURRENT_TIME))
    
    if [ $REMAINING -le 0 ]; then
        echo ""
        echo "⏰ Session time expired. Shutting down..."
        break
    fi
    
    # RustDesk watchdog: respawn the remote-access app if it crashed
    ensure_rustdesk

    # Calculate human-readable time
    HOURS=$((REMAINING / 3600))
    MINUTES=$(((REMAINING % 3600) / 60))
    SECONDS=$((REMAINING % 60))
    
    # 15 minute warning
    if [ $REMAINING -le 900 ] && [ "$warned_15min" = false ] && [ "$WARNING_15MIN" = "true" ]; then
        echo ""
        echo "⚠️  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  WARNING: Session ends in 15 minutes!"
        echo "⚠️  Save your work and prepare to reconnect if needed."
        echo "⚠️  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        warned_15min=true
    fi
    
    # 5 minute warning
    if [ $REMAINING -le 300 ] && [ "$warned_5min" = false ] && [ "$WARNING_5MIN" = "true" ]; then
        echo ""
        echo "🚨 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🚨 URGENT: Session ends in 5 minutes!"
        echo "🚨 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        warned_5min=true
    fi
    
    # Heartbeat message
    printf "\r💓 [%02d:%02d:%02d remaining] Session active - $(date '+%H:%M:%S')     " $HOURS $MINUTES $SECONDS
    
    # Sleep for the interval or remaining time, whichever is smaller
    SLEEP_TIME=$((REMAINING < KEEPALIVE_INTERVAL ? REMAINING : KEEPALIVE_INTERVAL))
    sleep $SLEEP_TIME
    
    # Print newline periodically for log readability
    if [ $((CURRENT_TIME % (KEEPALIVE_INTERVAL * 6))) -lt $KEEPALIVE_INTERVAL ]; then
        echo ""
    fi
done

echo ""
echo "👋 Session ended. Thank you for using GitHub Mac Remote!"
