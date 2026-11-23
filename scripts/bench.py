"""Benchmark llama-server configs for Inkling 2 Mini on this PC.

Starts llama-server with each config, records VRAM after load, then measures
prompt processing (pp) and generation (tg) from the server's own `timings`.

  python scripts/bench.py                 # all configs
  python scripts/bench.py q8-32k dspark   # just these
"""
import json, os, random, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "llama.cpp", "llama-server.exe")
MODEL = os.path.join(ROOT, "models", "Inkling-2-Mini-UD-Q4_K_XL.gguf")
DRAFT = os.path.join(ROOT, "models", "dspark-Inkling-2-Mini-Q8_0.gguf")
PORT = 8091
BASE = f"http://127.0.0.1:{PORT}"
COMMON = ["-m", MODEL, "--jinja", "-ngl", "99", "-fa", "on", "-lm", "none", "--fit", "off",
          "--temp", "1.0", "--top-p", "1.0", "--top-k", "0", "--min-p", "0.0",
          "--host", "127.0.0.1", "--port", str(PORT), "-np", "1"]
SPEC = ["-md", DRAFT, "--spec-type", "draft-dspark", "-ngld", "99"]

CONFIGS = {
    "f16-32k":  ["-c", "32768"],
    "q8-32k":   ["-c", "32768", "-ctk", "q8_0", "-ctv", "q8_0"],
    "f16-64k":  ["-c", "65536"],
    "q8-64k":   ["-c", "65536", "-ctk", "q8_0", "-ctv", "q8_0"],
    "q8-128k":  ["-c", "131072", "-ctk", "q8_0", "-ctv", "q8_0"],
    "dspark2":  ["-c", "65536", "-ctk", "q8_0", "-ctv", "q8_0", *SPEC, "--spec-draft-n-max", "2"],
    "dspark3":  ["-c", "65536", "-ctk", "q8_0", "-ctv", "q8_0", *SPEC, "--spec-draft-n-max", "3"],
    "dspark5":  ["-c", "65536", "-ctk", "q8_0", "-ctv", "q8_0", *SPEC, "--spec-draft-n-max", "5"],
}


def vram_used_mib():
    out = subprocess.check_output(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"])
    return int(out.decode().strip().splitlines()[0])


def post(path, body, timeout=900):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def wait_ready(proc, secs=300):
    t = time.time()
    while time.time() - t < secs:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(BASE + "/health", timeout=2) as r:
                if r.status == 200:
                    return time.time() - t
        except Exception:
            pass
        time.sleep(0.5)
    return False


WORDS = ("def class return import self value index buffer parse token stream config server request "
         "response error handler cache layer expert router window session model prompt").split()


def filler(n_tokens, seed):
    rnd = random.Random(seed)
    lines = [f"# {seed}-{i}: " + " ".join(rnd.choice(WORDS) for _ in range(12)) for i in range(n_tokens // 10)]
    text = "\n".join(lines)
    count = len(post("/tokenize", {"content": text})["tokens"])
    keep = max(1, int(len(lines) * n_tokens / count))  # scale to the real token count
    return "\n".join(lines[:keep])


def pp(n):
    text = filler(n, random.randint(0, 10**9))
    r = post("/v1/chat/completions", {
        "messages": [{"role": "user", "content": text + "\n\nReply with OK."}],
        "max_tokens": 1, "cache_prompt": False, "reasoning_effort": "none"})
    t = r["timings"]
    return t["prompt_n"], t["prompt_per_second"]


def tg():
    r = post("/v1/chat/completions", {
        "messages": [{"role": "user", "content":
                      "Write a Python module implementing an LRU cache with TTL, with docstrings and tests."}],
        "max_tokens": 512, "ignore_eos": True, "cache_prompt": False, "reasoning_effort": "low"})
    t = r["timings"]
    acc = ""
    if "draft_n" in t and t.get("draft_n"):
        acc = f" draft acc {t['draft_n_accepted']}/{t['draft_n']}"
    return t["predicted_n"], t["predicted_per_second"], acc


def run(name):
    base = vram_used_mib()
    cmd = [EXE, *COMMON, *CONFIGS[name]]
    log = open(os.path.join(ROOT, "scripts", f"bench-{name}.log"), "w")
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    try:
        load = wait_ready(proc)
        if not load:
            print(f"{name}: FAILED to start (see scripts/bench-{name}.log)")
            return
        time.sleep(2)
        loaded = vram_used_mib()
        post("/v1/chat/completions", {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8})  # warmup
        res = {"load_s": round(load, 1), "vram_mib": loaded - base, "vram_total_mib": loaded}
        for n in (2000, 8000, 30000):
            pn, ps = pp(n)
            res[f"pp{pn}"] = round(ps)
        peak = vram_used_mib()
        res["vram_after_30k_mib"] = peak - base
        tgs = [tg() for _ in range(3)]
        res["tg_tok_s"] = [round(x[1], 1) for x in tgs]
        res["tg_note"] = tgs[-1][2]
        print(name, json.dumps(res), flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()
        time.sleep(3)


if __name__ == "__main__":
    for n in (sys.argv[1:] or CONFIGS):
        run(n)
