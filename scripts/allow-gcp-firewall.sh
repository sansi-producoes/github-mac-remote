#!/bin/bash
# Adds this Mac session's public IP to the GCP proxy firewall.
# Needs GCP_SA_KEY (JSON) in the environment. Never prints the key.

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
    echo -e "${YELLOW}Skipping GCP firewall update (missing CURRENT_IP or GCP_SA_KEY)${NC}"
    exit 0
fi

echo -e "${CYAN}Allowing ${SESSION_IP} on proxy-pool-client${NC}"

KEYFILE="$(mktemp)"
printf '%s' "$GCP_SA_KEY" > "$KEYFILE"
gcloud auth activate-service-account --key-file="$KEYFILE" --quiet >/dev/null 2>&1
rm -f "$KEYFILE"

EXISTING="$(gcloud compute firewall-rules describe proxy-pool-client --project=angular-box-420305 --format='value(sourceRanges)' 2>/dev/null | tr ';' ',')"
if [ -z "$EXISTING" ]; then
    EXISTING="177.181.237.223/32"
fi

NEW_RANGE="${SESSION_IP}/32"
case ",${EXISTING}," in
    *",${NEW_RANGE},"*) echo -e "${GREEN}Already allowed${NC}"; exit 0 ;;
esac

gcloud compute firewall-rules update proxy-pool-client \
    --project=angular-box-420305 \
    --source-ranges="${EXISTING},${NEW_RANGE}" \
    --quiet

echo -e "${GREEN}Firewall now includes ${NEW_RANGE}${NC}"
exit 0
