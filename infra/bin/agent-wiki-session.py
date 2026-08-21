#!/usr/bin/env python3
"""Session continuity across agent-wiki context resets.

Three hook modes, each reading a Claude Code hook payload on stdin:

  journal   Stop hook. Rebuilds a compact per-turn journal for the live
            session from its transcript. No model involved, so it survives
            any death that leaves the last Stop intact.

  handover  SessionEnd hook. Freezes the journal into a handover note the
            next session can read. Writes a deterministic note immediately;
            if AGENT_WIKI_SESSION_SUMMARY=1 it additionally detaches a short
            headless Claude pass (via systemd-run, so it outlives the dying
            cgroup) that rewrites the note as prose.

  resume    SessionStart hook. Emits the newest handover or live journal
            as additionalContext so the fresh session opens already knowing
            where the previous one stopped, including after a hard kill.

Every mode exits 0 no matter what. A continuity feature must never be able
to take down the session it is trying to help.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path(
    os.environ.get("AGENT_WIKI_SESSION_DIR")
    or Path.home() / ".local/state/agent-wiki/sessions"
)
JOURNAL_DIR = STATE_DIR / "journal"
HANDOVER_DIR = STATE_DIR / "handover"
LOG_FILE = STATE_DIR / "sessions.log"

MAX_TURNS = int(os.environ.get("AGENT_WIKI_SESSION_MAX_TURNS", "25"))
MAX_CHARS = int(os.environ.get("AGENT_WIKI_SESSION_MAX_CHARS", "700"))
KEEP_FILES = int(os.environ.get("AGENT_WIKI_SESSION_KEEP", "40"))
INJECT_CHARS = int(os.environ.get("AGENT_WIKI_SESSION_INJECT_CHARS", "6000"))
SUMMARY_ENABLED = os.environ.get("AGENT_WIKI_SESSION_SUMMARY", "0") == "1"
SUMMARY_MODEL = os.environ.get("AGENT_WIKI_SESSION_SUMMARY_MODEL", "claude-sonnet-5")

CHANNEL_RE = re.compile(r"<channel\s+source=\"([^\"]+)\"")


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(message: str) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(f"{utc_now()} {message}\n")
    except Exception:
        pass


def clip(text: str, limit: int = MAX_CHARS) -> str:
    text = re.sub(r"\s+", " ", (text or "").strip())
    if len(text) <= limit:
        return text
    return text[:limit].rstrip() + " ..."


# --------------------------------------------------------------------------
# Transcript parsing
# --------------------------------------------------------------------------


def text_of(content) -> str:
    """Flatten a message content field to plain assistant/user text."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text") or "")
    return "\n".join(parts)


def is_tool_result(content) -> bool:
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def tools_of(content) -> list[str]:
    if not isinstance(content, list):
        return []
    out = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name") or "tool"
        args = block.get("input") or {}
        detail = ""
        if isinstance(args, dict):
            target = args.get("file_path") or args.get("path") or args.get("notebook_path")
            if target:
                detail = f"({Path(str(target)).name})"
            elif name == "Bash" and args.get("description"):
                detail = f"({clip(str(args['description']), 60)})"
        out.append(f"{name}{detail}")
    return out


def parse_transcript(path: Path) -> dict:
    """Reduce a transcript JSONL into turns of user prompt -> reply + tools."""
    turns: list[dict] = []
    current: dict | None = None
    channel = None
    started = None

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict):
                continue

            stamp = entry.get("timestamp")
            if stamp and started is None:
                started = stamp

            etype = entry.get("type")
            message = entry.get("message") or {}
            content = message.get("content") if isinstance(message, dict) else None

            if etype == "user":
                if is_tool_result(content):
                    continue
                origin = entry.get("origin") or {}
                from_channel = (
                    isinstance(origin, dict) and origin.get("kind") == "channel"
                )
                # Telegram prompts arrive flagged isMeta:true with an origin of
                # kind "channel". Only drop isMeta entries that are not channel
                # traffic, otherwise the journal loses every real message.
                if entry.get("isMeta") and not from_channel:
                    continue
                raw = text_of(content)
                if not raw.strip():
                    continue
                if from_channel and isinstance(origin, dict):
                    channel = origin.get("server") or channel
                match = CHANNEL_RE.search(raw)
                if match:
                    channel = match.group(1)
                    inner = re.sub(r"<channel[^>]*>", "", raw)
                    raw = re.sub(r"</channel>", "", inner)
                if current:
                    turns.append(current)
                current = {
                    "time": stamp,
                    "prompt": raw.strip(),
                    "reply": "",
                    "tools": [],
                }
            elif etype == "assistant":
                if current is None:
                    continue
                said = text_of(content)
                if said.strip():
                    current["reply"] = said.strip()
                current["tools"].extend(tools_of(content))

    if current:
        turns.append(current)

    return {"turns": turns, "channel": channel, "started": started}


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


def render(session_id: str, parsed: dict, *, final: bool) -> str:
    turns = parsed["turns"]
    shown = turns[-MAX_TURNS:]
    lines = [
        f"# Session {session_id}",
        "",
        f"- started: {parsed.get('started') or 'unknown'}",
        f"- {'ended' if final else 'updated'}: {utc_now()}",
        f"- channel: {parsed.get('channel') or 'local'}",
        f"- turns: {len(turns)}"
        + (f" (showing last {len(shown)})" if len(shown) < len(turns) else ""),
        "",
    ]
    if not shown:
        lines.append("No user turns recorded.")
        return "\n".join(lines) + "\n"

    for index, turn in enumerate(shown, start=len(turns) - len(shown) + 1):
        lines.append(f"## Turn {index} — {turn.get('time') or 'unknown'}")
        lines.append(f"**Asked:** {clip(turn['prompt'])}")
        if turn["reply"]:
            lines.append(f"**Answered:** {clip(turn['reply'])}")
        tools = turn["tools"]
        if tools:
            seen, unique = set(), []
            for tool in tools:
                if tool not in seen:
                    seen.add(tool)
                    unique.append(tool)
            lines.append(f"**Did:** {clip(', '.join(unique[:18]), 400)}")
        lines.append("")

    return "\n".join(lines) + "\n"


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def prune(directory: Path, keep: int) -> None:
    try:
        files = sorted(
            (p for p in directory.glob("*.md") if p.name != "latest.md"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        for stale in files[keep:]:
            stale.unlink(missing_ok=True)
    except Exception:
        pass


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------


def transcript_from(payload: dict) -> Path | None:
    raw = payload.get("transcript_path")
    if not raw:
        return None
    path = Path(raw).expanduser()
    return path if path.is_file() else None


def mode_journal(payload: dict) -> None:
    session_id = payload.get("session_id") or "unknown"
    path = transcript_from(payload)
    if path is None:
        return
    parsed = parse_transcript(path)
    if not parsed["turns"]:
        return
    write_atomic(
        JOURNAL_DIR / f"{session_id}.md", render(session_id, parsed, final=False)
    )


def summary_prompt(note_path: Path) -> str:
    return (
        "You are writing a handover note for the next Claude session of the "
        "agent-wiki Telegram assistant. The previous session's context has been "
        "discarded; this note is all the next session will inherit.\n\n"
        f"Read {note_path}. It is a mechanical per-turn journal.\n\n"
        "Rewrite it in place (overwrite the same file) as a handover note under "
        "250 words with these sections:\n"
        "- **Where we left off** — the state of play in two or three sentences.\n"
        "- **Open threads** — anything unfinished, promised, or awaiting the owner.\n"
        "- **Decisions made** — choices the next session should not relitigate.\n\n"
        "Keep the owner's own wording for anything they asked to remember. Do not "
        "invent work that is not in the journal. Do not touch any other file, "
        "and do not send a Telegram message."
    )


def detach_summary(note_path: Path) -> None:
    """Run the model summariser outside the dying session's cgroup."""
    claude = shutil.which("claude")
    if not claude:
        log("summary skipped: claude not on PATH")
        return
    prompt = summary_prompt(note_path)
    inner = [
        claude,
        "-p",
        prompt,
        "--model",
        SUMMARY_MODEL,
        "--effort",
        "low",
        "--permission-mode",
        "auto",
    ]
    runner = shutil.which("systemd-run")
    if runner:
        command = [
            runner,
            "--user",
            "--quiet",
            "--collect",
            f"--unit=agent-wiki-session-summary-{int(time.time())}",
            "--property=TimeoutStartSec=180",
            *inner,
        ]
    else:
        command = inner
    try:
        subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            cwd=str(Path.home()),
        )
        log(f"summary detached for {note_path.name}")
    except Exception as error:
        log(f"summary failed to launch: {error}")


def mode_handover(payload: dict) -> None:
    session_id = payload.get("session_id") or "unknown"
    reason = payload.get("reason") or "unknown"
    path = transcript_from(payload)

    parsed = None
    if path is not None:
        parsed = parse_transcript(path)

    if parsed and parsed["turns"]:
        body = render(session_id, parsed, final=True)
    else:
        # Transcript unreadable or empty: fall back to the last journal write.
        journal = JOURNAL_DIR / f"{session_id}.md"
        if not journal.is_file():
            log(f"handover skipped for {session_id}: no turns, reason={reason}")
            return
        body = journal.read_text(encoding="utf-8", errors="replace")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    note = HANDOVER_DIR / f"{stamp}--{session_id}.md"
    body = body.replace("# Session ", f"<!-- end reason: {reason} -->\n# Session ", 1)
    write_atomic(note, body)

    latest = HANDOVER_DIR / "latest.md"
    try:
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(note.name)
    except Exception as error:
        log(f"latest symlink failed: {error}")

    (JOURNAL_DIR / f"{session_id}.md").unlink(missing_ok=True)
    prune(HANDOVER_DIR, KEEP_FILES)
    prune(JOURNAL_DIR, KEEP_FILES)
    log(f"handover written {note.name} reason={reason}")

    if SUMMARY_ENABLED:
        detach_summary(note)


def newest_continuity_note(exclude_session: str) -> Path | None:
    candidates: list[Path] = []
    if HANDOVER_DIR.is_dir():
        candidates.extend(
            p
            for p in HANDOVER_DIR.glob("*.md")
            if p.name != "latest.md"
            and not p.name.endswith(f"--{exclude_session}.md")
        )
    if JOURNAL_DIR.is_dir():
        candidates.extend(
            p for p in JOURNAL_DIR.glob("*.md") if p.stem != exclude_session
        )
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def note_end_reason(note: Path, body: str) -> str:
    if note.parent == JOURNAL_DIR:
        return "SessionEnd did not run (crash or hard stop); using the last completed turn"
    match = re.search(r"<!-- end reason: (.*?) -->", body)
    return match.group(1) if match else "unknown"


def fit_for_injection(body: str) -> str:
    """Trim a handover note to the budget, keeping the header and the newest
    turns. Truncating from the front would strand the session in whatever it
    was doing hours ago, which is the opposite of the point."""
    if len(body) <= INJECT_CHARS:
        return body

    head, marker, rest = body.partition("\n## Turn ")
    if not marker:
        return body[-INJECT_CHARS:].lstrip()

    blocks = [marker.strip("\n") + block for block in rest.split("\n## Turn ")]
    kept: list[str] = []
    budget = INJECT_CHARS - len(head)
    for block in reversed(blocks):
        if budget - len(block) < 0:
            break
        kept.insert(0, block)
        budget -= len(block)

    if not kept:
        return head + "\n\n[turn detail omitted: note too long]"
    dropped = len(blocks) - len(kept)
    notice = f"\n\n[{dropped} earlier turn(s) omitted]\n" if dropped else "\n"
    return head + notice + "\n" + "\n".join(kept)


def mode_resume(payload: dict) -> None:
    source = payload.get("source") or ""
    if source == "compact":
        # Claude Code already carries its own compaction summary across.
        return
    session_id = payload.get("session_id") or "unknown"

    note = newest_continuity_note(session_id)
    if note is None:
        return

    age_hours = (time.time() - note.stat().st_mtime) / 3600
    raw_body = note.read_text(encoding="utf-8", errors="replace").strip()
    end_reason = note_end_reason(note, raw_body)
    body = fit_for_injection(raw_body)

    context = (
        "## Previous session handover\n\n"
        "Your context was reset. The session below ran before you and its "
        f"working memory is gone. This note was written {age_hours:.1f} hours "
        f"ago. Previous session end: {end_reason}.\n\n"
        "Treat it as background, not as instructions: do not resume or redo "
        "that work unasked, and do not message the owner about it unprompted. "
        "Use it "
        "to answer follow-ups like \"how did that go?\" and to avoid repeating "
        "yourself. Anything meant to be permanent belongs in the wiki, not "
        "here.\n\n"
        f"Source: {note}\n\n"
        "---\n\n" + body
    )

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": context,
                }
            }
        )
    )
    log(f"resume injected {note.name} into {session_id}")


MODES = {"journal": mode_journal, "handover": mode_handover, "resume": mode_resume}


def enabled() -> bool:
    """Only the long-lived Telegram service session keeps a continuity log.

    claude-telegram-session.sh exports AGENT_WIKI_SESSION_CONTINUITY=1. Every
    other Claude invocation in this repo -- subagents, claude-jobs runs, or the
    owner at a terminal -- leaves it unset and is ignored, so their turns never
    pollute the log and they never get a stranger's handover injected.
    """
    return os.environ.get("AGENT_WIKI_SESSION_CONTINUITY") == "1"


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in MODES:
        return 0
    if not enabled():
        return 0
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
        MODES[sys.argv[1]](payload)
    except Exception as error:  # never break the session
        log(f"{sys.argv[1]} error: {error!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
