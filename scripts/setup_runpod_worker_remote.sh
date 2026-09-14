#!/usr/bin/env bash
set -euo pipefail

# Mac-side wrapper for configuring an already-created RunPod worker.
# Resolves direct SSH coordinates from the selected fleet environment and streams
# setup_runpod_ollama_worker.sh into the selected pod.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET_KEY="${LME_RUNPOD_FLEET:-default}"
if [[ "$FLEET_KEY" == "default" ]]; then
  ENV_FILE="$ROOT/.env"
else
  ENV_FILE="$ROOT/output/runpod-fleets/fleets/$FLEET_KEY/fleet.env"
fi
REMOTE_SETUP="$ROOT/scripts/setup_runpod_ollama_worker.sh"
WORKER=""
SSH_USER=root
IDENTITY="$HOME/.ssh/id_ed25519"
REMOTE_ARGS=()

usage() {
  cat <<'USAGE'
Usage:
  setup_runpod_worker_remote.sh --worker N [remote setup arguments]

Worker addressing is loaded from the selected fleet environment file:
  RUNPOD_BURST_N_HOST
  RUNPOD_BURST_N_SSH_PORT

Wrapper options:
  --worker N          Burst worker number (required)
  --user USER         SSH user (default: root)
  --identity PATH     SSH private key (default: ~/.ssh/id_ed25519)
  -h, --help          Show this help

All other arguments are forwarded unchanged to setup_runpod_ollama_worker.sh.

Example:
  scripts/setup_runpod_worker_remote.sh \
    --worker 2 \
    --clean \
    --model qwen3.6:27b \
    --expect-digest qwen3.6:27b=9d5803d493a991af27b9441c098aa56f2ed7bbd260877f075ec09b575c049bc3
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

while (($#)); do
  case "$1" in
    --worker)
      [[ $# -ge 2 ]] || die "--worker requires a value"
      WORKER="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      SSH_USER="$2"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 ]] || die "--identity requires a value"
      IDENTITY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      REMOTE_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ "$WORKER" =~ ^[1-9][0-9]*$ ]] || { usage >&2; die "--worker must be a positive integer"; }
[[ -f "$ENV_FILE" ]] || die "missing RunPod fleet environment file: $ENV_FILE"
[[ -f "$REMOTE_SETUP" ]] || die "remote setup script not found: $REMOTE_SETUP"
[[ -f "$IDENTITY" ]] || die "SSH identity not found: $IDENTITY"

info "[1/4] Loading worker $WORKER connection settings from $ENV_FILE ..."
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

host_var="RUNPOD_BURST_${WORKER}_HOST"
ssh_port_var="RUNPOD_BURST_${WORKER}_SSH_PORT"
HOST="${!host_var:-}"
SSH_PORT="${!ssh_port_var:-}"

[[ -n "$HOST" ]] || die "$host_var is not set in $ENV_FILE"
[[ -n "$SSH_PORT" ]] || die "$ssh_port_var is not set in $ENV_FILE"
case "$HOST" in
  *'<'*|*'>'*) die "$host_var still contains a placeholder: $HOST" ;;
  ssh.runpod.io|*.ssh.runpod.io)
    die "$host_var points at RunPod proxy SSH; use the Direct TCP host/IP"
    ;;
esac
case "$SSH_PORT" in
  *'<'*|*'>'*) die "$ssh_port_var still contains a placeholder: $SSH_PORT" ;;
esac
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "$ssh_port_var must be an integer"
[[ -n "${LME_RUNPOD_FLEET_DIR:-}" ]] || die "LME_RUNPOD_FLEET_DIR is not set; remote worker SSH state must be scoped to the current fleet"

SSH_STATE_DIR="$LME_RUNPOD_FLEET_DIR/ssh"
KNOWN_HOSTS_FILE="$SSH_STATE_DIR/known_hosts-burst_${WORKER}"
mkdir -p "$SSH_STATE_DIR"
: >> "$KNOWN_HOSTS_FILE"
chmod 600 "$KNOWN_HOSTS_FILE"
SSH_COMMON_ARGS=(
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE"
  -p "$SSH_PORT"
  -i "$IDENTITY"
)

info "[2/4] Resolved worker $WORKER -> ${SSH_USER}@${HOST}:${SSH_PORT}"
info "Worker-specific SSH host keys: $KNOWN_HOSTS_FILE"
info "[3/4] Checking direct SSH reachability and key authentication ..."
ssh_probe="$(
  ssh \
    "${SSH_COMMON_ARGS[@]}" \
    -o ConnectTimeout=10 \
    "$SSH_USER@$HOST" \
    'printf "direct-ssh-ok\\n"'
)" || die "direct SSH authentication failed"
[[ "$ssh_probe" == *direct-ssh-ok* ]] || die "direct SSH authentication failed"
info "Direct SSH PASS."

remote_command="bash -s --"
for arg in "${REMOTE_ARGS[@]}"; do
  printf -v quoted '%q' "$arg"
  remote_command+=" $quoted"
done

info "[4/4] Streaming setup_runpod_ollama_worker.sh to worker $WORKER ..."
info "Remote setup progress follows. Normal bootstrap may pull/rsync models; --reuse-existing never does."
ssh \
  "${SSH_COMMON_ARGS[@]}" \
  "$SSH_USER@$HOST" \
  "$remote_command" \
  < "$REMOTE_SETUP"

info "Worker $WORKER remote setup PASS."
