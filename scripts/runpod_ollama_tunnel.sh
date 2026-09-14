#!/usr/bin/env bash
set -euo pipefail

# Create or stop a background SSH tunnel from the Mac to a RunPod direct-TCP SSH endpoint.
# RunPod's ssh.runpod.io proxy does not support the channel forwarding needed here.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
STATE_DIR=""
WORKER=""
HOST=""
SSH_PORT=""
LOCAL_PORT=""
REMOTE_PORT=11434
SSH_USER=root
IDENTITY="$HOME/.ssh/id_ed25519"
NAME=""
STOP=0
WAIT_SECONDS=30

usage() {
  cat <<'USAGE'
Usage:
  runpod_ollama_tunnel.sh --worker N [options]
  runpod_ollama_tunnel.sh --host HOST --ssh-port PORT --local-port PORT [options]
  runpod_ollama_tunnel.sh --stop --worker N
  runpod_ollama_tunnel.sh --stop --local-port PORT

Worker mode:
  --worker N           Resolve connection settings from repo-local .env:
                         RUNPOD_BURST_N_HOST
                         RUNPOD_BURST_N_SSH_PORT
                         LME_BURST_N_URL

Options:
  --host HOST          Explicit direct-TCP public IP/host; overrides .env
  --ssh-port PORT      Explicit external TCP port mapped to container port 22
  --local-port PORT    Explicit local Mac port; overrides LME_BURST_N_URL
  --remote-port PORT   Remote Ollama port (default: 11434)
  --user USER          SSH user (default: root)
  --identity PATH      SSH private key (default: ~/.ssh/id_ed25519)
  --name NAME          Worker label used in status output
  --wait-seconds N     Endpoint readiness timeout (default: 30)
  --stop               Stop the selected tunnel
  -h, --help           Show this help

Preferred:
  scripts/runpod_ollama_tunnel.sh --worker 2

Explicit fallback:
  scripts/runpod_ollama_tunnel.sh \
    --name burst_2 \
    --host 69.30.85.231 \
    --ssh-port 22127 \
    --local-port 11442
USAGE
}

if [[ "${LME_SCRIPT_TIMESTAMPS:-1}" == "0" ]]; then
  info() { printf '%s\n' "$*"; }
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
else
  ts() { date '+%H:%M:%S'; }
  info() { printf '[%s] %s\n' "$(ts)" "$*"; }
  die() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }
fi

load_repo_env() {
  [[ -f "$ENV_FILE" ]] || die "worker mode requires $ENV_FILE; copy .env.example to .env and fill in real RunPod values"
  info "Loading worker connection settings from $ENV_FILE ..."
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

while (($#)); do
  case "$1" in
    --worker) WORKER="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    --remote-port) REMOTE_PORT="${2:-}"; shift 2 ;;
    --user) SSH_USER="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="${2:-}"; shift 2 ;;
    --stop) STOP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n "$WORKER" ]]; then
  [[ "$WORKER" =~ ^[1-9][0-9]*$ ]] || die "--worker must be a positive integer"
  load_repo_env

  host_var="RUNPOD_BURST_${WORKER}_HOST"
  ssh_port_var="RUNPOD_BURST_${WORKER}_SSH_PORT"
  endpoint_var="LME_BURST_${WORKER}_URL"

  [[ -n "$HOST" ]] || HOST="${!host_var:-}"
  [[ -n "$SSH_PORT" ]] || SSH_PORT="${!ssh_port_var:-}"

  if [[ -z "$LOCAL_PORT" ]]; then
    configured_endpoint="${!endpoint_var:-}"
    [[ -n "$configured_endpoint" ]] || die "$endpoint_var is not set in $ENV_FILE"
    if [[ "$configured_endpoint" =~ ^http://(127\.0\.0\.1|localhost):([0-9]+)$ ]]; then
      LOCAL_PORT="${BASH_REMATCH[2]}"
    else
      die "$endpoint_var must be a localhost HTTP endpoint such as http://127.0.0.1:11442"
    fi
  fi

  [[ -n "$NAME" ]] || NAME="burst_${WORKER}"
  [[ -n "${LME_RUNPOD_FLEET_DIR:-}" ]] || die "LME_RUNPOD_FLEET_DIR is not set; worker-mode tunnel state must be scoped to the current fleet"
  STATE_DIR="$LME_RUNPOD_FLEET_DIR/tunnels/legacy"
else
  [[ -n "$NAME" ]] || NAME="burst"
  STATE_DIR="$ROOT/output/manual-tunnels"
fi

[[ -n "$LOCAL_PORT" ]] || { usage >&2; die "--local-port is required (or use --worker N)"; }
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || die "--local-port must be an integer"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/runpod-ollama-${LOCAL_PORT}.pid"
LOG_FILE="$STATE_DIR/runpod-ollama-${LOCAL_PORT}.log"
KNOWN_HOSTS_FILE="$STATE_DIR/known_hosts-${LOCAL_PORT}"

if [[ $STOP -eq 1 ]]; then
  info "[1/2] Looking for tunnel on local port $LOCAL_PORT ..."
  if [[ ! -f "$PID_FILE" ]]; then
    info "No pid file found; nothing to stop."
    exit 0
  fi
  pid="$(cat "$PID_FILE")"
  info "[2/2] Stopping tunnel pid=$pid ..."
  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  info "Tunnel stopped."
  exit 0
fi

[[ -n "$HOST" ]] || { usage >&2; die "--host is required (or set RUNPOD_BURST_${WORKER:-N}_HOST in .env)"; }
[[ -n "$SSH_PORT" ]] || { usage >&2; die "--ssh-port is required (or set RUNPOD_BURST_${WORKER:-N}_SSH_PORT in .env)"; }

case "$HOST" in
  *'<'*|*'>'*) die "RunPod host still contains a placeholder: $HOST" ;;
esac
case "$SSH_PORT" in
  *'<'*|*'>'*) die "RunPod SSH port still contains a placeholder: $SSH_PORT" ;;
esac

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "--ssh-port must be an integer"
[[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || die "--remote-port must be an integer"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be an integer"
[[ -f "$IDENTITY" ]] || die "SSH identity not found: $IDENTITY"

case "$HOST" in
  ssh.runpod.io|*.ssh.runpod.io)
    die "RunPod proxy SSH does not support the forwarding channel we need. Use the Direct TCP host/IP and external port mapped to container port 22."
    ;;
esac

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE")"
  if kill -0 "$old_pid" 2>/dev/null; then
    die "tunnel already appears to be running on local port $LOCAL_PORT (pid=$old_pid)"
  fi
  rm -f "$PID_FILE"
fi

info "[1/4] Checking SSH reachability and key authentication ..."
ssh_probe="$(
  ssh \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -o ConnectTimeout=10 \
    -p "$SSH_PORT" \
    -i "$IDENTITY" \
    "$SSH_USER@$HOST" \
    'printf "direct-ssh-ok\\n"'
)" || die "direct SSH authentication failed"
[[ "$ssh_probe" == *direct-ssh-ok* ]] || die "direct SSH authentication failed"
info "Direct SSH PASS."

info "[2/4] Starting background tunnel 127.0.0.1:${LOCAL_PORT} -> pod 127.0.0.1:${REMOTE_PORT} ..."
nohup ssh \
  -N \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
  -p "$SSH_PORT" \
  -i "$IDENTITY" \
  "$SSH_USER@$HOST" \
  >"$LOG_FILE" 2>&1 &
pid=$!
echo "$pid" > "$PID_FILE"
if (( WAIT_SECONDS > 0 )); then
  sleep 1
fi
kill -0 "$pid" 2>/dev/null || {
  cat "$LOG_FILE" >&2 || true
  rm -f "$PID_FILE"
  die "SSH tunnel exited immediately"
}
info "Tunnel process running as pid=$pid."

ENDPOINT="http://127.0.0.1:${LOCAL_PORT}"
info "[3/4] Waiting for remote Ollama at $ENDPOINT ..."
ready=0
for ((i=1; i<=WAIT_SECONDS; i++)); do
  if curl -fsS "$ENDPOINT/api/version" > "$STATE_DIR/runpod-ollama-${LOCAL_PORT}-version.json" 2>/dev/null; then
    ready=1
    break
  fi
  if ((i % 5 == 0)); then
    info "Still waiting (${i}/${WAIT_SECONDS}s) ..."
  fi
  sleep 1
done

if [[ $ready -ne 1 ]]; then
  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  cat "$LOG_FILE" >&2 || true
  die "tunnel exists but Ollama did not become reachable within ${WAIT_SECONDS}s"
fi

version="$(cat "$STATE_DIR/runpod-ollama-${LOCAL_PORT}-version.json")"
info "Remote Ollama reachable: $version"

safe_name="$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_')"
env_name="LME_${safe_name}_URL"
info "[4/4] Tunnel PASS."
printf '\nLME/scorer endpoint: %s\n' "$ENDPOINT"
if [[ -n "$WORKER" ]]; then
  printf 'LME variable: %s (loaded from repo-local .env by LME)\n' "$env_name"
else
  printf 'For manual routing:\n'
  printf '  export %s=%s\n' "$env_name" "$ENDPOINT"
  printf '  export AF_OLLAMA_BASE_URL=%s\n' "$ENDPOINT"
fi
printf '\nTunnel pid file: %s\n' "$PID_FILE"
if [[ -n "$WORKER" ]]; then
  printf 'Stop it with:\n  %s --stop --worker %s\n' "$0" "$WORKER"
else
  printf 'Stop it with:\n  %s --stop --local-port %s\n' "$0" "$LOCAL_PORT"
fi
