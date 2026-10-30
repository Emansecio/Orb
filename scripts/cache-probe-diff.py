#!/usr/bin/env python3
"""Diff de linhas do CacheProbe (uso/cache-probe-YYYY-MM.jsonl) por conversa.

Para cada par consecutivo de requisições da mesma conversa, mostra onde o
prefixo deixou de ser idêntico: instruções, lista de ferramentas, ou o primeiro
item de `input` que mudou — a fronteira provável do cache do provedor.

Uso: python3 scripts/cache-probe-diff.py [arquivo.jsonl] [--all]
     (sem arquivo, lê o mês corrente em ~/Library/Application Support/Orb/uso)
"""
import json, sys
from pathlib import Path
from datetime import datetime

USAGE = Path.home() / "Library/Application Support/Orb/uso"


def first_diff(prev, cur):
    """Where the cur request's prefix stopped matching the prev one's."""
    if prev["fp"]["instr"][1] != cur["fp"]["instr"][1]:
        return "instrucoes", 0
    if prev["fp"]["tools"][1] != cur["fp"]["tools"][1]:
        return "ferramentas", 0
    a, b = prev["fp"]["items"], cur["fp"]["items"]
    for i, (x, y) in enumerate(zip(a, b)):
        if x[2] != y[2]:
            return f"item[{i}] {y[0]} (era {x[0]})", i
    if len(a) != len(b):
        return f"itens {len(a)} -> {len(b)}", min(len(a), len(b))
    return "identico (prefixo estavel)", -1


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = Path(args[0]) if args else USAGE / f"cache-probe-{datetime.now():%Y-%m}.jsonl"
    if not path.exists():
        sys.exit(f"sem arquivo: {path}")
    lines = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    by_conv = {}
    for row in lines:
        by_conv.setdefault(row.get("conv", "(sem chave)"), []).append(row)
    misses = 0
    for conv, rows in sorted(by_conv.items()):
        if len(rows) < 2 and "--all" not in sys.argv:
            continue
        print(f"== {conv} ({len(rows)} requisicoes)")
        prev = None
        for row in rows:
            use = row.get("usage", {})
            cached = use.get("cached", 0)
            prompt = (use.get("in") or 0) + cached
            tag = "?"
            if prev is not None:
                where, idx = first_diff(prev, row)
                prompt_kb = prompt / 1024
                pct = f"{100 * cached / prompt:.0f}%" if prompt else "-"
                mark = " <== cache baixo" if prompt and cached / prompt < 0.2 else ""
                print(f"  {datetime.fromtimestamp(row['t']):%m-%d %H:%M:%S}  prompt {prompt_kb:.1f}k, cached {pct}{mark}")
                print(f"    primeira mudanca: {where}")
                if idx >= 0 and mark:
                    misses += 1
            else:
                print(f"  {datetime.fromtimestamp(row['t']):%m-%d %H:%M:%S}  prompt {prompt / 1024:.1f}k (primeira req.)")
            prev = row
    if misses:
        print(f"\n{misses} requisicao(oes) com cache baixo e prefixo identificavel — a fronteira esta no item acima.")


if __name__ == "__main__":
    main()
