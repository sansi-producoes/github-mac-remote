#!/bin/bash
# Removes this Mac session's public IP from the GCP proxy firewall on teardown.
# Prevents accumulation of recycled Azure runner IPs and respects GCP's 256-CIDR limit.

set +e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SESSION_IP="${CURRENT_IP:-}"
if [ -z "$SESSION_IP" ]; then
    SESSION_IP="$(curl -s --max-time 8 https://api.ipify.org)"
fi

if [ -z "$SESSION_IP" ] || [ -z "${GCP_SA_KEY:-}" ]; then
    echo -e "${YELLOW}Skipping GCP firewall cleanup (missing CURRENT_IP or GCP_SA_KEY)${NC}"
    exit 0
fi

TARGET_CIDR="${SESSION_IP}/32"
echo -e "${CYAN}🧹 Removing ${TARGET_CIDR} from GCP firewall rules...${NC}"

KEYFILE="$(mktemp)"
printf '%s' "$GCP_SA_KEY" > "$KEYFILE"
gcloud auth activate-service-account --key-file="$KEYFILE" --quiet >/dev/null 2>&1
rm -f "$KEYFILE"

remove_cidr_from_rule() {
    local rule_name="$1"
    local existing
    existing="$(gcloud compute firewall-rules describe "$rule_name" --project=angular-box-420305 --format='value(sourceRanges)' 2>/dev/null | tr ';' ',')"
    [ -z "$existing" ] && return 0

    local updated
    updated="$(echo "$existing" | tr ',' '\n' | grep -vxF "$TARGET_CIDR" | paste -sd ',' -)"
    if [ -z "$updated" ]; then
        updated="177.181.237.223/32"
    fi

    if [ "$updated" != "$existing" ]; then
        gcloud compute firewall-rules update "$rule_name" \
            --project=angular-box-420305 \
            --source-ranges="$updated" \
            --quiet >/dev/null 2>&1 && \
            echo -e "${GREEN}✅ Removed ${TARGET_CIDR} from ${rule_name}${NC}"
    fi
}

remove_cidr_from_rule "proxy-pool-client"
remove_cidr_from_rule "proxy-pool-wg"

exit 0
