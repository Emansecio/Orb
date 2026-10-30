"""Collect narrow evidence about snapshot failures and routine work, without exporting chat bodies."""
from collections import Counter
import datetime as dt
import hashlib
import json
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
ROOT = Path.home() / "Library/Application Support/Orb"
sources = []


def read(path):
    raw = path.read_bytes()
    sources.append(dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw)))
    return json.loads(raw)


data = read(ROOT / "conversations/D5AE91E3-7C79-4079-95E3-34CDBD05DD0A.json")
messages = data["messages"]
calls = {c["id"]: c for m in messages for c in m.get("toolCalls", [])}
results = {m.get("toolCallID"): m for m in messages if m["role"] == "tool"}
snapshot_calls = [c for c in calls.values() if c["name"] == "browse_snapshot"]
failures = []
for index, message in enumerate(messages):
    call = calls.get(message.get("toolCallID"), {})
    if message["role"] != "tool" or not message.get("isError") or call.get("name") != "browse_snapshot":
        continue
    category = ("CSS selector absent" if "did not match any element" in message["content"] else
                "no AX node for CSS selector" if "No accessibility node found for selector" in message["content"] else "other")
    following = []
    for candidate in messages[index+1:]:
        if candidate["role"] == "user":
            break
        if candidate.get("toolCalls"):
            following = candidate["toolCalls"]
            break
    next_snapshots = [c for c in following if c["name"] == "browse_snapshot"]
    args = json.loads(call["arguments"])
    failures.append(dict(message_index=index, tool_call_id=call["id"], category=category,
                         selector=args.get("selector"), query_ignored="query" in args,
                         raw_error=message["content"],
                         next_tool_names=[c["name"] for c in following],
                         next_snapshots=[dict(selector=json.loads(c["arguments"]).get("selector"),
                                              succeeded=c["id"] in results and not results[c["id"]].get("isError"))
                                         for c in next_snapshots]))

state = read(ROOT / "state.json")
routines = []
for routine in state["routines"]:
    if not routine["isEnabled"]:
        continue
    path = ROOT / "conversations" / routine["botID"] / ("routine-" + routine["id"] + ".json")
    saved = read(path) if path.exists() else {}
    runs = []
    active = None
    for item in saved.get("items", []):
        kind = item["kind"]
        if "notice" in kind and any(isinstance(v, str) and v.startswith("Execução de ") for v in kind["notice"].values()):
            active = dict(start=dt.datetime.fromtimestamp(item["date"] + 978307200, ZoneInfo("America/Sao_Paulo")).isoformat(),
                          tools=0, failed_tools=0, reads=0, terminal=0, assistant_items=0)
            runs.append(active)
        if active is None:
            continue
        if "tool" in kind:
            tool = kind["tool"]["_0"]
            active["tools"] += 1
            active["failed_tools"] += tool["state"] == "failed"
            active["reads"] += tool["title"] == "Lendo arquivo"
            active["terminal"] += tool["title"] == "Rodando no Terminal"
        active["assistant_items"] += "bot" in kind
    routines.append(dict(id=routine["id"], name=routine["name"], schedule=routine["schedule"],
                         prompt_chars=len(routine["prompt"]), retained_runs=runs,
                         retained_tools=sum(r["tools"] for r in runs), retained_reads=sum(r["reads"] for r in runs),
                         latest_model_history_messages=len(saved.get("messages", [])),
                         excludes_2330="23:30" in routine["prompt"],
                         requires_reading_skill="Ler integralmente" in routine["prompt"]))

usage = read(ROOT / "uso/2026-10.json")["buckets"]
daily = {}
for day in sorted({dt.datetime.fromtimestamp(r["hour"], ZoneInfo("America/Sao_Paulo")).strftime("%Y-%m-%d") for r in usage}):
    rows = [r for r in usage if dt.datetime.fromtimestamp(r["hour"], ZoneInfo("America/Sao_Paulo")).strftime("%Y-%m-%d") == day]
    routine_rows = [r for r in rows if r["source"] == "routine"]
    daily[day] = dict(all_requests=sum(r["requests"] for r in rows), routine_requests=sum(r["requests"] for r in routine_rows),
                      routine_prompt=sum(r.get(k, 0) for r in routine_rows for k in ("input", "cacheRead", "cacheWrite")))

summary = dict(snapshot_calls=len(snapshot_calls), failures=len(failures),
               categories=dict(Counter(f["category"] for f in failures)),
               calls_with_selector=sum(bool(json.loads(c["arguments"]).get("selector")) for c in snapshot_calls),
               calls_with_ignored_query=sum("query" in json.loads(c["arguments"]) for c in snapshot_calls),
               failure_then_immediate_new_snapshot=sum(bool(f["next_snapshots"]) for f in failures),
               failure_then_immediate_successful_snapshot=sum(any(s["succeeded"] for s in f["next_snapshots"]) for f in failures),
               failure_then_immediate_successful_unscoped_snapshot=sum(any(s["succeeded"] and s["selector"] is None for s in f["next_snapshots"]) for f in failures))
summary["failure_then_only_unscoped_successful_snapshot"] = sum(
    f["next_tool_names"] == ["browse_snapshot"] and any(s["succeeded"] and s["selector"] is None for s in f["next_snapshots"])
    for f in failures)
result = dict(timestamp_utc=dt.datetime.now(dt.timezone.utc).isoformat(), sources=sources, summary=summary,
              snapshot_failures=failures, enabled_routines=routines, daily_usage=daily)
(HERE / "investigation.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(dict(summary=summary, routines=[{k: v for k, v in r.items() if k != "retained_runs"} for r in routines]), ensure_ascii=False, indent=2))
