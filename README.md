# MiniCPM 4.7 Ultra (CIRU HALO AGENT): local server

This repo downloads, installs and serves
[`jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT`](https://huggingface.co/jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT)
as an OpenAI-compatible API on **`0.0.0.0:8000`**, all with one script.

About the model:

- Based on `openbmb/MiniCPM-V-4.7-35B-A3B`: a MoE model with 35B total and ~3B active parameters.
- Routed experts are packed to 8-bit (Ciru Q8).
- Supports vision input and native tool calling.
- Uses speculative decoding with the DSpark drafter.
- Context window is 262,144 tokens.
- Built and tuned for **AMD Strix Halo**: Ryzen AI Max+ 395 / Radeon 8060S (`gfx1151`) with 128 GB unified memory.

## Requirements

- AMD Strix Halo (`gfx1151`) with 128 GB unified memory, and a working AMD GPU driver.
- Your user can access `/dev/kfd` and `/dev/dri/renderD*`. Add yourself to the groups with `sudo usermod -aG render,video $USER`, then log out and back in.
- About **87 GB** of free disk space in this folder: ~75 GB under `./models` and ~12 GB under `./ciru`.
- `sudo` access, needed **once**, only to create one symlink at `/opt/ciru/glm53-iu4`. No files are written as root (see [Why `/opt/ciru`?](#why-optciru)).
- [uv](https://docs.astral.sh/uv/). To install it:
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- Ubuntu 24.04 packages:
  ```bash
  sudo apt-get update
  sudo apt-get install -y git python3 python3-venv ca-certificates zstd \
    build-essential pkg-config xxd libgomp1 libnuma1 libdrm2 libelf1 \
    libssl3t64 libstdc++6 zlib1g
  ```

## Quick start

```bash
chmod +x run.sh
./run.sh
```

The first run takes these steps:

1. **check**: verifies the tools, GPU device access and free disk space.
2. **download**: fetches the release (~42 GB, resumable) into `models/minicpm-ultra`, pinned to an immutable commit. It verifies the runtime archive checksums.
3. **install** has three parts:
   - Extracts the ~12 GB runtime foundation (Python 3.14, ROCm, torch, vLLM) into `./ciru/glm53-iu4` as your user.
   - Asks for `sudo` once to create the symlink `/opt/ciru/glm53-iu4 → ./ciru/glm53-iu4`.
   - Verifies every weight file and installs the model runtime into `models/runtime`.
4. **serve**: starts the server on `http://0.0.0.0:8000`.

Steps that are already done get skipped, so later runs of `./run.sh` go straight to serving. The first server start also compiles GPU kernels and can take a while. The compiled kernels are cached for later starts.

### Commands

| Command | What it does |
|---|---|
| `./run.sh` / `./run.sh all` | check → download → install → serve |
| `./run.sh check` | Check prerequisites only |
| `./run.sh download` | Download and verify the model |
| `./run.sh install` | Install the runtime (needs the download) |
| `./run.sh serve [args...]` | Start the server; extra args are passed to the upstream `serve.sh` |
| `./run.sh logs [tail args...]` | Follow the server log (last 100 lines, then live). E.g. `./run.sh logs -n 500` |
| `./run.sh metrics [-w SECONDS]` | Print a summary of server metrics; `-w 5` refreshes every 5 s |

### Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Port |
| `MODEL_DIR` | `./models/minicpm-ultra` | Download location (keep it: the server reads `weights/` from here) |
| `RUNTIME_DIR` | `./models/runtime` | Installed model runtime location |
| `FOUNDATION_DIR` | `./ciru/glm53-iu4` | Runtime foundation location (target of the `/opt/ciru` symlink) |
| `REVISION` | `main` | Hugging Face revision to download |
| `HF_TOKEN` | – | Optional Hugging Face token (raises download rate limits) |

For example, to serve on localhost only:

```bash
HOST=127.0.0.1 PORT=8095 ./run.sh serve
```

### Why uv is only used for downloading

The weights use a custom packed Q8 format. They load **only** in the Ciru vLLM runtime bundled with the release, which pins Python 3.14, ROCm 10, torch 2.13, Triton and AITER. Stock vLLM, `transformers`, llama.cpp and Ollama cannot load them.

Upstream says not to `pip install vllm` or upgrade torch in that environment. So `run.sh` uses `uv` (`uvx` / `uv run --with huggingface_hub`) only for the download tooling, with no pip and no venv to manage. Serving uses the pinned runtime as shipped.

### Why `/opt/ciru`?

The release's runtime foundation is pinned to the absolute path `/opt/ciru/glm53-iu4`, and it can't be moved:

- The model launcher (`runtime-env.sh`) runs `source /opt/ciru/glm53-iu4/runtime-env.sh` and points vLLM and AITER at that path.
- The release pins foundation files (Python, `libtorch_hip.so`, Triton, AITER) by **absolute path + SHA-256**. The installer checks them, and so does the server on every start.
- The bundled Python venv was built at that prefix. The upstream installer relocates the model runtime, but not the foundation.

Rewriting those paths would mean editing pinned files and their hashes, which breaks the release's integrity checks.

Avoiding sudo entirely would need an unprivileged mount namespace (`unshare` / `bwrap`) to make `./ciru` appear at `/opt/ciru`. Ubuntu 24.04 blocks those by default (`kernel.apparmor_restrict_unprivileged_userns=1`).

So `run.sh` keeps all the files in `./ciru`, owned by you, and only uses `sudo` for:

```bash
sudo mkdir -p /opt/ciru
sudo ln -sfnT "$PWD/ciru/glm53-iu4" /opt/ciru/glm53-iu4
```

If `/opt/ciru/glm53-iu4` already exists (a symlink elsewhere or a real directory), `run.sh` leaves it alone and warns you. The installer then checks whether it matches this release.

## Using the API

Check that the server is up:

```bash
curl -f http://localhost:8000/health
curl http://localhost:8000/v1/models
```

The model id is **`minicpm-q8`**. Recommended sampling: `temperature 0.6`, `top_p 0.95`, `top_k 20`. Thinking mode is set per request with `chat_template_kwargs.enable_thinking`.

```bash
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "minicpm-q8",
    "messages": [{"role": "user", "content": "Write a Python function that merges overlapping intervals."}],
    "temperature": 0.6,
    "top_p": 0.95,
    "top_k": 20,
    "chat_template_kwargs": {"enable_thinking": false},
    "stream": true
  }'
```

Python, with the OpenAI client:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="none")
resp = client.chat.completions.create(
    model="minicpm-q8",
    messages=[{"role": "user", "content": "Hello!"}],
    temperature=0.6,
    top_p=0.95,
    extra_body={"top_k": 20, "chat_template_kwargs": {"enable_thinking": True}},
)
print(resp.choices[0].message.content)
```

Image and tool-calling examples are in the upstream docs at [`docs/API.md`](https://huggingface.co/jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT/blob/main/docs/API.md). After download, the same file is at `models/minicpm-ultra/docs/API.md`.

## Monitoring

### Metrics

```bash
./run.sh metrics        # one-off summary
./run.sh metrics -w 5   # refresh every 5 seconds
```

It reads the server's Prometheus endpoint (`http://localhost:8000/metrics`) and shows:
- load: running/waiting requests out of 8 slots, KV-cache usage, preemptions
- totals: requests finished and how they ended, tokens in/out
- latency: average, p50 and p95 for time to first token, time per output token, and end-to-end
- prefix/image cache hit rates
- speculative-decoding acceptance

The figures are totals since the server started. The p50/p95 values are histogram bucket upper bounds, so they're approximate.

For dashboards, point Prometheus at `http://<host>:8000/metrics`. vLLM's [example Grafana dashboard](https://github.com/vllm-project/vllm/tree/main/examples/online_serving/prometheus_grafana) works with it.

GPU-level stats come from the AMD tools: `amd-smi monitor`, `radeontop`, or `cat /sys/class/drm/card*/device/gpu_busy_percent`. Memory is shared on Strix Halo, so `free -g` is also useful.

### Logs

Run `./run.sh logs` (see the notes below for where the log file lives).

## Notes

- **Security:** binding to `0.0.0.0` exposes an **unauthenticated** API to your network. Firewall port 8000 (e.g. `sudo ufw allow from 192.168.1.0/24 to any port 8000`), or use `HOST=127.0.0.1`.
- **Limits:** the default profile has 8 request slots sharing a 24 GiB KV-cache budget. Eight requests at full 262k context each will not fit at the same time.
- **Ubuntu:** upstream validated end-to-end GPU serving on NixOS. On Ubuntu 24.04 only the userspace install checks were validated.
- **Logs:** the server writes all output to `models/runtime/payload/model/candidate/minicpm/installed-rc/server.log`, not the terminal. Use `./run.sh logs` to follow it, or `grep -E 'ERROR|Traceback'` on the file to find problems.
  - Each restart moves the old log to `prior-launches/<timestamp>/` in the same folder.
  - `command.json` there has the exact vLLM command, and `exit.json` has the exit code.
  - `Triton kernel JIT compilation during inference` warnings are normal at first. The compiled kernels are cached.
- **Stopping:** press Ctrl-C. The launcher stops only its own server process group.
- **Reinstalling the runtime:** run `rm -rf models/runtime && ./run.sh install`. The installer never overwrites an existing directory. To re-extract the foundation, also remove `ciru/glm53-iu4`.
- **Moving this folder** breaks the `/opt/ciru/glm53-iu4` symlink. `./run.sh serve` will tell you. Fix it with `sudo ln -sfnT "$PWD/ciru/glm53-iu4" /opt/ciru/glm53-iu4`.
- **Uninstalling:** run `sudo rm /opt/ciru/glm53-iu4 && sudo rmdir /opt/ciru`, then `rm -rf ciru models`.
- **Re-downloading:** delete `models/minicpm-ultra/download-receipt.json` (or the whole directory) and run `./run.sh download`.
- **Disk usage:** `models/minicpm-ultra/weights` must stay, because the server reads it directly. You can delete `models/minicpm-ultra/runtime/*.tar.zst` after install to free ~3.5 GB. A later reinstall then needs those archives again: delete `download-receipt.json` and run `./run.sh download`, which re-fetches only the missing files.

## Links

- Model: <https://huggingface.co/jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT>
- Upstream install guide: [`docs/INSTALL.md`](https://huggingface.co/jcbtc/MiniCPM-4.7-Ultra-CIRU-HALO-AGENT/blob/main/docs/INSTALL.md)
- Base model: <https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B>
