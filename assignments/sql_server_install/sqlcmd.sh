#!/usr/bin/env bash
# Open a sqlcmd session to the mssql1 container as sa.
# Uses the sqlcmd shipped inside the container, so nothing to install.
#
# Usage:
#   ./sqlcmd.sh                          interactive session (type GO to run, QUIT to leave)
#   ./sqlcmd.sh -Q "SELECT @@VERSION;"   run one query and exit
#   ./sqlcmd.sh -d MyDb                  start in a specific database
#   ./sqlcmd.sh < script.sql             run a .sql file from the host
#
# Password: prompts unless SQLCMDPASSWORD is exported in this shell.
# Output defaults: -w 300 wrap width, -Y 30 / -y 30 cap each column at 30 chars
# so results stay aligned without padding to the declared size. Pass -W for
# compact unpadded output; the caps are dropped then, since sqlcmd rejects -W
# with -Y/-y. Any other extra arguments are passed straight through to sqlcmd.

set -u

CONTAINER=mssql1
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

state=$(docker container inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null)
if [ -z "$state" ]; then
    echo "Container '$CONTAINER' does not exist. See README.md in this folder." >&2
    exit 2
fi
if [ "$state" != "running" ]; then
    echo "Container '$CONTAINER' is $state. Start it with: $(dirname "$0")/start_mssql.sh" >&2
    exit 3
fi

# -t only when stdin is a terminal, so  ./sqlcmd.sh < file.sql  works too.
tty_flag=()
[ -t 0 ] && tty_flag=(-t)

# Pass SQLCMDPASSWORD into the container only if it is set here.
env_flag=()
[ -n "${SQLCMDPASSWORD:-}" ] && env_flag=(-e SQLCMDPASSWORD)

# Column width caps keep output aligned. sqlcmd refuses them alongside -W.
fmt_flags=(-w 300 -Y 30 -y 30)
for arg in "$@"; do
    [ "$arg" = "-W" ] && fmt_flags=(-w 300)
done

exec docker exec -i "${tty_flag[@]}" "${env_flag[@]}" "$CONTAINER" \
    "$SQLCMD" -S localhost -U sa -C "${fmt_flags[@]}" "$@"
