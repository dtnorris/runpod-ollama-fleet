#!/usr/bin/env bash
set -euo pipefail

# Bootstrap an already-created RunPod GPU worker as an Ollama inference appliance.
#
# Design goals:
# - do not provision or destroy RunPod resources;
# - pull model weights on the fast local/root disk;
# - optionally keep a single-model bootstrap on root instead of copying to /workspace;
# - otherwise copy completed Ollama stores to /workspace one model at a time;
# - serve inference from the selected final store at the requested context length;
# - verify model digest, full GPU residency, and context before declaring success;
# - emit incremental console feedback for every long-running step.

CONTEXT_LENGTH=131072
STAGING_DIR=/root/.ollama/models
SHARED_DIR=/workspace/ollama-models
STATE_ROOT=/workspace/lme-worker-state
SERVER_HOST=127.0.0.1:11434
CLIENT_URL=http://127.0.0.1:11434
MIN_VRAM_GB=40
EXPECTED_GPU_NAME=""
CLEAN=0
REUSE_EXISTING=0
KEEP_ROOT_MODELS=0
MODELS=()
declare -A EXPECTED_DIGESTS=()
declare -A FINAL_DIGESTS=()
declare -A VERIFIED_CONTEXTS=()
declare -A VERIFIED_SIZES=()
declare -A VERIFIED_SIZES_VRAM=()
OLLAMA_PID=""
FINAL_SERVER_READY=0
STEP=0
TOTAL_STEPS=8

usage() {
  cat <<'USAGE'
Usage:
  setup_runpod_ollama_worker.sh --model MODEL [--model MODEL ...] [options]

Required:
  --model MODEL                 Ollama model to install. Repeat for multiple models.

Options:
  --context N                   Ollama context length (default: 131072)
  --staging-dir PATH            Fast local staging store (default: /root/.ollama/models)
  --shared-dir PATH             Shared/workspace store (default: /workspace/ollama-models)
  --state-root PATH             Worker evidence directory (default: /workspace/lme-worker-state)
  --min-vram-gb N               Minimum detected GPU VRAM (default: 40)
  --expect-gpu NAME             Fail before model pull unless detected GPU name matches exactly.
  --expect-digest MODEL=DIGEST  Fail unless the requested model has this full digest. Repeatable.
  --clean                       Delete both staging and shared Ollama stores before setup.
  --reuse-existing              Reuse /workspace cache only; never pull, stage, or rsync model data.
  --keep-root-models            Keep one pulled model in root storage and serve it there; skip rsync.
  -h, --help                    Show this help.

Example for the first automated worker-2 validation:
  bash setup_runpod_ollama_worker.sh \
    --clean \
    --model qwen3.6:27b \
    --expect-digest qwen3.6:27b=9d5803d493a991af27b9441c098aa56f2ed7bbd260877f075ec09b575c049bc3
USAGE
}

ts() { date '+%H:%M:%S'; }
info() { printf '[%s] %s\n' "$(ts)" "$*"; }
step() {
  STEP=$((STEP + 1))
  printf '\n[%s] [%d/%d] %s\n' "$(ts)" "$STEP" "$TOTAL_STEPS" "$*"
}
die() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || die "--model requires a value"
      MODELS+=("$2"); shift 2 ;;
    --context)
      [[ $# -ge 2 ]] || die "--context requires a value"
      CONTEXT_LENGTH="$2"; shift 2 ;;
    --staging-dir)
      [[ $# -ge 2 ]] || die "--staging-dir requires a value"
      STAGING_DIR="$2"; shift 2 ;;
    --shared-dir)
      [[ $# -ge 2 ]] || die "--shared-dir requires a value"
      SHARED_DIR="$2"; shift 2 ;;
    --state-root)
      [[ $# -ge 2 ]] || die "--state-root requires a value"
      STATE_ROOT="$2"; shift 2 ;;
    --min-vram-gb)
      [[ $# -ge 2 ]] || die "--min-vram-gb requires a value"
      MIN_VRAM_GB="$2"; shift 2 ;;
    --expect-gpu)
      [[ $# -ge 2 ]] || die "--expect-gpu requires a value"
      EXPECTED_GPU_NAME="$2"
      shift 2 ;;
    --expect-digest)
      [[ $# -ge 2 ]] || die "--expect-digest requires MODEL=DIGEST"
      [[ "$2" == *=* ]] || die "--expect-digest must be MODEL=DIGEST"
      EXPECTED_DIGESTS["${2%%=*}"]="${2#*=}"
      shift 2 ;;
    --clean)
      CLEAN=1; shift ;;
    --reuse-existing)
      REUSE_EXISTING=1; shift ;;
    --keep-root-models)
      KEEP_ROOT_MODELS=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

((${#MODELS[@]} > 0)) || { usage >&2; die "at least one --model is required"; }
[[ "$CONTEXT_LENGTH" =~ ^[0-9]+$ ]] || die "--context must be an integer"
[[ "$MIN_VRAM_GB" =~ ^[0-9]+$ ]] || die "--min-vram-gb must be an integer"
if [[ $REUSE_EXISTING -eq 1 && $CLEAN -eq 1 ]]; then
  die "--clean cannot be combined with --reuse-existing"
fi
if [[ $REUSE_EXISTING -eq 1 && $KEEP_ROOT_MODELS -eq 1 ]]; then
  die "--keep-root-models cannot be combined with --reuse-existing"
fi
if [[ $KEEP_ROOT_MODELS -eq 1 && ${#MODELS[@]} -ne 1 ]]; then
  die "--keep-root-models requires exactly one --model"
fi
if [[ $REUSE_EXISTING -eq 1 ]]; then
  for model in "${MODELS[@]}"; do
    [[ -n "${EXPECTED_DIGESTS[$model]:-}" ]] || \
      die "--reuse-existing requires --expect-digest for $model; cache reuse never guesses model identity"
  done
fi
[[ "$(id -u)" -eq 0 ]] || die "run this script as root inside the RunPod pod"

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
STATE_DIR="$STATE_ROOT/$STAMP"
mkdir -p "$STATE_DIR"

stop_ollama() {
  if [[ -n "${OLLAMA_PID:-}" ]] && kill -0 "$OLLAMA_PID" 2>/dev/null; then
    info "Stopping Ollama server pid=$OLLAMA_PID ..."
    kill "$OLLAMA_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$OLLAMA_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$OLLAMA_PID" 2>/dev/null || true
  fi
  OLLAMA_PID=""
  pkill -x ollama 2>/dev/null || true
  sleep 1
}

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 && $FINAL_SERVER_READY -ne 1 ]]; then
    printf '\n[%s] Setup failed; stopping any temporary Ollama server. Evidence: %s\n' "$(ts)" "$STATE_DIR" >&2
    stop_ollama
  fi
  exit "$rc"
}
trap cleanup_on_error EXIT
trap 'exit 130' INT TERM

wait_for_ollama() {
  local attempts=60
  info "Waiting for Ollama API at $CLIENT_URL ..."
  for ((i=1; i<=attempts; i++)); do
    if curl -fsS "$CLIENT_URL/api/version" > "$STATE_DIR/ollama-version.json" 2>/dev/null; then
      info "Ollama API is ready."
      return 0
    fi
    if ((i % 5 == 0)); then
      info "Still waiting for Ollama (${i}/${attempts}) ..."
    fi
    sleep 1
  done
  return 1
}

start_ollama() {
  local store="$1"
  local label="$2"
  local log="$STATE_DIR/ollama-${label}.log"
  stop_ollama
  mkdir -p "$store"
  info "Starting Ollama with model store: $store"
  info "Context length: $CONTEXT_LENGTH"
  OLLAMA_MODELS="$store" \
  OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH" \
  OLLAMA_HOST="$SERVER_HOST" \
    nohup ollama serve >"$log" 2>&1 &
  OLLAMA_PID=$!
  wait_for_ollama || {
    tail -100 "$log" >&2 || true
    die "Ollama did not become ready; see $log"
  }
}

model_digest() {
  local model="$1"
  curl -fsS "$CLIENT_URL/api/tags" | jq -r --arg model "$model" \
    '.models[] | select(.name == $model or .model == $model) | .digest' | head -n 1
}

model_ps_json() {
  local model="$1"
  curl -fsS "$CLIENT_URL/api/ps" | jq -c --arg model "$model" \
    '.models[] | select(.name == $model or .model == $model)' | head -n 1
}

step "Preflight host, GPU, and required utilities"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is required"

GPU_LINE="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -n 1)"
GPU_NAME="${GPU_LINE%,*}"
GPU_VRAM_MIB="${GPU_LINE##*,}"
GPU_VRAM_MIB="${GPU_VRAM_MIB// /}"
MIN_VRAM_MIB=$((MIN_VRAM_GB * 1024))
VRAM_REPORTING_TOLERANCE_MIB=64
info "GPU detected: $GPU_NAME (${GPU_VRAM_MIB} MiB VRAM)"
((GPU_VRAM_MIB + VRAM_REPORTING_TOLERANCE_MIB >= MIN_VRAM_MIB)) || \
  die "GPU has less than required ${MIN_VRAM_GB} GiB VRAM (allowing ${VRAM_REPORTING_TOLERANCE_MIB} MiB reporting tolerance)"
if [[ -n "$EXPECTED_GPU_NAME" && "$GPU_NAME" != "$EXPECTED_GPU_NAME" ]]; then
  die "GPU mismatch: expected '$EXPECTED_GPU_NAME', got '$GPU_NAME'"
fi

nvidia-smi > "$STATE_DIR/nvidia-smi-preflight.txt"
df -h / /workspace > "$STATE_DIR/disk-preflight.txt" 2>&1 || true
cat "$STATE_DIR/disk-preflight.txt"

missing_packages=()
if [[ $REUSE_EXISTING -eq 0 && $KEEP_ROOT_MODELS -eq 0 ]]; then
  command -v rsync >/dev/null 2>&1 || missing_packages+=(rsync)
fi
command -v jq >/dev/null 2>&1 || missing_packages+=(jq)
if ((${#missing_packages[@]})); then
  info "Installing required packages: ${missing_packages[*]}"
  apt-get update
  apt-get install -y "${missing_packages[@]}"
fi

if ! command -v ollama >/dev/null 2>&1; then
  info "Installing Ollama ..."
  curl -fsSL https://ollama.com/install.sh | sh
else
  info "Ollama already installed: $(ollama --version 2>&1 | head -n 1)"
fi

step "Normalize Ollama state"
stop_ollama
if [[ $CLEAN -eq 1 ]]; then
  info "--clean requested: deleting $STAGING_DIR and $SHARED_DIR"
  rm -rf "$STAGING_DIR" "$SHARED_DIR"
  mkdir -p "$STAGING_DIR" "$SHARED_DIR"
elif [[ $REUSE_EXISTING -eq 1 ]]; then
  [[ -d "$SHARED_DIR" ]] || \
    die "--reuse-existing requested but shared Ollama cache is missing: $SHARED_DIR; run normal bootstrap to populate it"
  [[ -r "$SHARED_DIR" ]] || die "shared Ollama cache is not readable: $SHARED_DIR"
  info "--reuse-existing requested: preserving shared store without modifying model data: $SHARED_DIR"
  info "Local staging store is not used in cache-reuse mode: $STAGING_DIR"
else
  info "Preserving existing shared store: $SHARED_DIR"
  info "Clearing only local staging store: $STAGING_DIR"
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR" "$SHARED_DIR"
fi

if [[ $REUSE_EXISTING -eq 1 ]]; then
  step "Reuse existing workspace model cache without pull or copy"
  info "Skipping staging, ollama pull, and rsync. Exact cached digests will be validated from the workspace-backed server."
else
  if [[ $KEEP_ROOT_MODELS -eq 1 ]]; then
    step "Pull requested model to fast local/root store and keep it there"
  else
    step "Stage requested models on fast local disk and copy them to workspace"
  fi
  for model in "${MODELS[@]}"; do
    safe="${model//[^A-Za-z0-9._-]/_}"
    printf '\n[%s] ---- Model: %s ----\n' "$(ts)" "$model"
    info "Resetting local staging store before this model."
    stop_ollama
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    df -h / | tee "$STATE_DIR/disk-before-${safe}.txt"

    start_ollama "$STAGING_DIR" "staging-${safe}"
    info "Pulling $model to fast local/root disk. Ollama will print download progress below."
    OLLAMA_HOST="$CLIENT_URL" ollama pull "$model"

    digest="$(model_digest "$model")"
    [[ -n "$digest" && "$digest" != "null" ]] || die "could not read digest for $model after pull"
    info "Pulled digest: $digest"
    printf '%s\t%s\n' "$model" "$digest" >> "$STATE_DIR/pulled-model-digests.tsv"

    expected="${EXPECTED_DIGESTS[$model]:-}"
    if [[ -n "$expected" && "$digest" != "$expected" ]]; then
      die "digest mismatch for $model: expected $expected, got $digest"
    fi

    if [[ $KEEP_ROOT_MODELS -eq 1 ]]; then
      info "Keeping completed Ollama store on fast local/root disk: $STAGING_DIR"
      info "Root model store now uses: $(du -sh "$STAGING_DIR" | awk '{print $1}')"
    else
      stop_ollama
      info "Copying completed Ollama store into $SHARED_DIR. rsync progress follows."
      if ! rsync -ah --info=progress2 "$STAGING_DIR/" "$SHARED_DIR/"; then
        die "rsync to $SHARED_DIR failed (a RunPod workspace quota may have been reached)"
      fi
      info "Copy complete. Shared store now uses: $(du -sh "$SHARED_DIR" | awk '{print $1}')"
      info "Removing local staging copy to recover root-disk space."
      rm -rf "$STAGING_DIR"
      mkdir -p "$STAGING_DIR"
    fi
  done
fi

if [[ $KEEP_ROOT_MODELS -eq 1 ]]; then
  FINAL_MODEL_STORE="$STAGING_DIR"
  FINAL_SERVER_LABEL="root"
  MODEL_STORE_MODE="root"
else
  FINAL_MODEL_STORE="$SHARED_DIR"
  FINAL_SERVER_LABEL="workspace"
  MODEL_STORE_MODE="workspace"
fi

step "Start final ${MODEL_STORE_MODE}-backed Ollama server"
start_ollama "$FINAL_MODEL_STORE" "$FINAL_SERVER_LABEL"
curl -fsS "$CLIENT_URL/api/tags" | jq . > "$STATE_DIR/api-tags-final.json"
OLLAMA_HOST="$CLIENT_URL" ollama list | tee "$STATE_DIR/ollama-list-final.txt"

step "Verify requested model digests from the final server"
for model in "${MODELS[@]}"; do
  digest="$(model_digest "$model")"
  [[ -n "$digest" && "$digest" != "null" ]] || die "$model is not visible from final $MODEL_STORE_MODE server"
  expected="${EXPECTED_DIGESTS[$model]:-}"
  info "$model digest: $digest"
  FINAL_DIGESTS["$model"]="$digest"
  if [[ -n "$expected" && "$digest" != "$expected" ]]; then
    die "final digest mismatch for $model: expected $expected, got $digest"
  fi
done

step "Warm each model and verify context plus full GPU residency"
for model in "${MODELS[@]}"; do
  safe="${model//[^A-Za-z0-9._-]/_}"
  info "Preloading $model into VRAM without generating a response."
  OLLAMA_HOST="$CLIENT_URL" ollama run "$model" "" </dev/null \
    2>&1 | tee "$STATE_DIR/warmup-${safe}.log"

  OLLAMA_HOST="$CLIENT_URL" ollama ps | tee "$STATE_DIR/ollama-ps-${safe}.txt"
  curl -fsS "$CLIENT_URL/api/ps" | jq . > "$STATE_DIR/api-ps-${safe}.json"
  nvidia-smi > "$STATE_DIR/nvidia-smi-${safe}.txt"

  ps_json="$(model_ps_json "$model")"
  [[ -n "$ps_json" ]] || die "$model did not appear in /api/ps after warmup"
  actual_context="$(jq -r '.context_length' <<<"$ps_json")"
  size="$(jq -r '.size' <<<"$ps_json")"
  size_vram="$(jq -r '.size_vram' <<<"$ps_json")"
  info "$model context=$actual_context size=$size size_vram=$size_vram"

  [[ "$actual_context" == "$CONTEXT_LENGTH" ]] || \
    die "$model context mismatch: expected $CONTEXT_LENGTH, got $actual_context"
  [[ "$size" == "$size_vram" ]] || \
    die "$model is not fully GPU-resident: size=$size size_vram=$size_vram"

  VERIFIED_CONTEXTS["$model"]="$actual_context"
  VERIFIED_SIZES["$model"]="$size"
  VERIFIED_SIZES_VRAM["$model"]="$size_vram"
  info "$model verification PASS: context=$CONTEXT_LENGTH and 100% model residency in VRAM."
  OLLAMA_HOST="$CLIENT_URL" ollama stop "$model" >/dev/null 2>&1 || true
done

step "Write durable worker evidence"
{
  echo "timestamp_utc=$STAMP"
  echo "gpu=$GPU_NAME"
  echo "gpu_vram_mib=$GPU_VRAM_MIB"
  echo "context_length=$CONTEXT_LENGTH"
  echo "model_store_mode=$MODEL_STORE_MODE"
  echo "final_model_store=$FINAL_MODEL_STORE"
  echo "shared_model_store=$SHARED_DIR"
  echo "server_url=$CLIENT_URL"
  echo "reuse_existing=$REUSE_EXISTING"
  echo "keep_root_models=$KEEP_ROOT_MODELS"
  echo "models=${MODELS[*]}"
} > "$STATE_DIR/worker-summary.txt"

info "Emitting machine-readable model/GPU provenance."
printf '[%s] LME_PROVENANCE_GPU\t%s\t%s\n' "$(ts)" "$GPU_NAME" "$GPU_VRAM_MIB"
for model in "${MODELS[@]}"; do
  printf '[%s] LME_PROVENANCE_MODEL\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ts)" "$model" "${FINAL_DIGESTS[$model]}" \
    "${VERIFIED_CONTEXTS[$model]}" "${VERIFIED_SIZES[$model]}" "${VERIFIED_SIZES_VRAM[$model]}"
done

info "Worker setup PASS."
info "Ollama is serving from $FINAL_MODEL_STORE on $CLIENT_URL."
info "Evidence directory: $STATE_DIR"
info "Server log: $STATE_DIR/ollama-${FINAL_SERVER_LABEL}.log"
info "Leave this pod running; use the Mac tunnel helper to expose it to LME."

FINAL_SERVER_READY=1
trap - EXIT
exit 0
