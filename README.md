# ink (Windows): Inkling 2 Mini on an RTX 3090, in one command

Windows port of [ox1138/inkling-mac](https://github.com/ox1138/inkling-mac). Same commands, same Pi
extensions, but the model runs in llama.cpp on CUDA instead of MLX. Open a folder, type `ink`. The model
loads on first use (about 7 s) and unloads when you close the last session.

## What's here

| Path | What |
|---|---|
| `bin/ink.ps1` | The command. Starts `llama-server` on `127.0.0.1:8080` when needed (detached, owned by a hidden watchdog), tracks sessions, and unloads when none are left, including when you just close the terminal window. |
| `config/ext/web.ts`, `confirm.ts` | Pi extensions from the Mac repo. `confirm.ts` compares paths case-insensitively on Windows. Pi runs commands through Git Bash here, so the bash command parser works as is. |
| `config/pi/` | Pi model definition: 64K context, 8K max output, Unsloth's sampling (temp 1.0, top-p 1.0, top-k 0, min-p 0) |
| `config/opencode.json` | opencode config for `ink oc` |
| `install.ps1` | Reproduces the whole setup. Safe to re-run. |
| `smoke_test.py` | One chat answer plus an OpenAI tool-call round trip (`python smoke_test.py` while the server is up) |
| `scripts/bench.py`, `bench_spec.py` | Benchmarks for context, KV-cache type and the DSpark drafter |
| `llama.cpp/`, `models/`, `tools/` | Unsloth llama.cpp build, GGUFs, local Pi/opencode (not in git) |

Only `%USERPROFILE%\.local\bin\ink.cmd` and `ink` (for Git Bash) live outside this folder. State and logs
go to `%LOCALAPPDATA%\inkling`.

## Server

```
llama-server -m Inkling-2-Mini-UD-Q4_K_XL.gguf --jinja -ngl 99 -fa on -lm none
  -c 65536 -ctk q8_0 -ctv q8_0 -np 1
  -md dspark-Inkling-2-Mini-Q8_0.gguf --spec-type draft-dspark --spec-draft-n-max 2 -ngld 99
  --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0 --alias inkling-2-mini
```

- llama.cpp is [Unsloth's b12631-mix-acc0843](https://github.com/unslothai/llama.cpp/releases/tag/b12631-mix-acc0843)
  `windows-x64-cuda13-portable`. Despite the name, that zip doesn't include cuBLAS and silently falls back to
  CPU, so `install.ps1` adds `cublas64_13.dll` and `cublasLt64_13.dll` from upstream llama.cpp's NVIDIA
  redistributable bundle. No CUDA toolkit is needed.
- `-lm none` replaces `--no-mmap` in this build. The weights live on the GPU, so the file isn't kept mapped in RAM.
- Text only (no `--mmproj`).

## Measured (RTX 3090, driver 610.88, Windows 11; desktop already uses 3.4 GB VRAM)

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
- `INKLING_CTX=131072`: more context (VRAM fits it; also raise `contextWindow` in `config/pi/models.json`)
- `INKLING_DRAFT=0`: no DSpark drafter (saves about 0.9 GB VRAM)
- `INKLING_PORT`, `INKLING_HOST`: where the server listens (default `127.0.0.1:8080`)

## Good to know

- **VRAM headroom.** With the default config the card sits at about 22.4 of 24 GB. A game or another GPU app can
  push it over, and on Windows the driver then spills into system RAM and everything slows down. Run `ink stop`
  before gaming, or set `INKLING_DRAFT=0` / `INKLING_CTX=32768`.
- **The model can act on its own.** Pi doesn't sandbox commands. The confirm prompt is a guard, not a sandbox: use `ink` in folders under git.
- **It can loop when debugging.** The 8K output cap limits that. `INKLING_THINK=low` helps too.
- **Pi `-p` mode waits on piped stdin.** `ink ask` handles this. If you script Pi yourself, add `< NUL`.
