#!/usr/bin/env bash
# Start the mssql1 container (SQL Server 2025) and validate it.
# If it is already running, say so and validate only.
# See README.md in this folder for the install steps.

set -u

CONTAINER=mssql1
TS_IP=100.94.249.116
PORT=1433
READY_TIMEOUT=90   # seconds to wait for "SQL Server is now ready"

ok()   { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
FAILS=0

# --- container must exist -------------------------------------------------
if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Container '$CONTAINER' does not exist. Follow README.md steps 2 and 3 to create it."
    exit 2
fi

state=$(docker container inspect "$CONTAINER" --format '{{.State.Status}}')

# --- start if needed ------------------------------------------------------
if [ "$state" = "running" ]; then
    started=$(docker container inspect "$CONTAINER" --format '{{.State.StartedAt}}')
    echo "'$CONTAINER' is already running (since $started). Validating."
    # Only look at log lines from this run, so an old ready line can't satisfy us.
    LOG_SINCE="$started"
else
    echo "'$CONTAINER' is $state. Starting."
    if ! tailscale ip -4 2>/dev/null | grep -qx "$TS_IP"; then
        echo "Tailscale IP $TS_IP is not up. Start fails without it. Check: tailscale status"
        exit 3
    fi
    LOG_SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
    if ! docker start "$CONTAINER" >/dev/null; then
        echo "docker start failed. Recent logs:"
        docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/    /'
        exit 1
    fi
fi

# --- wait for SQL Server ready --------------------------------------------
printf 'Waiting for SQL Server to accept connections'
deadline=$((SECONDS + READY_TIMEOUT))
ready=0
while [ $SECONDS -lt $deadline ]; do
    if docker logs --since "$LOG_SINCE" "$CONTAINER" 2>&1 | grep -q 'SQL Server is now ready for client connections'; then
        ready=1; break
    fi
    # Bail early if the container died (bad password, OOM, etc.)
    if [ "$(docker container inspect "$CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
        break
    fi
    printf '.'; sleep 2
done
echo

echo "Validation:"

# 1. running
if [ "$(docker container inspect "$CONTAINER" --format '{{.State.Status}}')" = "running" ]; then
    ok "container is running"
else
    fail "container is not running. Recent logs:"
    docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/         /'
fi

# 2. ready line
if [ $ready -eq 1 ]; then
    ok "log shows 'SQL Server is now ready for client connections'"
else
    fail "no ready line within ${READY_TIMEOUT}s"
fi

# 3. docker port shows only the Tailscale IP
ports=$(docker port "$CONTAINER" 2>/dev/null)
if [ "$ports" = "${PORT}/tcp -> ${TS_IP}:${PORT}" ]; then
    ok "docker port: $ports"
else
    fail "docker port unexpected: ${ports:-<none>}"
fi

# 4. host listeners: Tailscale IP only, nothing on wildcard
listeners=$(ss -Htln "sport = :$PORT" | awk '{print $4}')
if echo "$listeners" | grep -qx "${TS_IP}:${PORT}"; then
    ok "listening on ${TS_IP}:${PORT}"
else
    fail "not listening on ${TS_IP}:${PORT}"
fi
if echo "$listeners" | grep -qE "^(0\.0\.0\.0|\*|\[::\]):${PORT}$"; then
    fail "wildcard listener found on port $PORT: $(echo "$listeners" | tr '\n' ' ')"
else
    ok "no wildcard listener on port $PORT"
fi

# 5. no restart policy
rp=$(docker container inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}')
if [ "$rp" = "no" ] || [ -z "$rp" ]; then
    ok "restart policy: ${rp:-no} (manual start only)"
else
    fail "restart policy is '$rp', expected none"
fi

# 6. ufw route rule for tailnet clients (only checkable with a warm sudo)
if sudo -n true 2>/dev/null; then
    if sudo -n ufw status 2>/dev/null | grep -qE "^${PORT}/tcp +ALLOW FWD +Anywhere on tailscale0"; then
        ok "ufw route rule for tailscale0:${PORT} present"
    else
        fail "ufw route rule missing. README step 4."
    fi
else
    echo "  [skip] ufw rule check needs sudo (run 'sudo -v' first)"
fi

echo
if [ $FAILS -eq 0 ]; then
    echo "All checks passed. From the Mac Studio:"
    echo "  sqlcmd -S ${TS_IP},${PORT} -U sa -C -Q \"SELECT @@VERSION;\""
    exit 0
else
    echo "$FAILS check(s) failed."
    exit 1
fi
