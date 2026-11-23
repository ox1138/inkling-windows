"""Simulate smaller GPUs on a big one and measure each quant / offload strategy.

A card of SIZE GB is simulated by giving llama.cpp's --fit a margin that leaves only
(SIZE - 1 GB desktop) of VRAM usable, with the default 1 GB fit margin on top.
CPU, RAM and PCIe are this PC's, so offload numbers depend on them.

  python scripts/bench_lowvram.py 16:Q4_K_XL:fit 12:Q2_K_XL:fit ...
  spec = SIZE_GB:QUANT:MODE   MODE = fit | cache (fit + --moe-cache-mib auto) | cpu (no GPU)
"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import bench

DESKTOP_MIB = 1024   # what a typical desktop uses on a dedicated card


def gguf(q):
    return os.path.join(bench.ROOT, "models", f"Inkling-2-Mini-UD-{q}.gguf")


def proc_mem_gb(pid):
    out = subprocess.check_output(["powershell", "-NoProfile", "-c",
                                   f"(Get-Process -Id {pid}).PrivateMemorySize64"]).decode().strip()
    return round(int(out) / 2**30, 1)


def fit_summary(log):
    keep = []
    for line in open(log, encoding="utf-8", errors="replace"):
        l = line.lower()
        if any(k in l for k in ("n_cpu_moe", "fit:", "llama_params_fit", "moe cache", "offloaded", "cpu_moe")):
            keep.append(line.strip()[-150:])
    return keep[-4:]


def run(spec):
    size, quant, mode = spec.split(":")
    free = 24576 - bench.vram_used_mib()
    usable = int(float(size) * 1024) - DESKTOP_MIB
    args = ["-m", gguf(quant), "--jinja", "-fa", "on", "-lm", "none", "-c", "32768", "-ctk", "q8_0", "-ctv", "q8_0",
            "-np", "1", "--temp", "1.0", "--top-p", "1.0", "--top-k", "0", "--min-p", "0.0",
            "--host", "127.0.0.1", "--port", str(bench.PORT)]
    if mode == "cpu":
        args += ["-ngl", "0", "--fit", "off"]
    else:
        args += ["--fit", "on", "--fit-target", str(free - usable + 1024)]
        if mode == "cache":
            args += ["--moe-cache-mib", "auto"]
    log = os.path.join(bench.ROOT, "scripts", f"lowvram-{size}-{quant}-{mode}.log")
    base = bench.vram_used_mib()
    p = subprocess.Popen([bench.EXE, *args], stdout=open(log, "w"), stderr=subprocess.STDOUT)
    try:
        load = bench.wait_ready(p, 600)
        if not load:
            print(f"{spec}: FAILED to start, see {log}", flush=True); return
        time.sleep(2)
        vram = bench.vram_used_mib() - base
        bench.post("/v1/chat/completions", {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8})
        pps = [bench.pp(n) for n in (2000, 8000)]
        tgs = [bench.tg() for _ in range(2)]
        print(f"{spec}: load {load:.0f}s | VRAM {vram/1024:.1f} GB (budget {usable/1024:.1f}) | "
              f"RAM {proc_mem_gb(p.pid)} GB | pp " + " / ".join(f"{n}:{s:.0f}" for n, s in pps) +
              " tok/s | tg " + " / ".join(f"{t[1]:.1f}" for t in tgs) + " tok/s", flush=True)
        for l in fit_summary(log):
            print("    ", l)
    finally:
        p.terminate(); p.wait(30); time.sleep(3)


for s in sys.argv[1:]:
    run(s)
