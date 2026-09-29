"""Build one input bundle per wiki page for the final VERIFY pass.

Each bundle holds the page's VERIFY questions (from verify-questions.txt), the hardware answers of the
C and Python runs for those questions (hw-retest-result.json), the hardware problems that name the
page, and the code-derived corrections for it (wiki-corrections-from-code.json).
"""
import json
import os
import re

SCRATCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIKI = r"C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface\docs\wiki"
OUT = os.path.join(SCRATCH, "wikipass", "inputs")
os.makedirs(OUT, exist_ok=True)

questions = {}
pages_of = {}
for line in open(os.path.join(SCRATCH, "verify-questions.txt"), encoding="utf-8"):
    m = re.match(r"(\d+)\. (.*?)\s+\[(.*)\]\s*$", line.rstrip("\n"))
    if not m:
        continue
    n = int(m.group(1))
    questions[n] = m.group(2)
    pages_of[n] = [os.path.splitext(os.path.basename(p.strip().replace("\\", "/")))[0]
                   for p in m.group(3).split(",")]

hw = json.load(open(os.path.join(SCRATCH, "hw-retest-result.json"), encoding="utf-8"))


def ids(s):
    return [int(x) for x in re.findall(r"\d+", s)]


groups = []
for q in hw["triage"]["hardware_questions"]:
    groups.append({"ids": ids(q["ids"]), "question": q["question"], "answers": []})
by_id = {}
for g in groups:
    for i in g["ids"]:
        by_id.setdefault(i, []).append(g)
for side in ("c", "python"):
    for a in hw[side]["answers"]:
        a_ids = ids(a["ids"])
        entry = {"helper_run": side, "answer": a["answer"], "evidence": a.get("evidence", "")}
        placed = False
        for g in groups:
            if set(a_ids) & set(g["ids"]):
                g["answers"].append(entry)
                placed = True
        if not placed:
            groups.append({"ids": a_ids, "question": "(no triage group)", "answers": [entry]})
            for i in a_ids:
                by_id.setdefault(i, []).append(groups[-1])

corrections = json.load(open(os.path.join(SCRATCH, "wiki-corrections-from-code.json"), encoding="utf-8"))
problems = [dict(p, run=side) for side in ("c", "python") for p in hw[side]["problems"]]

pages = sorted(os.path.splitext(f)[0] for f in os.listdir(WIKI) if f.endswith(".md") and not f.startswith("_"))
summary = []
for page in pages:
    text = open(os.path.join(WIKI, page + ".md"), encoding="utf-8").read()
    markers = [(text.count("\n", 0, m.start()) + 1, m.group(1).strip())
               for m in re.finditer(r"<!--\s*VERIFY:(.*?)-->", text, re.S)]
    qs = sorted(n for n, ps in pages_of.items() if page in ps)
    seen, hw_groups = set(), []
    for n in qs:
        for g in by_id.get(n, []):
            if id(g) not in seen and g["answers"]:
                seen.add(id(g))
                hw_groups.append(g)
    probs = [p for p in problems if page in json.dumps(p)]
    corr = [c for c in corrections if c.get("page") == page]
    bundle = {
        "page": page,
        "verify_markers_now": [{"line": ln, "text": t} for ln, t in markers],
        "questions": [{"id": n, "text": questions[n]} for n in qs],
        "hardware_answers": hw_groups,
        "hardware_problems_naming_this_page": probs,
        "code_corrections": corr,
    }
    with open(os.path.join(OUT, page + ".json"), "w", encoding="utf-8") as f:
        json.dump(bundle, f, indent=1, ensure_ascii=False)
    summary.append((page, len(markers), len(qs), len(hw_groups), len(probs), len(corr)))

print("%-45s %7s %5s %5s %5s %5s" % ("page", "markers", "qs", "hw", "probs", "corr"))
for row in summary:
    print("%-45s %7d %5d %5d %5d %5d" % row)
print("total markers", sum(r[1] for r in summary))
