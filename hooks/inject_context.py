#!/usr/bin/env python3
"""
Shared lifecycle hook for rex-agent.nvim.
Reads live Neovim editor state from $NVIM_EDITOR_STATE and injects it as
context for Antigravity (`agy` PreInvocation) or Claude Code (`claude` UserPromptSubmit).

Deduplicates per conversation/session so repeated PreInvocation calls inside
a multi-tool turn do not spam duplicate system messages.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile


def pid_is_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def read_stdin_json():
    try:
        raw = sys.stdin.read()
        if not raw or not raw.strip():
            return {}
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def safe_cache_key(value):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value or "default"))[:80]


def format_path_for_cwd(state, agent_cwd):
    abs_file = state.get("absFile") or state.get("file") or ""
    if not abs_file:
        return ""
    if agent_cwd and os.path.isabs(abs_file):
        try:
            rel = os.path.relpath(abs_file, agent_cwd)
            if not rel.startswith(".."):
                return rel
        except ValueError:
            pass
    return state.get("file") or abs_file


def format_context(state, agent_cwd):
    file_path = format_path_for_cwd(state, agent_cwd)
    if not file_path:
        return ""

    line = state.get("line")
    col = state.get("col")
    filetype = state.get("filetype") or ""
    selection = state.get("selection")

    header = f"Active Neovim buffer: `{file_path}`"
    if isinstance(line, int) and line > 0:
        if isinstance(col, int) and col > 0:
            header += f" (cursor at line {line}, col {col})"
        else:
            header += f" (cursor at line {line})"

    parts = [header]

    if isinstance(selection, dict):
        start_line = selection.get("startLine")
        end_line = selection.get("endLine")
        text = selection.get("text")
        truncated = bool(selection.get("truncated"))

        if isinstance(start_line, int) and isinstance(end_line, int):
            if start_line == end_line:
                range_label = f"line {start_line}"
            else:
                range_label = f"lines {start_line}-{end_line}"
        else:
            range_label = "selection"

        if isinstance(text, str) and text != "":
            # Choose a fence longer than any backtick run inside the selection.
            fence = "```"
            while fence in text:
                fence += "`"
            parts.append(f"Selected {range_label}:\n{fence}{filetype}\n{text}\n{fence}")
        elif truncated:
            parts.append(
                f"Selected {range_label} (selection too large to inline; read the file lines directly)."
            )

    return "\n".join(parts)


def compute_fingerprint(state):
    selection = state.get("selection")
    sel_key = None
    if isinstance(selection, dict):
        sel_key = {
            "startLine": selection.get("startLine"),
            "endLine": selection.get("endLine"),
            "text": selection.get("text"),
            "truncated": bool(selection.get("truncated")),
        }
    canonical = json.dumps(
        {
            "absFile": state.get("absFile") or state.get("file"),
            "line": state.get("line"),
            "selection": sel_key,
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def check_and_update_dedup(provider, session_id, fingerprint):
    cache_dir = tempfile.gettempdir()
    cache_path = os.path.join(
        cache_dir, f"rex-agent-last-{safe_cache_key(provider)}-{safe_cache_key(session_id)}.hash"
    )
    try:
        with open(cache_path, "r", encoding="utf-8") as fh:
            if fh.read().strip() == fingerprint:
                return False
    except FileNotFoundError:
        pass
    except Exception:
        pass

    try:
        tmp_path = f"{cache_path}.{os.getpid()}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as fh:
            fh.write(fingerprint)
        os.replace(tmp_path, cache_path)
    except Exception:
        pass

    return True


def main():
    parser = argparse.ArgumentParser(description="Inject active Neovim context into AI CLI agents.")
    parser.add_argument("--provider", choices=["agy", "claude"], required=True)
    parser.add_argument("--no-dedup", action="store_true", help="Always emit context even if unchanged")
    args = parser.parse_args()

    state_path = os.environ.get("NVIM_EDITOR_STATE", "").strip()
    if not state_path:
        print("{}")
        return 0

    state = read_json_file(state_path)
    if not state or not pid_is_alive(state.get("pid")):
        print("{}")
        return 0

    payload = read_stdin_json()
    agent_cwd = payload.get("cwd") or (
        payload.get("workspacePaths")[0]
        if isinstance(payload.get("workspacePaths"), list) and payload.get("workspacePaths")
        else None
    )

    context_text = format_context(state, agent_cwd)
    if not context_text:
        print("{}")
        return 0

    session_id = (
        payload.get("conversationId")
        if args.provider == "agy"
        else payload.get("session_id")
    ) or state_path

    if not args.no_dedup:
        fingerprint = compute_fingerprint(state)
        if not check_and_update_dedup(args.provider, session_id, fingerprint):
            print("{}")
            return 0

    if args.provider == "agy":
        output = {
            "injectSteps": [
                {
                    "systemMessage": {
                        "systemMessage": context_text,
                    }
                }
            ]
        }
    else:
        output = {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context_text,
            }
        }

    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
