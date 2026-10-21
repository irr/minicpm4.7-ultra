#!/usr/bin/env bash
# Download, install and serve jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT.
#
# Usage: ./run.sh [all|check|download|install|serve|logs|metrics] [extra args...]
#
# uv is used for the download tooling only. The model runs on the pinned
# ROCm/vLLM runtime bundled with the release (stock vLLM cannot load it).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

HF_REPO=${HF_REPO:-jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT}
REVISION=${REVISION:-main}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-8000}
MODEL_DIR=$(realpath -m -- "${MODEL_DIR:-$SCRIPT_DIR/models/minicpm-ultra}")
RUNTIME_DIR=$(realpath -m -- "${RUNTIME_DIR:-$SCRIPT_DIR/models/runtime}")
# The ~12 GB runtime foundation lives here, owned by you.
FOUNDATION_DIR=$(realpath -m -- "${FOUNDATION_DIR:-$SCRIPT_DIR/ciru/glm53-iu4}")
# The release hardcodes this path, so it becomes a symlink to FOUNDATION_DIR.
# (Override only for testing; upstream install.sh always uses /opt/ciru/glm53-iu4.)
FOUNDATION_LINK=${FOUNDATION_LINK:-/opt/ciru/glm53-iu4}
HF_HUB_SPEC='huggingface_hub>=1.0,<2'
MIN_FREE_GB=87

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

check() {
  log "Checking prerequisites"
  local missing=()
  for cmd in uv python3 tar zstd sudo realpath; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    printf 'Missing commands: %s\n' "${missing[*]}" >&2
    [[ " ${missing[*]} " == *" uv "* ]] &&
      echo "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    cat >&2 <<'EOF'
Ubuntu 24.04 prerequisites:
  sudo apt-get update
  sudo apt-get install -y git python3 python3-venv ca-certificates zstd \
    build-essential pkg-config xxd libgomp1 libnuma1 libdrm2 libelf1 \
    libssl3t64 libstdc++6 zlib1g
EOF
    exit 1
  fi

  [[ -r /dev/kfd && -w /dev/kfd ]] ||
    warn "/dev/kfd is not accessible. Add your user to the 'render' and 'video' groups and log in again."
  compgen -G '/dev/dri/renderD*' >/dev/null ||
    warn "No /dev/dri/renderD* device found. Is the AMD GPU driver loaded?"

  if [[ ! -f "$RUNTIME_DIR/serve.sh" ]]; then
    mkdir -p "$(dirname -- "$MODEL_DIR")"
    local free_gb
    free_gb=$(( $(df -Pk "$(dirname -- "$MODEL_DIR")" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
    ((free_gb >= MIN_FREE_GB)) ||
      warn "Only ${free_gb} GB free near $MODEL_DIR. About ${MIN_FREE_GB} GB is needed."
  fi
  log "Prerequisites OK"
}

download() {
  if [[ -f "$MODEL_DIR/download-receipt.json" ]]; then
    log "Model already downloaded and verified: $MODEL_DIR"
    return
  fi
  log "Downloading $HF_REPO ($REVISION) to $MODEL_DIR (~42 GB, resumable)"
  mkdir -p "$MODEL_DIR"
  # Fetch the upstream downloader first. It pins an immutable commit,
  # downloads the snapshot and verifies the runtime archive checksums.
  uvx --from "$HF_HUB_SPEC" hf download "$HF_REPO" scripts/download.py \
    --revision "$REVISION" --local-dir "$MODEL_DIR" >/dev/null
  uv run --no-project --with "$HF_HUB_SPEC" -- \
    python -I "$MODEL_DIR/scripts/download.py" \
    --destination "$MODEL_DIR" --revision "$REVISION"
}

install() {
  if [[ -f "$RUNTIME_DIR/serve.sh" ]]; then
    log "Runtime already installed: $RUNTIME_DIR"
    return
  fi
  [[ -f "$MODEL_DIR/download-receipt.json" ]] || die "Model not downloaded yet. Run: $0 download"
  [[ ! -e "$RUNTIME_DIR" ]] ||
    die "$RUNTIME_DIR exists but has no serve.sh (a partial install?). Remove it and run again."

  foundation
  log "Installing runtime to $RUNTIME_DIR"
  # The foundation already exists (via the symlink), so install.sh skips its
  # own "sudo tar" and only verifies it. It extracts ~3 GB to TMPDIR, so keep
  # that on disk, not tmpfs.
  local tmp="$SCRIPT_DIR/models/.tmp"
  mkdir -p "$tmp"
  TMPDIR="$tmp" bash "$MODEL_DIR/scripts/install.sh" "$MODEL_DIR" "$RUNTIME_DIR"
  rmdir "$tmp" 2>/dev/null || true
}

# Extract the foundation into the project as your user, then point the
# hardcoded /opt/ciru/glm53-iu4 path at it. sudo is used only for the symlink.
foundation() {
  if [[ ! -f "$FOUNDATION_DIR/runtime-env.sh" ]]; then
    [[ ! -e "$FOUNDATION_DIR" ]] ||
      die "$FOUNDATION_DIR exists but looks incomplete. Remove it and run again."
    local archive="$MODEL_DIR/runtime/ciru-rocm10-gfx1151-foundation.tar.zst"
    [[ -f "$archive" ]] || die "Missing $archive. Run: $0 download"
    log "Extracting runtime foundation to $FOUNDATION_DIR (~12 GB)"
    mkdir -p "$(dirname -- "$FOUNDATION_DIR")"
    local stage
    stage=$(mktemp -d "$(dirname -- "$FOUNDATION_DIR")/.stage.XXXXXXXX")
    tar --zstd --no-same-owner -xf "$archive" -C "$stage"
    mv -T -- "$stage/foundation" "$FOUNDATION_DIR"
    rmdir -- "$stage"
  else
    log "Runtime foundation already extracted: $FOUNDATION_DIR"
  fi

  if [[ -L "$FOUNDATION_LINK" ]]; then
    local target
    target=$(realpath -m -- "$(readlink -- "$FOUNDATION_LINK")")
    if [[ "$target" == "$FOUNDATION_DIR" ]]; then
      log "$FOUNDATION_LINK -> $FOUNDATION_DIR (ok)"
      return
    fi
    warn "$FOUNDATION_LINK points to $target, not $FOUNDATION_DIR. Leaving it as is."
    warn "To use this project's copy: sudo ln -sfnT '$FOUNDATION_DIR' '$FOUNDATION_LINK'"
  elif [[ -e "$FOUNDATION_LINK" ]]; then
    warn "$FOUNDATION_LINK already exists as a real directory. Using it as is."
    warn "The installer will check that it matches this release."
  else
    log "sudo is needed once, only to create the symlink $FOUNDATION_LINK -> $FOUNDATION_DIR"
    sudo mkdir -p -- "$(dirname -- "$FOUNDATION_LINK")"
    sudo ln -sfnT -- "$FOUNDATION_DIR" "$FOUNDATION_LINK"
  fi
}

serve() {
  [[ -f "$RUNTIME_DIR/serve.sh" ]] || die "Runtime not installed yet. Run: $0 install"
  [[ -f "$FOUNDATION_LINK/runtime-env.sh" ]] ||
    die "$FOUNDATION_LINK does not resolve (project moved?). Fix: sudo ln -sfnT '$FOUNDATION_DIR' '$FOUNDATION_LINK'"
  log "Serving on http://$HOST:$PORT/v1 (model id: minicpm-q8)"
  log "The first start compiles kernels. Wait for: curl -f http://localhost:$PORT/health"
  log "Server output goes to a log file. Follow it with: $0 logs"
  exec bash "$RUNTIME_DIR/serve.sh" --host "$HOST" --port "$PORT" "$@"
}

# The upstream launcher writes all server output here, not to the terminal.
# Each restart moves the previous log to prior-launches/<timestamp>/.
LOG_FILE="$RUNTIME_DIR/payload/model/candidate/minicpm/installed-rc/server.log"

logs() {
  [[ -f "$LOG_FILE" ]] || die "No log yet at $LOG_FILE. Start the server first: $0 serve"
  log "Following $LOG_FILE (Ctrl-C to stop)"
  # -F keeps following across restarts; extra args (e.g. -n 500) override the default.
  exec tail -F -n 100 "$@" -- "$LOG_FILE"
}

# Summarize the server's Prometheus /metrics endpoint.
# Usage: ./run.sh metrics [-w SECONDS]   (-w refreshes until Ctrl-C)
metrics() {
  local interval=""
  case "${1:-}" in
    -w|--watch) interval=${2:-5} ;;
    "") ;;
    *) die "Usage: $0 metrics [-w SECONDS]" ;;
  esac
  # 0.0.0.0 is a bind address, not one to connect to.
  local host=$HOST
  [[ "$host" == 0.0.0.0 || "$host" == "::" ]] && host=127.0.0.1
  local url=${METRICS_URL:-http://$host:$PORT/metrics}
  while :; do
    local body
    body=$(curl -fsS --max-time 5 "$url") ||
      die "Could not read $url. Is the server running? ($0 serve)"
    [[ -n "$interval" ]] && clear
    METRICS_BODY=$body metrics_report "$url"
    [[ -n "$interval" ]] || break
    sleep "$interval"
  done
}

metrics_report() {
  python3 -I - "$1" <<'PY'
import math, os, re, sys, time

line_re = re.compile(r"^(vllm:[A-Za-z0-9_:]+)(?:\{(.*)\})? (\S+)$")
m, hist, reasons = {}, {}, {}
for line in os.environ["METRICS_BODY"].splitlines():
    r = line_re.match(line.strip())
    if not r:
        continue
    name, labels, value = r.group(1), r.group(2) or "", float(r.group(3))
    if name.endswith("_created"):
        continue
    if name.endswith("_bucket"):
        le = float(re.search(r'le="([^"]+)"', labels).group(1))
        h = hist.setdefault(name[: -len("_bucket")], {})
        h[le] = h.get(le, 0) + value
        continue
    if name == "vllm:request_success_total":
        fr = re.search(r'finished_reason="([^"]+)"', labels)
        reasons[fr.group(1) if fr else "?"] = value
    m[name] = m.get(name, 0) + value

def g(n):
    return m.get("vllm:" + n, 0.0)

def avg(n):
    c = g(n + "_count")
    return g(n + "_sum") / c if c else None

def pct(a, b):
    return 100 * a / b if b else None

def quantile(n, q):
    h, total = hist.get("vllm:" + n), g(n + "_count")
    if not h or not total:
        return None
    return next((le for le in sorted(h) if h[le] >= q * total), None)

def secs(v):
    if v is None:
        return "-"
    if math.isinf(v):
        return "> max bucket"
    return f"{v * 1000:.0f} ms" if v < 1 else f"{v:.2f} s"

def num(v, fmt="{:,.0f}"):
    return "-" if v is None else fmt.format(v)

def lat(n):
    return " | ".join(secs(x) for x in (avg(n), quantile(n, 0.5), quantile(n, 0.95)))

tpot = avg("request_time_per_output_token_seconds")
drafts = g("spec_decode_num_drafts_total")
drafted = g("spec_decode_num_draft_tokens_total")
accepted = g("spec_decode_num_accepted_tokens_total")
done = sum(reasons.values())
ended = ", ".join(f"{k} {v:.0f}" for k, v in sorted(reasons.items()) if v)

rows = [
    ("Load", None),
    ("Requests running / waiting", f"{g('num_requests_running'):.0f} / {g('num_requests_waiting'):.0f}  (8 slots)"),
    ("KV cache usage", f"{g('kv_cache_usage_perc') * 100:.1f}%"),
    ("Preemptions", num(g("num_preemptions_total"))),
    ("Totals since start", None),
    ("Requests finished", num(done) + (f"  ({ended})" if ended else "")),
    ("Prompt / generated tokens", f"{g('prompt_tokens_total'):,.0f} / {g('generation_tokens_total'):,.0f}"),
    ("Avg prompt / output length", f"{num(avg('request_prompt_tokens'))} / {num(avg('request_generation_tokens'))} tokens"),
    ("Latency (avg | p50 | p95)", None),
    ("Time to first token", lat("time_to_first_token_seconds")),
    ("Time per output token", lat("request_time_per_output_token_seconds")),
    ("End-to-end request", lat("e2e_request_latency_seconds")),
    ("Generation speed (avg/request)", num(1 / tpot if tpot else None, "{:.1f} tokens/s")),
    ("Caches", None),
    ("Prefix cache hit rate", num(pct(g("prefix_cache_hits_total"), g("prefix_cache_queries_total")), "{:.1f}%")),
    ("Image cache hit rate", num(pct(g("mm_cache_hits_total"), g("mm_cache_queries_total")), "{:.1f}%")),
    ("Speculative decoding", None),
    ("Draft tokens accepted", num(pct(accepted, drafted), "{:.1f}%")),
    ("Tokens per decode step", num(1 + accepted / drafts if drafts else None, "{:.2f}")),
]
print(f"MiniCPM metrics  {sys.argv[1]}  {time.strftime('%H:%M:%S')}")
print("p50/p95 are histogram bucket upper bounds.")
for k, v in rows:
    print(f"\n{k}" if v is None else f"  {k:<32}{v}")
PY
}

cmd=${1:-all}
[[ $# -gt 0 ]] && shift
case "$cmd" in
  all)      check; download; install; serve "$@" ;;
  check)    check ;;
  download) check; download ;;
  install)  check; install ;;
  serve)    serve "$@" ;;
  logs)     logs "$@" ;;
  metrics)  metrics "$@" ;;
  -h|--help|help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "Unknown command: $cmd (use all|check|download|install|serve|logs|metrics)" ;;
esac
