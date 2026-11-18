#!/usr/bin/env python3
"""Trap Tower level assembler (Run 2).

Joins a candidates file with an autopilot report by candidate ID and
writes the shipped levels.json. Frozen assembly contract (run-ledger.md
Run 2, reconciled plan v1):

- Candidate IDs ``D{door:02d}S{slot}V{variant}`` (e.g. D03S2V1); the
  ``variation`` field holds the same code.
- Selects the FIRST passing variant PER (door, slot), variants ordered
  by variant number ascending. A pass requires ``pass == true`` AND
  ``mode == "game"`` in the autopilot report.
- A door ships iff ALL 5 slots pass; incomplete doors are dropped
  entirely.
- Shipped order = door-major, slot order. Shipped IDs are reassigned
  L001.. sequentially. Palette = door_index (0-based, from the
  candidate door number, NOT the shipped position).
- Asserts geometry identity: shipped geometry == candidate geometry
  except id/palette.
- Writes a mapping report (candidate -> final ID, palette per door,
  input/output shas).
- Deterministic. Refuses to write on ANY inconsistency: report sha
  mismatch, unknown report IDs, candidates missing from the report,
  duplicate candidate IDs, duplicate final IDs, non-multiple-of-5
  shipped counts, unparseable IDs, variation/ID mismatch, palette out
  of range, or a geometry-identity failure.

Usage:
  python3 tools/assemble_levels.py --candidates <candidates.json>
      --report <autopilot-report.json> --out <levels.json>
      --tuning <tuning.json> [--mapping <mapping.json>]

The mapping report defaults to ``<out>.mapping.json``.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ID_RE = re.compile(r"^D(\d{2})S([1-5])V(\d+)$")
SLOTS_PER_DOOR = 5
SCHEMA_VERSION = 1


def fail(msg):
    print("ERROR: %s" % msg, file=sys.stderr)
    return 2


def sha256_bytes(raw):
    return hashlib.sha256(raw).hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Trap Tower level assembler")
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tuning", required=True)
    ap.add_argument("--mapping", default=None,
                    help="mapping report path (default: <out>.mapping.json)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    cand_path = Path(args.candidates)
    report_path = Path(args.report)
    tuning_path = Path(args.tuning)
    out_path = Path(args.out)
    mapping_path = Path(args.mapping) if args.mapping \
        else Path(str(out_path) + ".mapping.json")

    try:
        cand_raw = cand_path.read_bytes()
        cand_data = json.loads(cand_raw.decode("utf-8"))
    except Exception as exc:
        return fail("cannot load candidates %s: %s" % (cand_path, exc))
    try:
        tuning = json.loads(tuning_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return fail("cannot load tuning %s: %s" % (tuning_path, exc))
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return fail("cannot load autopilot report %s: %s"
                    % (report_path, exc))

    # --- Top-level version checks -------------------------------------
    if cand_data.get("schema_version") != SCHEMA_VERSION:
        return fail("candidates schema_version %r != frozen %d"
                    % (cand_data.get("schema_version"), SCHEMA_VERSION))
    if cand_data.get("tuning_version") != tuning.get("tuning_version"):
        return fail("candidates tuning_version %r != tuning.json %r"
                    % (cand_data.get("tuning_version"),
                       tuning.get("tuning_version")))
    levels = cand_data.get("levels")
    if not isinstance(levels, list) or not levels:
        return fail("candidates file has no levels array")

    n_palettes = len(tuning.get("palettes", []))
    if n_palettes == 0:
        return fail("tuning.json has no palettes")

    # --- Report coverage + sha checks ---------------------------------
    cand_sha = sha256_bytes(cand_raw)
    report_sha = report.get("levels_sha256")
    if report_sha is not None and report_sha != cand_sha:
        return fail("autopilot report levels_sha256 %s != candidates file "
                    "sha256 %s (report is for a different file)"
                    % (report_sha, cand_sha))
    results = report.get("results")
    if not isinstance(results, list):
        return fail("autopilot report has no results array")

    # --- Parse + validate candidates ----------------------------------
    candidates = {}   # id -> level dict
    parsed = {}       # id -> (door, slot, variant)
    for lv in levels:
        if not isinstance(lv, dict):
            return fail("candidate is not an object")
        lid = lv.get("id")
        if not isinstance(lid, str):
            return fail("candidate has non-string id %r" % (lid,))
        if lid in candidates:
            return fail("duplicate candidate id %r" % lid)
        m = ID_RE.match(lid)
        if not m:
            return fail("candidate id %r does not match D{door:02d}S{slot}"
                        "V{variant}" % lid)
        door, slot, variant = int(m.group(1)), int(m.group(2)), \
            int(m.group(3))
        if lv.get("variation") != lid:
            return fail("candidate %s: variation %r != id (frozen format "
                        "requires variation == id)" % (lid, lv.get("variation")))
        if not isinstance(lv.get("template"), str) or not lv["template"]:
            return fail("candidate %s: empty template" % lid)
        if door < 1 or door - 1 >= n_palettes:
            return fail("candidate %s: door_index %d out of palette range "
                        "0..%d" % (lid, door - 1, n_palettes - 1))
        candidates[lid] = lv
        parsed[lid] = (door, slot, variant)

    # --- Join report by candidate ID ----------------------------------
    verdicts = {}     # id -> (pass, mode)
    for r in results:
        if not isinstance(r, dict) or "id" not in r:
            return fail("autopilot report result is not an object with id")
        rid = r["id"]
        if rid not in candidates:
            return fail("autopilot report lists unknown id %r (not in "
                        "candidates file)" % (rid,))
        if rid in verdicts:
            return fail("autopilot report lists id %r twice" % (rid,))
        verdicts[rid] = (bool(r.get("pass")), str(r.get("mode", "")))
    missing = sorted(set(candidates) - set(verdicts))
    if missing:
        return fail("autopilot report does not cover %d candidate(s): %s "
                    "(run the autopilot on the whole candidates file)"
                    % (len(missing), ", ".join(missing[:10])))

    # --- Select first passing variant per (door, slot) ----------------
    grouped = {}      # (door, slot) -> [(variant, id)]
    for lid, (door, slot, variant) in parsed.items():
        grouped.setdefault((door, slot), []).append((variant, lid))
    for key in grouped:
        grouped[key].sort()

    doors = sorted({door for (door, _slot) in grouped})
    selected = {}     # (door, slot) -> id
    dropped_doors = {}  # door -> [failed slots]
    for door in doors:
        failed_slots = []
        for slot in range(1, SLOTS_PER_DOOR + 1):
            picked = None
            for _variant, lid in grouped.get((door, slot), []):
                passed, mode = verdicts[lid]
                if passed and mode == "game":
                    picked = lid
                    break
            if picked is None:
                failed_slots.append(slot)
            else:
                selected[(door, slot)] = picked
        if failed_slots:
            dropped_doors[door] = failed_slots
            for slot in range(1, SLOTS_PER_DOOR + 1):
                selected.pop((door, slot), None)

    shipped_doors = [d for d in doors if d not in dropped_doors]
    if not shipped_doors:
        return fail("no complete door: every door is missing a passing "
                    "variant for at least one slot; nothing to ship")

    # --- Build shipped levels (ID + palette reassignment only) --------
    shipped = []
    mapping = []
    seq = 0
    for door in shipped_doors:
        for slot in range(1, SLOTS_PER_DOOR + 1):
            lid = selected[(door, slot)]
            seq += 1
            final_id = "L%03d" % seq
            cand = candidates[lid]
            out_level = dict(cand)
            out_level["id"] = final_id
            out_level["palette"] = door - 1
            # Geometry identity: everything except id/palette identical.
            for key, value in cand.items():
                if key in ("id", "palette"):
                    continue
                if out_level[key] != value:
                    return fail("geometry identity failure for %s -> %s "
                                "(field %r changed)" % (lid, final_id, key))
            if set(out_level) != set(cand):
                return fail("geometry identity failure for %s -> %s "
                            "(field set changed)" % (lid, final_id))
            shipped.append(out_level)
            mapping.append({"candidate_id": lid, "final_id": final_id,
                            "door": door, "slot": slot,
                            "variant": parsed[lid][2],
                            "template": cand["template"],
                            "palette": door - 1})
    final_ids = [lv["id"] for lv in shipped]
    if len(set(final_ids)) != len(final_ids):
        return fail("duplicate final IDs after reassignment (internal error)")
    if len(shipped) % SLOTS_PER_DOOR != 0:
        return fail("shipped count %d is not a multiple of %d"
                    % (len(shipped), SLOTS_PER_DOOR))

    out_data = {"schema_version": SCHEMA_VERSION,
                "tuning_version": tuning["tuning_version"],
                "levels": shipped}
    out_text = json.dumps(out_data, indent=1, sort_keys=True) + "\n"
    out_sha = sha256_bytes(out_text.encode("utf-8"))

    mapping_data = {
        "candidates_path": str(cand_path),
        "candidates_sha256": cand_sha,
        "candidates_count": len(levels),
        "report_path": str(report_path),
        "report_sha256": report_sha,
        "tuning_path": str(tuning_path),
        "output_path": str(out_path),
        "output_sha256": out_sha,
        "doors_shipped": shipped_doors,
        "doors_dropped": {str(d): slots
                          for d, slots in sorted(dropped_doors.items())},
        "palette_per_door": {str(d): d - 1 for d in shipped_doors},
        "shipped_count": len(shipped),
        "mapping": mapping,
    }
    mapping_text = json.dumps(mapping_data, indent=1, sort_keys=True) + "\n"

    out_path.parent.mkdir(parents=True, exist_ok=True)
    mapping_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out_text, encoding="utf-8")
    mapping_path.write_text(mapping_text, encoding="utf-8")

    if not args.quiet:
        print("assemble_levels.py: %d candidates -> %d shipped "
              "(%d doors)" % (len(levels), len(shipped), len(shipped_doors)))
        print("  doors shipped: %s"
              % ", ".join("D%02d" % d for d in shipped_doors))
        if dropped_doors:
            print("  doors dropped (incomplete): %s"
                  % ", ".join("D%02d slots %s" % (d, slots)
                              for d, slots in sorted(dropped_doors.items())))
        print("  output: %s (sha256 %s)" % (out_path, out_sha))
        print("  mapping: %s" % mapping_path)
        if len(shipped_doors) < 40:
            print("  WARNING: only %d complete doors (< 40-door minimum); "
                  "verification must judge the count"
                  % len(shipped_doors), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
