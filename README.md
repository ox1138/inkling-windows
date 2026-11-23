# ink (Windows): Inkling 2 Mini as a local coding agent, in one command

Windows port of [ox1138/inkling-mac](https://github.com/ox1138/inkling-mac). Same commands, same Pi
extensions, but the model runs in llama.cpp on an NVIDIA GPU instead of MLX. Open a folder, type `ink`. The model
loads on first use (7–25 s) and unloads when you close the last session.

## Quick start

You need:
- An NVIDIA GPU with 8 GB or more and a recent driver (see [Weaker PCs](#weaker-pcs) for what each size gets you)
- [Node.js](https://nodejs.org) 22.19 or newer and [Git for Windows](https://git-scm.com)
- 10–20 GB of free disk space, depending on the model size the installer picks

```powershell
git clone https://github.com/ox1138/inkling-windows
cd inkling-windows
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer reads your GPU, VRAM and RAM and picks the model size and settings for you. Everything goes
inside this folder; only two small `ink` shims go in `%USERPROFILE%\.local\bin` (added to your PATH).
Open a new terminal afterwards, then in any project folder:

```
ink          # coding agent (Pi) in this folder
ink chat     # chat with web search
ink status   # is the model loaded, and with which settings
ink stop     # unload now
```

## Weaker PCs

Inkling 2 Mini is a mixture-of-experts model. When it doesn't fit in VRAM, llama.cpp keeps the parts it uses
most on the GPU and the rest in system RAM, so it still runs, just slower. Smaller GGUF files (Q3, Q2) fit on
smaller cards, and they lose some quality on hard problems.

What the installer picks:

| GPU VRAM | RAM | Picks | Generation | Prompt processing (2K / 8K) |
|---|---|---|---|---|
| 24 GB | 32 GB+ | UD-Q4_K_XL, all on GPU, 64K context, DSpark drafter | **60 tok/s** | 1,300 / 1,340 tok/s |
| 16 GB | 24 GB+ | UD-Q3_K_XL (13.6 GB), all on GPU | **54 tok/s** | 1,220 / 1,360 tok/s |
| 12 GB | 32 GB+ | UD-Q4_K_XL, overflow to RAM | **29 tok/s** | 690 / 790 tok/s |
| 8 GB (or 12 GB with 16 GB RAM) | 16 GB+ | UD-Q2_K_XL (9.1 GB) | **41 tok/s** on 8 GB, 57 on 12 GB | 1,060 / 1,180 tok/s |
| none | 32 GB+ | UD-Q4_K_XL on CPU | 3.5 tok/s (chat only) | 160 / 220 tok/s |

Other combinations I measured, if you want to choose yourself:

| Card | Option | Generation | Prompt (2K / 8K) |
|---|---|---|---|
| 16 GB | Q4_K_XL, overflow to RAM (better quality than Q3) | 40 tok/s | 1,030 / 1,160 tok/s |
| 12 GB | Q2_K_XL, all on GPU (faster, lower quality) | 57 tok/s | 1,340 / 1,420 tok/s |
| 8 GB | Q4_K_XL, overflow to RAM | 11 tok/s | 340 / 400 tok/s |

To override the pick, re-run the installer with your choice, for example:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Quant Q4_K_XL -Gpu fit
```

`-Quant` takes any Unsloth UD quant (Q4_K_XL, Q4_K_M, IQ4_XS, Q3_K_XL, IQ3_XXS, Q2_K_XL, IQ2_XXS). `-Gpu` is
`full` (everything on the GPU), `fit` (llama.cpp fills the free VRAM and keeps the rest in RAM) or `cpu`. `-Ctx`
sets the context length (default 32K, or 64K on 24 GB cards).

How these were measured: on one RTX 3090 PC, with smaller cards simulated by limiting how much VRAM llama.cpp may
use (1 GB left for the desktop, 32K context, q8_0 KV cache). CPU, RAM and PCIe speed are this PC's (an Intel
i9-10900X with 64 GB of DDR4-2400, on the slow side for RAM), so the "overflow to RAM" and CPU rows depend most on your own hardware. A real
12 GB card is also slower than a 3090, so expect somewhat less than the table on cards like the RTX 3060.

Things to know on smaller setups:
- **RAM matters too.** llama-server keeps a copy of the weights in RAM: about 21 GB for Q4, 17 GB for Q3, 13 GB
  for Q2. With 16 GB of RAM, close your browser before starting `ink`.
- **Close GPU-heavy apps.** Games, video editors and many browser tabs take VRAM. If loading fails with out of
  memory, run `$env:INKLING_GPU="fit"` or `$env:INKLING_CTX=16384` and try again.
- **CUDA 12 vs 13.** The installer uses the CUDA 13 build on drivers that support it and the CUDA 12 build on
  older ones. If it says your driver is too old, update it from nvidia.com.
- **AMD and Intel GPUs** get the Vulkan build. That path is untested.

## What's here

| Path | What |
|---|---|
| `bin/ink.ps1` | The command. Starts `llama-server` on `127.0.0.1:8080` when needed (detached, owned by a hidden watchdog), tracks sessions, and unloads when none are left, including when you just close the terminal window. |
| `install.ps1` | Detects the hardware, downloads llama.cpp, the model, Pi and the extensions. Safe to re-run. Writes `ink.config.json` with this PC's settings. |
| `config/ext/web.ts`, `confirm.ts` | Pi extensions from the Mac repo. `confirm.ts` compares paths case-insensitively on Windows. Pi runs commands through Git Bash here, so the bash command parser works as is. |
| `config/pi/` | Pi model definition: 8K max output, Unsloth's sampling (temp 1.0, top-p 1.0, top-k 0, min-p 0). Context is set from `ink.config.json`. |
| `config/opencode.json` | opencode config for `ink oc` (install with `-WithOpencode`) |
| `smoke_test.py` | One chat answer plus an OpenAI tool-call round trip (`python smoke_test.py` while the server is up) |
| `scripts/` | Benchmarks: context and KV cache (`bench.py`), the DSpark drafter (`bench_spec.py`), simulated smaller GPUs (`bench_lowvram.py`) |
| `llama.cpp/`, `models/`, `tools/` | Unsloth llama.cpp build, GGUFs, local Pi/opencode (not in git) |

State and logs go to `%LOCALAPPDATA%\inkling`.

## Server

What `ink` runs on a 24 GB card:

```
llama-server -m Inkling-2-Mini-UD-Q4_K_XL.gguf --jinja -ngl 99 -fa on -lm none
  -c 65536 -ctk q8_0 -ctv q8_0 -np 1
  -md dspark-Inkling-2-Mini-Q8_0.gguf --spec-type draft-dspark --spec-draft-n-max 2 -ngld 99
  --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0 --alias inkling-2-mini
```

On smaller cards `-ngl 99` becomes `--fit on` and the drafter is off.

- llama.cpp is [Unsloth's b12631-mix-acc0843](https://github.com/unslothai/llama.cpp/releases/tag/b12631-mix-acc0843)
  build (it has the looped-layer and per-expert NVFP4 support this model needs). Its "portable" CUDA zips don't
  include cuBLAS and silently fall back to CPU, so `install.ps1` adds the CUDA runtime DLLs from upstream
  llama.cpp's NVIDIA redistributable bundle. No CUDA toolkit is needed.
- `-lm none` replaces `--no-mmap` in this build.
- Text only (no `--mmproj`).

## Measured on a 24 GB card (RTX 3090, driver 610.88, Windows 11; desktop already uses 3.4 GB VRAM)

| Config | Model VRAM | Prompt processing (2K / 8K / 30K tokens) | Generation |
|---|---|---|---|
| 32K, f16 KV | 18.1 GB | 1,284 / 1,383 / 1,399 tok/s | 54.4 tok/s |
| 32K, q8_0 KV | 17.5 GB | 1,317 / 1,390 / 1,355 tok/s | 52.1 tok/s |
| 64K, f16 KV | 19.2 GB | 1,264 / 1,419 / 1,434 tok/s | 54.0 tok/s |
| **64K, q8_0 KV** | 18.1 GB | 1,367 / 1,431 / 1,385 tok/s | 52.5 tok/s |
| 128K, q8_0 KV | 19.3 GB | 1,288 / 1,410 / 1,382 tok/s | 52.7 tok/s |
| **64K, q8_0 + DSpark n=2** (default) | 19.0 GB | 1,301 / 1,342 / 1,309 tok/s | **59.7–60.2 tok/s** (vs 52.6–54.6 without; 54–58% of drafts accepted) |

The KV cache is small for this model: 128K costs only 1.2 GB more than 32K. DSpark depth 3 was slower
(56.0 tok/s). Load time is 6–7 s. Agent task (fix two bugs and run tests): Pi 10–11 s, opencode 24–44 s.
opencode's first step is 15.2K prompt tokens (12 s to process); Pi's is 2.1K, and later steps hit the prompt cache.

## Settings (environment variables)

- `INKLING_THINK=off|minimal|low|medium|high`: thinking effort (default `medium`; chat uses `low`)
- `INKLING_CONFIRM=0`: no "run this command?" prompts
- `INKLING_KEEP=1`: keep the model loaded after the session ends (`ink stop` to unload)
- `INKLING_CTX=131072`: context length for this session (overrides `ink.config.json`)
- `INKLING_GPU=full|fit|cpu`, `INKLING_QUANT=Q3_K_XL`: override the installed settings (the quant must be downloaded)
- `INKLING_DRAFT=0`: no DSpark drafter (saves about 0.9 GB VRAM)
- `INKLING_PORT`, `INKLING_HOST`: where the server listens (default `127.0.0.1:8080`)

## Good to know

- **VRAM headroom.** On a 24 GB card the default config uses about 22.4 GB. A game or another GPU app can
  push it over, and on Windows the driver then spills into system RAM and everything slows down. Run `ink stop`
  before gaming, or set `INKLING_DRAFT=0` / `INKLING_CTX=32768`.
- **The model can act on its own.** Pi doesn't sandbox commands. The confirm prompt is a guard, not a sandbox: use `ink` in folders under git.
- **It can loop when debugging.** The 8K output cap limits that. `INKLING_THINK=low` helps too.
- **MCP servers.** `ink` gives Pi its own config folder, so Pi doesn't see servers set up for Claude Code or a
  normal Pi install. Add them to `%LOCALAPPDATA%\inkling\pi\mcp.json` (same `mcpServers` format as Claude Code) and
  check them with `/mcp` inside `ink`. `ink chat` runs without MCP.
- **Pi `-p` mode waits on piped stdin.** `ink ask` handles this. If you script Pi yourself, add `< NUL`.
