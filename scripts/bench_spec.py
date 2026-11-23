"""Compare generation speed with and without the DSpark drafter on natural prompts.
  python scripts/bench_spec.py base dspark2 dspark3
"""
import sys, time, subprocess
sys.path.insert(0, __import__("os").path.dirname(__file__))
import bench

bench.CONFIGS["base"] = ["-c", "65536", "-ctk", "q8_0", "-ctv", "q8_0"]
PROMPTS = [
    "Write a Python function that parses an ISO 8601 duration string into seconds, with tests.",
    "Explain the difference between a mutex and a semaphore, with a short C example of each.",
    "Refactor this to be idiomatic TypeScript: function f(a){var r=[];for(var i=0;i<a.length;i++){if(a[i]%2==0)r.push(a[i]*2)}return r}",
    "Write a bash script that finds the 10 largest files under a directory and prints human-readable sizes.",
    "What are the tradeoffs between SQLite WAL mode and rollback journal mode? Be concise.",
]


def run(name):
    proc = subprocess.Popen([bench.EXE, *bench.COMMON, *bench.CONFIGS[name]],
                            stdout=open(f"{bench.ROOT}/scripts/spec-{name}.log", "w"), stderr=subprocess.STDOUT)
    try:
        bench.wait_ready(proc)
        bench.post("/v1/chat/completions", {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8})
        toks = secs = dn = da = 0
        for rep in range(2):
            for p in PROMPTS:
                t = bench.post("/v1/chat/completions", {"messages": [{"role": "user", "content": p}],
                               "max_tokens": 1500, "reasoning_effort": "low", "cache_prompt": False})["timings"]
                toks += t["predicted_n"]; secs += t["predicted_ms"] / 1000
                dn += t.get("draft_n", 0) or 0; da += t.get("draft_n_accepted", 0) or 0
        acc = f", draft accepted {da}/{dn} ({100*da/dn:.0f}%)" if dn else ""
        print(f"{name}: {toks} tokens in {secs:.1f}s = {toks/secs:.1f} tok/s{acc}", flush=True)
    finally:
        proc.terminate(); proc.wait(20); time.sleep(3)


for n in sys.argv[1:]:
    run(n)
