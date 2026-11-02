"""Tamper-evident deployment ledger.

Every pipeline run appends one JSON line. Each entry stores the SHA-256 of the
build's evidence file and the hash of the previous entry, forming a hash chain.

What each layer detects
-----------------------
* Hash chain: editing, re-ordering or removing an entry in the MIDDLE of the file
  breaks the chain at that point.
* HMAC (LEDGER_KEY, Jenkins credential `ledger-hmac-key`): rewriting the whole file
  and recomputing every hash is detected unless the attacker also has the key.
* External anchors: a chain cannot reveal that its NEWEST entries were deleted
  (a shorter chain is still a valid chain). After every entry is written, its
  (seq, hash, hmac) is appended to stores outside Jenkins — an append-only file on
  the deployment server (chattr +a) and optionally a Git repository with force-push
  disabled. `verify --anchors` then fails if an anchored entry is missing or differs.

Residual risk: an attacker who controls Jenkins AND every anchor store (or root on
the server, which can lift chattr +a) can still rewrite history. Anchors raise the
bar from "compromise one system" to "compromise several independent ones".
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path

try:  # fcntl is POSIX-only; the ledger also works (unlocked) elsewhere
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None

GENESIS = "0" * 64
LEDGER_FIELDS = ("seq", "timestamp", "build", "commit", "app_tag", "gate_decision", "risk_score",
                 "deploy_status", "pipeline_result", "images", "evidence_sha256", "prev_hash")


def canonical(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _entry_hash(entry: dict) -> str:
    body = {k: entry.get(k) for k in LEDGER_FIELDS}
    return hashlib.sha256(canonical(body)).hexdigest()


def _sign(entry_hash: str, key: str | None) -> str | None:
    if not key:
        return None
    return hmac.new(key.encode(), entry_hash.encode(), hashlib.sha256).hexdigest()


def read(path: Path) -> list[dict]:
    path = Path(path)
    if not path.exists():
        return []
    entries = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def append(path: Path, record: dict, key: str | None = None) -> dict:
    """Append a record; returns the full stored entry (with seq, prev_hash, hash)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+", encoding="utf-8") as fh:
        if fcntl:
            fcntl.flock(fh, fcntl.LOCK_EX)
        fh.seek(0)
        lines = [ln for ln in fh.read().splitlines() if ln.strip()]
        last = json.loads(lines[-1]) if lines else None
        entry = {k: record.get(k) for k in LEDGER_FIELDS}
        entry["seq"] = (last["seq"] + 1) if last else 1
        entry["timestamp"] = record.get("timestamp") or dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        entry["prev_hash"] = last["hash"] if last else GENESIS
        entry["hash"] = _entry_hash(entry)
        sig = _sign(entry["hash"], key)
        if sig:
            entry["hmac"] = sig
        fh.seek(0, os.SEEK_END)
        fh.write(json.dumps(entry, sort_keys=True) + "\n")
        fh.flush()
        if fcntl:
            fcntl.flock(fh, fcntl.LOCK_UN)
    return entry


def anchor_line(entry: dict) -> str:
    """The record written to external anchor stores for one ledger entry."""
    anchor = {"seq": entry["seq"], "hash": entry["hash"], "build": entry.get("build"),
              "anchored_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")}
    if entry.get("hmac"):
        anchor["hmac"] = entry["hmac"]
    return json.dumps(anchor, sort_keys=True)


def read_anchors(path: Path) -> tuple[list[dict], list[str]]:
    """Parse an anchor file (JSON lines). Unparseable lines are reported, not fatal."""
    anchors, bad = [], []
    path = Path(path)
    if not path.exists():
        return anchors, bad
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            a = json.loads(line)
            int(a["seq"]), str(a["hash"])
            anchors.append(a)
        except (ValueError, KeyError, TypeError):
            bad.append(f"anchor line {i} is not a valid anchor record")
    return anchors, bad


def check_anchors(entries: list[dict], anchors: list[dict], key: str | None) -> tuple[list[str], dict]:
    """Compare the ledger with external anchors. Returns (problems, info)."""
    problems: list[str] = []
    by_seq = {e.get("seq"): e for e in entries}
    for a in anchors:
        seq = int(a["seq"])
        if key and a.get("hmac"):
            if not hmac.compare_digest(_sign(a["hash"], key), a["hmac"]):
                problems.append(f"anchor for entry #{seq} has an invalid HMAC (forged anchor?)")
                continue
        e = by_seq.get(seq)
        if e is None:
            problems.append(f"entry #{seq} was anchored externally on {a.get('anchored_at', '?')} "
                            f"but is missing from the ledger (ledger has {len(entries)} entries) – history was truncated or deleted")
        elif e.get("hash") != a["hash"]:
            problems.append(f"entry #{seq} differs from its external anchor – the entry was rewritten, "
                            "or history was truncated and new entries now reuse its number")
    anchored_through = max((int(a["seq"]) for a in anchors), default=0)
    info = {"anchors": len(anchors), "anchored_through": anchored_through,
            "unanchored_entries": [e["seq"] for e in entries if e.get("seq", 0) > anchored_through]}
    return problems, info


def verify(path: Path, key: str | None = None, evidence: Path | None = None,
           anchors: Path | None = None) -> dict:
    """Walk the chain (and compare with external anchors when given).

    Returns {"ok": bool, "entries": n, "problems": [...], "head": hash, ...}."""
    problems: list[str] = []
    try:
        entries = read(path)
    except ValueError as exc:
        return {"ok": False, "entries": 0, "problems": [f"ledger is not valid JSON lines: {exc}"], "head": None}
    prev = GENESIS
    for i, e in enumerate(entries, start=1):
        if e.get("seq") != i:
            problems.append(f"line {i}: sequence number {e.get('seq')} (expected {i}) – entry removed or re-ordered")
        if e.get("prev_hash") != prev:
            problems.append(f"line {i} (seq {e.get('seq')}): prev_hash does not match previous entry – chain broken")
        if _entry_hash(e) != e.get("hash"):
            problems.append(f"line {i} (seq {e.get('seq')}): content was modified after it was recorded")
        if key:
            expected = _sign(e.get("hash", ""), key)
            if not e.get("hmac"):
                problems.append(f"line {i} (seq {e.get('seq')}): missing HMAC signature")
            elif not hmac.compare_digest(expected, e["hmac"]):
                problems.append(f"line {i} (seq {e.get('seq')}): HMAC signature invalid")
        prev = e.get("hash")
    result = {"ok": not problems, "entries": len(entries), "problems": problems,
              "head": entries[-1]["hash"] if entries else None}
    if anchors is not None:
        anchor_list, bad = read_anchors(anchors)
        a_problems, info = check_anchors(entries, anchor_list, key)
        result["problems"] += bad + a_problems
        result["ok"] = not result["problems"]
        result["anchor_check"] = info
    if evidence:
        digest = sha256_file(evidence)
        match = [e for e in entries if e.get("evidence_sha256") == digest]
        result["evidence_sha256"] = digest
        result["evidence_recorded"] = bool(match)
        if not match:
            result["ok"] = False
            result["problems"].append(f"evidence file {Path(evidence).name} (sha256 {digest[:16]}…) is not in the ledger")
        else:
            result["evidence_seq"] = match[-1]["seq"]
    return result
