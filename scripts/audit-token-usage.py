#!/usr/bin/env python3
"""Read Orb's own usage and conversations; emit counts, never message bodies or credentials."""

import argparse
import collections
import datetime as dt
import hashlib
import json
import re
from pathlib import Path
from zoneinfo import ZoneInfo


FIELDS = ("requests", "input", "cacheRead", "cacheWrite", "cacheWrite1h", "output")
TZ = ZoneInfo("America/Sao_Paulo")
SOURCES = []


def read(path):
    data = path.read_bytes()
    SOURCES.append({"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return data.decode("utf-8")


def total(rows):
    result = {k: sum(r.get(k, 0) or 0 for r in rows) for k in FIELDS}
    result["prompt"] = result["input"] + result["cacheRead"] + result["cacheWrite"]
    result["uncached"] = result["input"] + result["cacheWrite"]
    result["cache_hit"] = result["cacheRead"] / result["prompt"] if result["prompt"] else None
    return result


def grouped(rows, key):
    groups = collections.defaultdict(list)
    for row in rows:
        groups[key(row)].append(row)
    return {k: total(v) for k, v in sorted(groups.items())}


def quantiles(values):
    values = sorted(values)
    if not values:
        return {}
    return {"min": values[0], "p50": values[(len(values) - 1) // 2],
            "p95": values[int((len(values) - 1) * .95)], "max": values[-1]}


def fnv_tag(text):
    value = 2166136261
    for byte in text.encode():
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return f"{value:08x}"


def chars(message):
    parts = (message.get("reasoning") or {}).get("parts", [])
    return len(message.get("content", "")) + sum(
        len(c.get(k, "")) for c in message.get("toolCalls", []) for k in ("id", "name", "arguments")
    ) + 16 + len(message.get("images", [])) * 5600 + sum(
        len(p.get(k) or "") for p in parts for k in ("text", "data", "signature")
    )


def session(path, root):
    data = json.loads(read(path))
    if not isinstance(data, dict) or "messages" not in data:
        return None
    messages = data["messages"]
    calls = {c["id"]: c for m in messages for c in m.get("toolCalls", [])}
    tool_stats = collections.defaultdict(collections.Counter)
    repeat_results = collections.Counter()
    repeat_calls = collections.Counter()
    compact_json_savings = 0
    for message in messages:
        for call in message.get("toolCalls", []):
            try:
                arguments = json.dumps(json.loads(call["arguments"]), sort_keys=True, ensure_ascii=False)
            except (ValueError, TypeError):
                arguments = call.get("arguments", "")
            repeat_calls[(call["name"], hashlib.sha256(arguments.encode()).hexdigest())] += 1
        if message["role"] != "tool":
            continue
        text = message.get("content", "")
        name = calls.get(message.get("toolCallID"), {}).get("name", "unmatched")
        stats = tool_stats[name]
        stats["count"] += 1
        stats["chars"] += len(text)
        stats["errors"] += bool(message.get("isError"))
        stats["over_4000"] += len(text) > 4000
        stats["over_24000"] += len(text) > 24000
        repeat_results[(name, hashlib.sha256(text.encode()).hexdigest(), len(text))] += 1
        try:
            obj = json.loads(text)
            if isinstance(obj, (dict, list)):
                compact = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
                assert json.loads(compact) == obj
                saved = max(0, len(text) - len(compact))
                compact_json_savings += saved
                stats["json_whitespace_savings_chars"] += saved
        except (ValueError, TypeError):
            pass
    covered = min(data.get("summaryCoveredCount", 0), len(messages))
    remaining = messages[covered:]
    reasoning = collections.Counter()
    for message in messages:
        trace = message.get("reasoning") or {}
        if trace:
            reasoning["messages"] += 1
            reasoning["data_chars"] += sum(len(p.get("data") or "") for p in trace.get("parts", []))
            reasoning["text_chars"] += sum(len(p.get("text") or "") for p in trace.get("parts", []))
    result = {
        "file": str(path), "active": path.parent == root / "conversations", "id": path.stem,
        "pipe_tag": fnv_tag(data.get("gatewaySessionID", path.stem)),
        "messages": len(messages), "requests_in_history": sum(m["role"] == "user" for m in messages),
        "compactions": data.get("compactions", 0), "covered": covered,
        "condensed": data.get("condensedCount", 0), "remaining_messages": len(remaining),
        "raw_remaining_chars_including_reasoning": sum(map(chars, remaining)),
        "remaining_content_chars_by_role": dict(collections.Counter({
            role: sum(len(m.get("content", "")) for m in remaining if m["role"] == role)
            for role in ("user", "assistant", "tool")})),
        "remaining_reasoning_data_chars": sum(len(p.get("data") or "") for m in remaining
                                                for p in (m.get("reasoning") or {}).get("parts", [])),
        "summary_chars": len(data.get("summary") or ""),
        "chunks": len(data.get("chunkSummaries", [])), "reasoning": dict(reasoning),
        "tools": dict(sorted(tool_stats.items(), key=lambda x: -x[1]["chars"])),
        "exact_duplicate_output_chars": sum((n - 1) * k[2] for k, n in repeat_results.items()),
        "repeated_identical_calls": sum(n - 1 for n in repeat_calls.values()),
        "json_whitespace_savings_chars": compact_json_savings,
        "stored_pruned_tool_outputs": sum("caracteres omitidos de uma saída antiga" in m.get("content", "")
                                           for m in messages if m["role"] == "tool"),
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path.home() / "Library/Application Support/Orb")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.data_dir.expanduser().resolve()
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    state = json.loads(read(root / "state.json"))
    selector_path = Path(__file__).resolve().parents[1] / "Sources/Orb/Engine/ChunkSummary.swift"
    selector_source = read(selector_path)
    match = re.search(r'cheapWords = \[([^\]]+)\]', selector_source)
    cheap_words = re.findall(r'"([^"]+)"', match[1]) if match else []
    configuration = {
        "contextMemory": state.get("contextMemory"), "defaultModel": state.get("defaultModel"),
        "bots": [{k: bot.get(k) for k in ("id", "name", "model", "effort")}
                 for bot in state.get("bots", [])],
        "auxiliary_selector_words": cheap_words,
        "chatgpt_catalog": [{"id": m["id"], "defaultEffort": m.get("defaultEffort"),
                             "matches_cheap_word": bool(set(re.findall(r'[a-z0-9]+', m["id"].lower())) & set(cheap_words))}
                            for a in state.get("providers", []) if a.get("kind") == "chatgpt"
                            for m in a.get("models", [])],
        "routines": [{"id": routine["id"], "name": routine["name"], "isEnabled": routine.get("isEnabled"),
                      "schedule": routine.get("schedule"), "retained_runs": len(routine.get("runs", [])),
                      "retained_succeeded": sum(bool(run.get("succeeded")) for run in routine.get("runs", []))}
                     for routine in state.get("routines", [])],
    }
    rows = []
    for path in sorted((root / "uso").glob("*.json")):
        rows += json.loads(read(path)).get("buckets", [])
    daily = lambda r: dt.datetime.fromtimestamp(r["hour"], TZ).strftime("%Y-%m-%d")
    usage = {
        "buckets": len(rows), "total": total(rows), "by_model": grouped(rows, lambda r: r["model"]),
        "by_source": grouped(rows, lambda r: r["source"]), "by_day": grouped(rows, daily),
        "by_day_model": grouped(rows, lambda r: daily(r) + "/" + r["model"]),
        "by_model_source": grouped(rows, lambda r: r["model"] + "/" + r["source"]),
    }
    assert sum(x["prompt"] for x in usage["by_model"].values()) == usage["total"]["prompt"]
    assert sum(x["requests"] for x in usage["by_source"].values()) == usage["total"]["requests"]
    metrics = []
    for path in sorted((root / "claude-pipe").glob("cache-metrics.jsonl*")):
        metrics += [dict(json.loads(line), requests=1) for line in read(path).splitlines() if line.strip()]
    pipe = {
        "records": len(metrics), "first": min((r["ts"] for r in metrics), default=None),
        "last": max((r["ts"] for r in metrics), default=None),
        "by_plan": grouped(metrics, lambda r: r["plan"]),
        "by_reason": grouped(metrics, lambda r: r.get("reason", "none")),
        "by_day_plan": grouped(metrics, lambda r: r["ts"][:10] + "/" + r["plan"]),
        "quantiles": {k: quantiles([r.get(k, 0) for r in metrics]) for k in ("messages", "chars", "cacheWrite")},
        "counts_by_plan": dict(collections.Counter(r["plan"] for r in metrics)),
        "counts_by_reason": dict(collections.Counter(r.get("reason", "none") for r in metrics)),
    }
    sessions = []
    for path in sorted((root / "conversations").rglob("*.json")):
        if ".meta." not in path.name:
            found = session(path, root)
            if found is not None:
                sessions.append(found)
    report = {"started_utc": started, "finished_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
              "timezone": str(TZ), "usage": usage, "claude_pipe": pipe, "sessions": sessions, "sources": SOURCES,
              "configuration": configuration,
              "limitations": ["Usage is hourly, without per-request sizes for non-Claude clients.",
                              "Session sizes are stored raw text; the context window transforms them before sending.",
                              "Old persisted tool outputs are already pruned to about 4000 characters by ConversationCoding.",
                              "Repeated calls/results are not necessarily redundant: external state may change.",
                              "Encrypted reasoning size in characters is not its billed token count.",
                              "Files are individually consistent reads; the running app may write between reads."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.output.resolve()), "total": usage["total"],
                      "sessions": len(sessions), "active_sessions": sum(s["active"] for s in sessions),
                      "pipe_records": len(metrics)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
