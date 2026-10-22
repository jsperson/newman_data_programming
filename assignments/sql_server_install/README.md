# SQL Server 2025 in Docker, reachable over Tailscale only

Host: ThinkPad running Omarchy, Tailscale node `omarchy`, Tailscale IPv4 `100.94.249.116`.
Test client: Mac Studio `office-mac-studio`, Tailscale IPv4 `100.75.70.51`.

Goal: run SQL Server 2025 in Docker so other tailnet devices can reach it on 1433,
without exposing 1433 on the LAN or any public interface. The container does not
start automatically. This is for class, not production.

## Assignment command, and what changed

The assignment supplied:

```bash
docker volume create mssql1data
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=Password123" -p 1433:1433 \
  --name mssql1 --hostname mssql1 -v sql1data:/var/opt/mssql -d \
  mcr.microsoft.com/mssql/server:2025-latest
```

Changes made here:

- The volume names mismatch (`mssql1data` created, `sql1data` mounted). `mssql1data` is used for both.
- `Password123` is replaced with a unique SA password that meets SQL Server complexity
  (8+ characters, 3 of 4 classes). It is never typed on a command line. It lives in
  1Password and is passed once through a root-owned mode-600 env file via `--env-file`.
- The port is published only on the Tailscale address: `-p 100.94.249.116:1433:1433`.
- No restart policy. Start and stop the container by hand.

## Inspection results, 2026-10-21

Run before changing anything.

| Check | Result |
|---|---|
| `docker info` | Docker 29.9.1, overlayfs, cgroup v2 |
| `docker ps -a` | no containers |
| `docker volume ls` | no volumes; `mssql1data` and `sql1data` both "no such volume" |
| `docker images` | no mssql images |
| `tailscale ip -4` | 100.94.249.116 |
| `ss -tlnp` on 1433 | nothing listening |
| docker.service | disabled (socket-activated via docker.socket, enabled) |
| tailscaled.service | enabled, active |
| user groups | jsperson is in `docker` and `wheel` |
| memory | 15 GiB total, 10 GiB available |
| ufw | active; default deny incoming, deny routed |
| ufw-docker | installed (251123-2); DOCKER-USER chain present |

Two findings that shape the install:

1. **Boot ordering is a non-issue.** Docker is socket-activated, so the daemon only
   starts on the first `docker` call. With no restart policy the container never races
   tailscaled at boot. Nothing to fix.
2. **ufw-docker blocks tailnet clients by default.** The DOCKER-USER chain only passes
   forwarded traffic from 10/8, 172.16/12 and 192.168/16 sources. Tailscale addresses
   are in 100.64.0.0/10, so the Mac's connection would be dropped after DNAT even with
   the port bound to the Tailscale IP. One interface-scoped `ufw route` rule fixes this
   (step 4). The LAN gains nothing from it because the port is not published there.

## Step 1. Inspect (read-only)

Needs a warm sudo timestamp: run `sudo -v` first.

```bash
docker info --format '{{.ServerVersion}} {{.OperatingSystem}}'
docker ps -a
docker volume ls
docker volume inspect mssql1data sql1data
tailscale ip -4
sudo ss -tlnp | /usr/bin/grep -E ':1433|State'
systemctl is-enabled docker tailscaled docker.socket; systemctl is-active docker tailscaled
id -nG | /usr/bin/grep -w docker
sudo ufw status verbose
sudo iptables -S DOCKER-USER
```

Do not delete or replace existing containers or volumes without deciding first.

## Step 2. SA password (run in your own terminal, never through an agent)

Choose a password with 8+ characters and at least 3 of: uppercase, lowercase, digit,
symbol. Avoid quotes, `#`, spaces, `!` and `$` so the env file and the Mac shell do
not mangle it. Save it in 1Password first. Then:

```bash
read -rsp 'SA password: ' pw; echo
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\n' "$pw" | sudo sh -c 'umask 077; cat > /root/mssql1.env'
unset pw
sudo ls -l /root/mssql1.env
```

Expected: `-rw------- 1 root root ... /root/mssql1.env`.

Notes:

- `read -rs` keeps the password off the screen and out of shell history.
- Env-file values are literal. No quoting, no leading spaces.
- The password will be visible in `docker inspect mssql1` to anyone with docker socket
  access. Only inspect with `--format` filters.

## Step 3. Create the volume and container

```bash
docker volume create mssql1data
sudo docker run --env-file /root/mssql1.env \
  -p 100.94.249.116:1433:1433 \
  --name mssql1 --hostname mssql1 \
  -v mssql1data:/var/opt/mssql -d \
  mcr.microsoft.com/mssql/server:2025-latest
sudo shred -u /root/mssql1.env
```

`sudo` is needed only because the env file is root-owned. Docker copies the env into
the container config at creation, and SQL Server stores the SA password in `master`
on the volume after first start, so the file is not needed again. If the container is
ever recreated, redo step 2 from 1Password.

Pinned alternative image tag if `2025-latest` misbehaves: `2025-RTM-ubuntu-22.04`.

## Step 4. Firewall rule for tailnet clients

Required on this host (see inspection finding 2).

```bash
sudo ufw route allow in on tailscale0 proto tcp to any port 1433
sudo ufw status verbose
```

## Step 5. Verify on the ThinkPad

```bash
docker logs mssql1 2>&1 | /usr/bin/grep -m1 'SQL Server is now ready'
docker port mssql1
sudo ss -tlnp | /usr/bin/grep ':1433'
docker inspect mssql1 --format '{{.HostConfig.RestartPolicy.Name}}'
```

Expected:

- one line containing `SQL Server is now ready for client connections`
- `docker port` shows only `1433/tcp -> 100.94.249.116:1433`
- `ss` shows a listener on `100.94.249.116:1433` and nothing on `0.0.0.0:1433` or `[::]:1433`
- restart policy is `no`

First start takes 20 to 60 seconds. If the log is not ready yet, wait and rerun.

## Step 6. Verify from the Mac Studio

```bash
brew install sqlcmd
nc -vz 100.94.249.116 1433
sqlcmd -S 100.94.249.116,1433 -U sa -C -Q "SELECT @@VERSION;"
```

`sqlcmd` prompts for the password when `-P` is omitted, so it stays out of history.
`-C` trusts the container's self-signed certificate. With MagicDNS enabled,
`-S omarchy,1433` also works.

If `nc` connects but `sqlcmd` fails, the problem is the password or SQL Server not yet
ready. If `nc` times out, check step 4 and Tailscale ACLs (default ACLs allow all).

## Day to day

```bash
docker start mssql1
docker stop mssql1
docker logs -f mssql1
```

`docker start` fails with "cannot assign requested address" if Tailscale is not up
yet. Wait a few seconds and retry.

## Teardown, if ever needed

```bash
docker stop mssql1
docker rm mssql1
docker volume rm mssql1data      # destroys all databases
sudo ufw route delete allow in on tailscale0 proto tcp to any port 1433
```
