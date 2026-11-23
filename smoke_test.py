"""Quick check of the local server: one chat answer and one tool call.

Run: python smoke_test.py   (server must be running: ink serve, or ink status to check)
"""
import json
import time
import urllib.request

URL = "http://127.0.0.1:8080/v1/chat/completions"
MODEL = "inkling-2-mini"


def post(body):
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    t = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        out = json.load(r)
    return out, time.time() - t


# 1. Plain question
out, secs = post({
    "model": MODEL,
    "messages": [{"role": "user", "content": "In two sentences: why is the sky blue?"}],
    "reasoning_effort": "low",
    "max_tokens": 1500,
})
msg = out["choices"][0]["message"]
usage = out.get("usage", {})
print("== Chat ==")
print(msg.get("content"))
print(f"[{secs:.1f}s, usage={usage}]\n")

# 2. Tool call
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}]
messages = [{"role": "user", "content": "What's the weather in Lisbon right now?"}]
out, secs = post({
    "model": MODEL, "messages": messages, "tools": tools,
    "reasoning_effort": "low", "max_tokens": 1500,
})
choice = out["choices"][0]
print("== Tool call ==")
print("finish_reason:", choice.get("finish_reason"))
calls = choice["message"].get("tool_calls") or []
print(json.dumps(calls, indent=2))
print(f"[{secs:.1f}s]\n")

if calls:
    # 3. Feed the tool result back and get the final answer
    call = calls[0]
    messages += [
        {"role": "assistant", "content": choice["message"].get("content") or "", "tool_calls": calls},
        {"role": "tool", "tool_call_id": call.get("id"), "name": call["function"]["name"],
         "content": json.dumps({"city": "Lisbon", "temp_c": 19, "conditions": "sunny"})},
    ]
    out, secs = post({
        "model": MODEL, "messages": messages, "tools": tools,
        "reasoning_effort": "low", "max_tokens": 1500,
    })
    print("== Answer after tool result ==")
    print(out["choices"][0]["message"].get("content"))
    print(f"[{secs:.1f}s]")
