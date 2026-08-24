#!/usr/bin/env bash
# Offline drift guard for Phase 7 operator-sequence runbook locations (F7-12).
# Sibling of rail-interface-check.sh: one declared-facts file plus field-equality
# assertions. File/JSON/markdown only — no network clients.
#
# Extractions are content-anchored (section headings, table markers, regexes).
# Never line numbers. A missing section is FAIL, not a silent pass.
#
# Env overrides (for test-helpers fixtures):
#   PHASE7_GATES_JSON     default: $REPO_ROOT/tasks/phase7-gates.json
#   PHASE7_PRD            default: $REPO_ROOT/tasks/prd-phase-7-fault-proofs.md
#   PHASE7_README         default: $REPO_ROOT/README.md
#   PHASE7_ENV_EXAMPLE    default: $REPO_ROOT/.env.sepolia.example
#   PHASE7_LEARNING_PRD   default: $REPO_ROOT/tasks/prd-l2-learning-chain.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Do not source lib.sh. It loads .env / .env.example (macOS FORTEL2_ROOT) and
# mkdir -p DATA_DIR. This check is offline JSON/markdown only.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: required binary not found on PATH: python3" >&2
  exit 1
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PHASE7_GATES_JSON="${PHASE7_GATES_JSON:-$REPO_ROOT/tasks/phase7-gates.json}"
export PHASE7_PRD="${PHASE7_PRD:-$REPO_ROOT/tasks/prd-phase-7-fault-proofs.md}"
export PHASE7_README="${PHASE7_README:-$REPO_ROOT/README.md}"
export PHASE7_ENV_EXAMPLE="${PHASE7_ENV_EXAMPLE:-$REPO_ROOT/.env.sepolia.example}"
export PHASE7_LEARNING_PRD="${PHASE7_LEARNING_PRD:-$REPO_ROOT/tasks/prd-l2-learning-chain.md}"

exec python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import sys

FAILS = 0
# Set from phase7-gates.json markerConvention.onRed after JSON load.
# Empty until then so parse/heading failures stay unchanged.
CONVENTION_POINTER = ""


class ExtractError(Exception):
    pass


def pass_(msg: str) -> None:
    print(f"PASS {msg}")


def fail(msg: str) -> None:
    global FAILS
    print(f"FAIL {msg}")
    FAILS += 1


def fail_with_convention(msg: str) -> None:
    """Same matching/exit path as fail(); suffix points at the documented convention."""
    suffix = f" — {CONVENTION_POINTER}" if CONVENTION_POINTER else ""
    fail(f"{msg}{suffix}")


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise ExtractError(f"could not read {path}: {e}") from e


def heading_level(line: str) -> int | None:
    m = re.match(r"^(#{1,6})\s+\S", line)
    return len(m.group(1)) if m else None


def extract_section(text: str, heading: str, path: str) -> str:
    """Content-anchored section extract. heading must match a markdown heading
    line exactly, or that heading plus a trailing parenthetical / suffix."""
    lines = text.splitlines()
    hashes = ""
    for ch in heading:
        if ch == "#":
            hashes += ch
        else:
            break
    if not hashes:
        raise ExtractError(f"heading {heading!r} is not a markdown heading")
    level = len(hashes)
    start = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == heading or stripped.startswith(heading + " "):
            start = i
            break
    if start is None:
        raise ExtractError(f"could not find heading {heading!r} in {path}")
    end = len(lines)
    for j in range(start + 1, len(lines)):
        lv = heading_level(lines[j])
        if lv is not None and lv <= level:
            end = j
            break
    body = "\n".join(lines[start:end])
    if not body.strip():
        raise ExtractError(f"heading {heading!r} in {path} has empty section")
    return body


def parse_prd_table(section: str, path: str) -> dict[str, str]:
    lines = section.splitlines()
    header_idx = None
    for i, line in enumerate(lines):
        if re.match(r"^\|\s*#\s*\|", line):
            header_idx = i
            break
    if header_idx is None:
        raise ExtractError(
            f"could not find Operator sequence table (header '| # |') in {path}"
        )
    steps: dict[str, str] = {}
    for line in lines[header_idx + 2 :]:
        if not line.startswith("|"):
            break
        cells = [c.strip() for c in line.split("|")]
        if len(cells) < 5:
            continue
        num = cells[1]
        when = cells[2]
        what = cells[3]
        if num in {"", "—", "-", "–"}:
            continue
        # When + What: v7 trigger lives in When; action markers live in What.
        steps[num] = f"{when} {what}"
    if not steps:
        raise ExtractError(f"Operator sequence table parsed 0 steps in {path}")
    return steps


STEP_LINE = re.compile(r"^(\d+[a-z]?)\.\s+(.*)$")


def parse_readme_steps(section: str, path: str) -> dict[str, str]:
    lines = section.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "Order:" or line.strip().startswith("Order:"):
            start = i + 1
            break
    if start is None:
        raise ExtractError(
            f"could not find 'Order:' in Network reset procedure in {path}"
        )
    steps: dict[str, str] = {}
    current: str | None = None
    buf: list[str] = []

    def flush() -> None:
        if current is not None:
            steps[current] = "\n".join(buf)

    for line in lines[start:]:
        m = STEP_LINE.match(line)
        if m:
            flush()
            current = m.group(1)
            buf = [m.group(2)]
            continue
        if heading_level(line) is not None:
            break
        if current is not None:
            buf.append(line)
    flush()
    if not steps:
        raise ExtractError(
            f"Network reset procedure Order: parsed 0 steps in {path}"
        )
    return steps


def extract_glossary_bullet(text: str, heading: str, bullet: str, path: str) -> str:
    lines = text.splitlines()
    gstart = None
    for i, line in enumerate(lines):
        if heading in line:
            gstart = i
            break
    if gstart is None:
        raise ExtractError(f"could not find {heading!r} in {path}")
    bstart = None
    # Glossary is a handful of bullets; bound the search so a later
    # unrelated heading does not silently match a different bullet.
    for i in range(gstart, min(gstart + 40, len(lines))):
        if lines[i].startswith(bullet):
            bstart = i
            break
    if bstart is None:
        raise ExtractError(f"could not find {bullet!r} in {path}")
    bend = bstart + 1
    while bend < len(lines):
        if lines[bend].startswith("- **"):
            break
        if heading_level(lines[bend]) is not None:
            break
        bend += 1
    body = "\n".join(lines[bstart:bend])
    if not body.strip():
        raise ExtractError(f"{bullet!r} bullet is empty in {path}")
    return body


def extract_phase7_row(text: str, heading: str, phase_cell: str, path: str) -> str:
    lines = text.splitlines()
    rstart = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == heading or stripped.startswith(heading + " "):
            rstart = i
            break
    if rstart is None:
        raise ExtractError(f"could not find heading {heading!r} in {path}")
    rend = len(lines)
    level = heading_level(lines[rstart]) or 2
    for j in range(rstart + 1, len(lines)):
        lv = heading_level(lines[j])
        if lv is not None and lv <= level:
            rend = j
            break
    for line in lines[rstart:rend]:
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.split("|")]
        if len(cells) >= 3 and cells[1] == phase_cell:
            return line
    raise ExtractError(
        f"could not find Phase 7 row (cell {phase_cell!r}) in {heading} table in {path}"
    )


def find_marker_in_steps(steps: dict[str, str], marker: str) -> list[str]:
    return [num for num, body in steps.items() if marker in body]


def require_markers(
    *,
    action_id: str,
    loc: str,
    declared: str,
    body: str | None,
    markers: list[str],
    steps: dict[str, str],
) -> None:
    if body is None:
        found = find_marker_in_steps(steps, markers[0]) if markers else []
        found_s = ",".join(found) if found else "<missing>"
        fail_with_convention(
            f"{action_id} {loc} numbering (declared={declared} found={found_s})"
        )
        return
    for marker in markers:
        if marker in body:
            continue
        found = find_marker_in_steps(steps, marker)
        if found:
            fail_with_convention(
                f"{action_id} {loc} numbering (declared={declared} found={','.join(found)})"
            )
        else:
            fail_with_convention(
                f"{action_id} {loc} marker {marker!r} not found (declared step {declared})"
            )


def check_timestamps(label: str, text: str, notice: dict) -> None:
    sent_utc = notice["sentUtc"]
    sent_local = notice["sentLocal"]
    gate_utc = notice["gateUtc"]
    for m in re.finditer(r"\d{4}-\d{2}-\d{2}T20:00Z", text):
        if m.group(0) != gate_utc:
            fail(
                f"{label} gate timestamp (declared={gate_utc} found={m.group(0)})"
            )
    for m in re.finditer(r"\d{4}-\d{2}-\d{2} 20:00Z", text):
        if m.group(0) != sent_utc:
            fail(
                f"{label} notice timestamp (declared={sent_utc} found={m.group(0)})"
            )
    for m in re.finditer(r"(\d{4}-\d{2}-\d{2}) 13:00 PDT", text):
        declared_local_day = sent_local.split(" ")[0]
        if m.group(1) != declared_local_day:
            fail(
                f"{label} notice local date (declared={sent_local} found={m.group(0)})"
            )


# Per-paragraph / imperative, not file-wide: a "next redeploy" phrase at the
# top of .env.sepolia.example must not bless a later `run FORCE_SEPOLIA_REDEPLOY=1 now`.
WIPE_FILE_NEGATION = (
    "second time",
    "do not re-run",
    "must not be re-run",
    "never execute",
    "never set",
    "next redeploy",
    "would wipe",
)

IMPERATIVE_WIPE = re.compile(
    r"(?:run|execute)\s+FORCE_SEPOLIA_REDEPLOY=1",
    re.I,
)

GATE_ID_RE = re.compile(r"\bF7-\d+\b")


def fmt_ids(ids: set[str] | list[str]) -> str:
    return ",".join(sorted(ids, key=lambda s: int(s.split("-")[1]))) or "<none>"


def extract_gate_ids(text: str) -> set[str]:
    return set(GATE_ID_RE.findall(text))


def check_gate_ids(label: str, text: str, declared: set[str]) -> None:
    found = extract_gate_ids(text)
    if found != declared:
        fail_with_convention(
            f"{label} gate ids (declared={fmt_ids(declared)} found={fmt_ids(found)})"
        )
    else:
        pass_(f"{label} gate ids match ({fmt_ids(declared)})")


def comment_paragraphs(text: str) -> list[str]:
    paras: list[str] = []
    buf: list[str] = []
    for line in text.splitlines():
        if line.startswith("#"):
            buf.append(line)
            continue
        if buf:
            paras.append("\n".join(buf))
            buf = []
    if buf:
        paras.append("\n".join(buf))
    return paras


def unnegated_wipe_units(text: str) -> list[str]:
    hits: list[str] = []
    if IMPERATIVE_WIPE.search(text):
        hits.append("imperative run/execute FORCE_SEPOLIA_REDEPLOY=1")
    hashed = any(
        ln.startswith("#") and "FORCE_SEPOLIA_REDEPLOY=1" in ln
        for ln in text.splitlines()
    )
    units = comment_paragraphs(text) if hashed else (
        [text] if "FORCE_SEPOLIA_REDEPLOY=1" in text else []
    )
    for unit in units:
        if "FORCE_SEPOLIA_REDEPLOY=1" not in unit:
            continue
        if IMPERATIVE_WIPE.search(unit):
            continue
        low = unit.lower()
        if not any(p in low for p in WIPE_FILE_NEGATION):
            hits.append(" ".join(unit.split())[:180])
    return hits


def check_complete_range(label: str, text: str, declared: list[str]) -> None:
    # Only ranges claimed complete — "steps 11–13" outstanding must not match.
    pat = re.compile(
        r"steps?\s+(\d+[a-z]?)\s*[–-]\s*(\d+[a-z]?)\s+(?:are\s+)?complete",
        re.I,
    )
    for m in pat.finditer(text):
        found = [m.group(1), m.group(2)]
        if found != declared:
            fail(
                f"{label} complete-steps range (declared={declared[0]}–{declared[1]} found={found[0]}–{found[1]})"
            )


def pointer_ok(label: str, text: str) -> None:
    missing = []
    if "prd-phase-7-fault-proofs.md" not in text:
        missing.append("prd-phase-7-fault-proofs.md")
    if "Operator sequence" not in text:
        missing.append("Operator sequence")
    if missing:
        fail(f"{label} pointer missing {', '.join(missing)}")
    else:
        pass_(f"{label} points at Operator sequence")


def main() -> int:
    global CONVENTION_POINTER
    gates_path = os.environ["PHASE7_GATES_JSON"]
    prd_path = os.environ["PHASE7_PRD"]
    readme_path = os.environ["PHASE7_README"]
    env_path = os.environ["PHASE7_ENV_EXAMPLE"]
    learning_path = os.environ["PHASE7_LEARNING_PRD"]

    try:
        facts = json.loads(read_text(gates_path))
    except ExtractError as e:
        fail(str(e))
        print("phase7-gate-parity: 1 FAIL(s)", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        fail(f"phase7-gates.json parses ({e})")
        print("phase7-gate-parity: 1 FAIL(s)", file=sys.stderr)
        return 1
    else:
        pass_("phase7-gates.json parses")

    try:
        loc = facts["locations"]
        notice = facts["notice"]
        executed = facts["executed"]
        v7 = facts["v7Bump"]
        preflight = facts["preflight"]
        actions = facts["steps"]
        gate_ids_facts = facts["gateIds"]
        marker_convention = facts["markerConvention"]
        prd_heading = loc["prd"]["heading"]
        readme_heading = loc["readme"]["heading"]
    except KeyError as e:
        fail(f"phase7-gates.json missing key {e}")
        print("phase7-gate-parity: 1 FAIL(s)", file=sys.stderr)
        return 1

    if not isinstance(marker_convention, dict):
        fail("phase7-gates.json markerConvention must be an object")
        print("phase7-gate-parity: 1 FAIL(s)", file=sys.stderr)
        return 1
    missing_mc = [
        k
        for k in ("completionMarkers", "gateIdSet", "onRed")
        if not str(marker_convention.get(k) or "").strip()
    ]
    if missing_mc:
        fail(
            f"phase7-gates.json markerConvention missing {','.join(missing_mc)}"
        )
        print("phase7-gate-parity: 1 FAIL(s)", file=sys.stderr)
        return 1
    CONVENTION_POINTER = str(marker_convention["onRed"]).strip()

    try:
        prd_text = read_text(prd_path)
        readme_text = read_text(readme_path)
        env_text = read_text(env_path)
        learning_text = read_text(learning_path)
        prd_section = extract_section(prd_text, prd_heading, prd_path)
        readme_section = extract_section(readme_text, readme_heading, readme_path)
        prd_steps = parse_prd_table(prd_section, prd_path)
        readme_steps = parse_readme_steps(readme_section, readme_path)
        glossary = extract_glossary_bullet(
            learning_text,
            loc["glossary"]["heading"],
            loc["glossary"]["bullet"],
            learning_path,
        )
        roadmap_row = extract_phase7_row(
            learning_text,
            loc["roadmap"]["heading"],
            loc["roadmap"]["phaseCell"],
            learning_path,
        )
    except ExtractError as e:
        fail(str(e))
        print(f"phase7-gate-parity: {FAILS} FAIL(s)", file=sys.stderr)
        return 1

    pass_(f"prd heading {prd_heading!r} found")
    pass_(f"readme heading {readme_heading!r} found")
    pass_(f"prd table parsed {len(prd_steps)} steps")
    pass_(f"readme Order: parsed {len(readme_steps)} steps")
    pass_("glossary Redeploy gate bullet found")
    pass_("Phase Roadmap row **7** found")

    declared_prd = {a["prd"] for a in actions if a.get("prd")}
    declared_readme = {a["readme"] for a in actions if a.get("readme")}
    extra_prd = sorted(set(prd_steps) - declared_prd)
    missing_prd = sorted(declared_prd - set(prd_steps))
    extra_readme = sorted(set(readme_steps) - declared_readme)
    missing_readme = sorted(declared_readme - set(readme_steps))
    if extra_prd:
        fail(f"undeclared PRD step(s) {','.join(extra_prd)}")
    else:
        pass_("every PRD table step is declared")
    if missing_prd:
        fail(f"missing PRD step(s) {','.join(missing_prd)}")
    else:
        pass_("every declared PRD step is in the table")
    if extra_readme:
        fail(f"undeclared README step(s) {','.join(extra_readme)}")
    else:
        pass_("every README Order step is declared")
    if missing_readme:
        fail(f"missing README step(s) {','.join(missing_readme)}")
    else:
        pass_("every declared README step is in Order:")

    both_ids = set(gate_ids_facts["both"])
    prd_ids = both_ids | set(gate_ids_facts.get("prdOnly") or [])
    readme_ids = both_ids | set(gate_ids_facts.get("readmeOnly") or [])
    check_gate_ids("PRD Operator sequence", prd_section, prd_ids)
    check_gate_ids("README Network reset procedure", readme_section, readme_ids)
    known_ids = prd_ids | readme_ids
    for label, text in (
        (".env.sepolia.example", env_text),
        ("glossary Redeploy gate", glossary),
        ("Phase 7 roadmap row", roadmap_row),
    ):
        extra = extract_gate_ids(text) - known_ids
        if extra:
            fail(
                f"{label} undeclared gate id(s) (declared={fmt_ids(known_ids)} found extra={fmt_ids(extra)})"
            )
        else:
            pass_(f"{label} gate ids are a subset of declared")

    for action in actions:
        aid = action["id"]
        prd_n = action.get("prd")
        if prd_n:
            require_markers(
                action_id=aid,
                loc="PRD",
                declared=prd_n,
                body=prd_steps.get(prd_n),
                markers=action.get("prdMustContain") or [],
                steps=prd_steps,
            )
            if action.get("prdMustContain") and all(
                m in prd_steps.get(prd_n, "") for m in action["prdMustContain"]
            ):
                pass_(f"{aid} PRD step {prd_n}")
        readme_n = action.get("readme")
        if readme_n:
            require_markers(
                action_id=aid,
                loc="README",
                declared=readme_n,
                body=readme_steps.get(readme_n),
                markers=action.get("readmeMustContain") or [],
                steps=readme_steps,
            )
            if action.get("readmeMustContain") and all(
                m in readme_steps.get(readme_n, "")
                for m in action["readmeMustContain"]
            ):
                pass_(f"{aid} README step {readme_n}")
        folded = action.get("readmeFoldedInto")
        folded_markers = action.get("readmeFoldedMustContain") or []
        if folded and folded_markers:
            body = readme_steps.get(folded)
            if body is None:
                fail(f"{aid} README fold target step {folded} missing")
            else:
                missing = [m for m in folded_markers if m not in body]
                if missing:
                    fail(
                        f"{aid} folded into README step {folded} missing {missing!r}"
                    )
                else:
                    pass_(f"{aid} folded into README step {folded}")

    # v7 trigger — declared per location (the two runbooks disagree; lock both).
    prd_v7_body = prd_steps.get(v7["prdStep"], "")
    if v7["prdTrigger"] in prd_v7_body:
        pass_(f"v7 PRD trigger at step {v7['prdStep']}")
    else:
        fail(
            f"v7 PRD trigger (declared={v7['prdTrigger']!r} at step {v7['prdStep']} found=<missing>)"
        )

    readme_v7_body = readme_steps.get(v7["readmeFoldedInto"], "")
    if v7["readmeTrigger"] in readme_v7_body:
        pass_(f"v7 README trigger at step {v7['readmeFoldedInto']}")
    else:
        fail(
            f"v7 README trigger (declared={v7['readmeTrigger']!r} at step {v7['readmeFoldedInto']} found=<missing>)"
        )

    if executed["prdBanner"] in prd_section:
        pass_("PRD executed-window banner")
    else:
        fail(
            f"PRD executed-window banner (declared={executed['prdBanner']!r} found=<missing>)"
        )
    if executed["readmeBanner"] in readme_section:
        pass_("README executed-window banner")
    else:
        fail(
            f"README executed-window banner (declared={executed['readmeBanner']!r} found=<missing>)"
        )

    if notice["sentUtc"] in prd_section:
        pass_("PRD notice sentUtc")
    else:
        fail(
            f"PRD notice sentUtc (declared={notice['sentUtc']} found=<missing>)"
        )
    if notice["gateUtc"] in prd_section:
        pass_("PRD ≥24h gate timestamp")
    else:
        fail(
            f"PRD ≥24h gate timestamp (declared={notice['gateUtc']} found=<missing>)"
        )
    if notice["sentReadme"] in readme_section:
        pass_("README notice sentReadme")
    else:
        fail(
            f"README notice (declared={notice['sentReadme']!r} found=<missing>)"
        )
    if notice["gateUtc"] in readme_section:
        pass_("README ≥24h gate timestamp")
    else:
        fail(
            f"README ≥24h gate timestamp (declared={notice['gateUtc']} found=<missing>)"
        )

    pf_step = preflight["readmeStep"]
    pf_body = readme_steps.get(pf_step, "")
    if preflight["readmeMustContain"] in pf_body:
        pass_(f"README preflight sentence at step {pf_step}")
    else:
        fail(
            f"README preflight sentence (declared={preflight['readmeMustContain']!r} at step {pf_step} found=<missing>)"
        )

    check_timestamps("PRD Operator sequence", prd_section, notice)
    check_timestamps("README Network reset procedure", readme_section, notice)
    check_timestamps("glossary Redeploy gate", glossary, notice)
    check_timestamps("Phase 7 roadmap row", roadmap_row, notice)
    check_timestamps(".env.sepolia.example", env_text, notice)

    # Completeness locations: a wipe command in the procedure is expected.
    # Summaries (3/4/5) must not instruct running it without negation.
    for label, text in (
        (".env.sepolia.example", env_text),
        ("glossary Redeploy gate", glossary),
        ("Phase 7 roadmap row", roadmap_row),
    ):
        hits = unnegated_wipe_units(text)
        if hits:
            fail(
                f"{label} instructs FORCE_SEPOLIA_REDEPLOY=1 without nearby negation ({hits[0]!r})"
            )
        else:
            pass_(f"{label} does not instruct a second wipe")

    check_complete_range(
        "glossary Redeploy gate", glossary, executed["prdCompleteRange"]
    )
    check_complete_range(
        "Phase 7 roadmap row", roadmap_row, executed["prdCompleteRange"]
    )

    pointer_ok(".env.sepolia.example", env_text)
    pointer_ok("glossary Redeploy gate", glossary)
    pointer_ok("Phase 7 roadmap row", roadmap_row)

    # README step numbers cited from summaries must match the declared mapping.
    readme_by_id = {a["id"]: a.get("readme") for a in actions}
    for label, text in (
        (".env.sepolia.example", env_text),
        ("glossary Redeploy gate", glossary),
        ("Phase 7 roadmap row", roadmap_row),
    ):
        for m in re.finditer(r"README step (\d+[a-z]?)", text):
            cited = m.group(1)
            if cited not in declared_readme:
                fail(f"{label} cites undeclared README step {cited}")
            elif cited == readme_by_id.get("code-gate"):
                pass_(f"{label} README step {cited} matches code-gate")
            else:
                pass_(f"{label} README step {cited} is a declared README step")

    if FAILS:
        print(f"phase7-gate-parity: {FAILS} FAIL(s)", file=sys.stderr)
        return 1
    print("phase7-gate-parity: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
