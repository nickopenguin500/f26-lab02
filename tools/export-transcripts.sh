#!/usr/bin/env bash
# export-transcripts.sh: Export Antigravity IDE agent conversation transcripts into
# transcripts/ in this repository as Markdown for local TA review.
#
# What it does:
#   1. Searches local Antigravity storage directories and SQLite databases
#      (e.g., ~/.gemini/antigravity/brain/ and ~/Library/Application Support/Antigravity/ on macOS).
#   2. Identifies conversation sessions associated with this repository.
#   3. Exports the full conversation history—including user prompts, model reasoning,
#      background tool calls, arguments, and command outputs—into structured Markdown files.
#   4. Also preserves the raw JSONL session logs in transcripts/ for complete reproducibility.
#
# Note on git:
#   Do not commit or push the transcripts in this lab. Your fork is public, and
#   transcripts are for course staff only. .gitignore keeps transcripts/ out of git.
#   You will show the TA the exported files on your machine at recitation.
#
# Usage (from anywhere inside your course repository):
#   ./tools/export-transcripts.sh [conversation_id]
#
# Options:
#   [conversation_id]  Optional specific conversation ID to export. If omitted,
#                      all sessions belonging to this repository are exported.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: this is not a git repository. Run the script from inside your course repository." >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required to parse and export Antigravity transcripts." >&2
    exit 1
}

SPECIFIC_CONV_ID="${1:-}"

export REPO_ROOT
export SPECIFIC_CONV_ID

python3 - << 'EOF'
import json
import os
import re
import sys
import glob
import shutil
import sqlite3
from pathlib import Path
from datetime import datetime

repo_root = os.path.realpath(os.environ.get("REPO_ROOT", "."))
specific_conv_id = os.environ.get("SPECIFIC_CONV_ID", "").strip()
dest_dir = os.path.join(repo_root, "transcripts")
os.makedirs(dest_dir, exist_ok=True)

# Candidate Antigravity storage paths on macOS / Linux / Windows
home = Path.home()
candidate_roots = [
    os.environ.get("ANTIGRAVITY_DATA_DIR"),
    os.environ.get("GEMINI_DATA_DIR"),
    str(home / ".gemini" / "antigravity"),
    str(home / "Library" / "Application Support" / "Antigravity"),
    str(home / "Library" / "Application Support" / "Code"),
    str(home / "Library" / "Application Support" / "Google" / "Antigravity"),
    str(home / ".config" / "antigravity"),
    str(home / ".config" / "Code"),
    os.path.expandvars(r"%APPDATA%\Antigravity") if os.name == "nt" else None,
]
candidate_roots = [p for p in candidate_roots if p and os.path.exists(p)]

def find_brain_directories():
    """Find all conversation brain directories containing logs."""
    conv_dirs = {}
    for root in candidate_roots:
        # Check <root>/brain/<conv_id>
        brain_path = Path(root) / "brain"
        if brain_path.is_dir():
            for conv_dir in brain_path.iterdir():
                if conv_dir.is_dir():
                    log_file = conv_dir / ".system_generated" / "logs" / "transcript_full.jsonl"
                    if not log_file.is_file():
                        log_file = conv_dir / ".system_generated" / "logs" / "transcript.jsonl"
                    if log_file.is_file():
                        conv_dirs[conv_dir.name] = {
                            "conv_id": conv_dir.name,
                            "log_file": log_file,
                            "conv_dir": conv_dir,
                            "mtime": log_file.stat().st_mtime
                        }
        
        # Direct check for logs in root
        for log_file in Path(root).glob("**/logs/transcript_full.jsonl"):
            conv_id = log_file.parent.parent.parent.name
            if conv_id not in conv_dirs:
                conv_dirs[conv_id] = {
                    "conv_id": conv_id,
                    "log_file": log_file,
                    "conv_dir": log_file.parent.parent.parent,
                    "mtime": log_file.stat().st_mtime
                }
    return conv_dirs

def query_sqlite_storage():
    """Check VS Code / Antigravity SQLite databases for conversation records if available."""
    sqlite_data = {}
    for root in candidate_roots:
        vscdb_files = list(Path(root).glob("**/state.vscdb"))
        for db_file in vscdb_files:
            try:
                conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
                cursor = conn.cursor()
                cursor.execute("SELECT key, value FROM ItemTable WHERE key LIKE '%antigravity%' OR key LIKE '%chat%' OR key LIKE '%conversation%'")
                for key, val in cursor.fetchall():
                    sqlite_data[key] = val
                conn.close()
            except Exception:
                continue
    return sqlite_data

def is_conversation_for_repo(conv_info, target_repo):
    """Check if a conversation session operated on the target repository."""
    log_file = conv_info["log_file"]
    target_repo_norm = os.path.normpath(target_repo)
    target_repo_name = os.path.basename(target_repo_norm)

    try:
        with open(log_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if target_repo_norm in line or f"/{target_repo_name}/" in line or f"/{target_repo_name}\"" in line:
                    return True
    except Exception:
        pass
    return False

def format_timestamp(ts_str):
    if not ts_str:
        return ""
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        return str(ts_str)

def parse_user_content(content):
    if not content:
        return "", ""
    user_req_match = re.search(r'<USER_REQUEST>(.*?)</USER_REQUEST>', content, re.DOTALL)
    if user_req_match:
        user_prompt = user_req_match.group(1).strip()
        metadata = content.replace(user_req_match.group(0), "").strip()
        return user_prompt, metadata
    return content.strip(), ""

def format_tool_args(tool_name, args):
    if not args:
        return "*(No arguments provided)*"
    
    if tool_name == "run_command":
        cmd = args.get("CommandLine", "")
        cwd = args.get("Cwd", "")
        action = args.get("toolAction", "")
        summary = args.get("toolSummary", "")
        res = []
        if action or summary:
            res.append(f"**Action**: {action or summary}")
        if cwd:
            res.append(f"**Working Directory**: `{cwd}`")
        res.append(f"**Command**:\n```bash\n{cmd}\n```")
        return "\n".join(res)
    elif tool_name == "replace_file_content":
        target = args.get("TargetFile", "")
        desc = args.get("Description", "")
        instr = args.get("Instruction", "")
        target_content = args.get("TargetContent", "")
        replacement = args.get("ReplacementContent", "")
        start_line = args.get("StartLine", "")
        end_line = args.get("EndLine", "")
        res = [f"**Target File**: `{target}`"]
        if desc or instr:
            res.append(f"**Description**: {desc or instr}")
        if start_line and end_line:
            res.append(f"**Lines**: {start_line} to {end_line}")
        if target_content:
            res.append(f"**Target Content to Replace**:\n````\n{target_content}\n````")
        if replacement:
            res.append(f"**Replacement Content**:\n````\n{replacement}\n````")
        return "\n".join(res)
    elif tool_name == "write_to_file":
        target = args.get("TargetFile", "")
        desc = args.get("Description", "")
        code = args.get("CodeContent", "")
        res = [f"**Target File**: `{target}`"]
        if desc:
            res.append(f"**Description**: {desc}")
        if code:
            res.append(f"**File Content**:\n````\n{code}\n````")
        return "\n".join(res)
    elif tool_name == "view_file":
        path = args.get("AbsolutePath", "")
        s_line = args.get("StartLine", "")
        e_line = args.get("EndLine", "")
        action = args.get("toolAction", "")
        res = [f"**File**: `{path}`"]
        if action:
            res.append(f"**Action**: {action}")
        if s_line or e_line:
            res.append(f"**Lines**: {s_line} - {e_line}")
        return "\n".join(res)
    elif tool_name == "list_dir":
        d_path = args.get("DirectoryPath", "")
        return f"**Directory**: `{d_path}`"
    elif tool_name == "grep_search":
        q = args.get("Query", "")
        p = args.get("SearchPath", "")
        return f"**Search Query**: `{q}` in `{p}`"
    elif tool_name == "find_by_name":
        pat = args.get("Pattern", "")
        d = args.get("SearchDirectory", "")
        return f"**Search Pattern**: `{pat}` in `{d}`"
    else:
        return f"```json\n{json.dumps(args, indent=2)}\n```"

def convert_session_to_markdown(conv_info, repo_path):
    log_file = conv_info["log_file"]
    conv_id = conv_info["conv_id"]

    lines = []
    with open(log_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                lines.append(json.loads(line))
            except Exception:
                continue

    if not lines:
        return None, 0

    start_time = lines[0].get("created_at", "")
    end_time = lines[-1].get("created_at", "")
    total_steps = len(lines)
    user_turns = sum(1 for l in lines if l.get("type") == "USER_INPUT")
    tool_calls_count = sum(len(l.get("tool_calls", [])) for l in lines if "tool_calls" in l)

    md = []
    md.append(f"# Antigravity Session Transcript")
    md.append("")
    md.append(f"| Session Property | Details |")
    md.append(f"| --- | --- |")
    md.append(f"| **Conversation ID** | `{conv_id}` |")
    md.append(f"| **Repository Root** | `{repo_path}` |")
    md.append(f"| **Session Start** | {format_timestamp(start_time)} |")
    md.append(f"| **Session End** | {format_timestamp(end_time)} |")
    md.append(f"| **Total Steps** | {total_steps} |")
    md.append(f"| **User Turns** | {user_turns} |")
    md.append(f"| **Tool Calls** | {tool_calls_count} |")
    md.append(f"| **Log Source** | `{log_file}` |")
    md.append("")
    md.append("---")
    md.append("")

    turn_idx = 0
    i = 0
    while i < len(lines):
        step = lines[i]
        step_idx = step.get("step_index", i)
        s_type = step.get("type", "")
        source = step.get("source", "")
        ts = format_timestamp(step.get("created_at", ""))
        content = step.get("content", "")
        thinking = step.get("thinking", "")
        tool_calls = step.get("tool_calls", [])

        if s_type == "USER_INPUT" or source == "USER_EXPLICIT":
            turn_idx += 1
            user_prompt, metadata = parse_user_content(content)
            md.append(f"## 👤 Turn {turn_idx}: User Input")
            if ts:
                md.append(f"*{ts}* (Step {step_idx})\n")
            md.append(f"{user_prompt}\n")
            if metadata:
                md.append("<details>")
                md.append("<summary>📋 Context & Environment Metadata</summary>\n")
                md.append(f"```text\n{metadata}\n```\n")
                md.append("</details>\n")
            md.append("---")
            md.append("")
            i += 1
            continue

        if s_type == "PLANNER_RESPONSE" or source == "MODEL":
            # Thinking / internal reasoning
            if thinking:
                md.append(f"### 💭 Agent Thinking (Step {step_idx})")
                if ts:
                    md.append(f"*{ts}*\n")
                md.append("<details>")
                md.append("<summary>View Reasoning & Planning</summary>\n")
                md.append(f"{thinking}\n")
                md.append("</details>\n")

            # Tool invocations
            if tool_calls:
                for tc in tool_calls:
                    tc_name = tc.get("name", "tool")
                    tc_args = tc.get("args", {})
                    action_title = tc_args.get("toolAction", tc_args.get("toolSummary", tc_name))
                    md.append(f"### 🛠️ Tool Action: `{tc_name}` — *{action_title}*")
                    if ts:
                        md.append(f"*{ts}* (Step {step_idx})\n")
                    md.append(format_tool_args(tc_name, tc_args))
                    md.append("")

                    # Check next step for corresponding tool output / generic response
                    if i + 1 < len(lines) and lines[i+1].get("type") in ("GENERIC", "TOOL_RESPONSE"):
                        next_step = lines[i+1]
                        next_content = next_step.get("content", "")
                        next_status = next_step.get("status", "DONE")
                        next_ts = format_timestamp(next_step.get("created_at", ""))
                        md.append("<details>")
                        md.append(f"<summary>📥 Tool Output ({tc_name}) — Status: {next_status}</summary>\n")
                        if next_ts:
                            md.append(f"*Result Timestamp: {next_ts}*\n")
                        md.append(f"````text\n{next_content}\n````\n")
                        md.append("</details>\n")
                        i += 1

            # Assistant markdown text
            if content and not tool_calls:
                md.append(f"### 🤖 Agent Response (Step {step_idx})")
                if ts:
                    md.append(f"*{ts}*\n")
                md.append(f"{content}\n")
                md.append("---")
                md.append("")
            i += 1
            continue

        if s_type == "SYSTEM_MESSAGE" or source == "SYSTEM":
            md.append(f"### ⚙️ System Notification (Step {step_idx})")
            if ts:
                md.append(f"*{ts}*\n")
            md.append(f"> {content}\n")
            md.append("")
            i += 1
            continue

        if s_type == "GENERIC":
            md.append(f"### 📝 Output (Step {step_idx})")
            if ts:
                md.append(f"*{ts}*\n")
            md.append("<details>")
            md.append("<summary>View Step Output</summary>\n")
            md.append(f"````text\n{content}\n````\n")
            md.append("</details>\n")
            i += 1
            continue

        i += 1

    return "\n".join(md), total_steps

# Step 1: Discover all conversation sessions
all_conversations = find_brain_directories()

if not all_conversations:
    print(f"No Antigravity conversation sessions found in checked directories:")
    for d in candidate_roots:
        print(f"  - {d}")
    print("\nHave you started an Antigravity session on this machine?")
    sys.exit(1)

# Step 2: Filter matching conversations
matching = {}
if specific_conv_id:
    if specific_conv_id in all_conversations:
        matching[specific_conv_id] = all_conversations[specific_conv_id]
    else:
        print(f"error: Specified conversation ID '{specific_conv_id}' not found.")
        sys.exit(1)
else:
    for cid, info in all_conversations.items():
        if is_conversation_for_repo(info, repo_root):
            matching[cid] = info

# If no direct repo path match was found, pick the most recent conversation(s)
if not matching:
    sorted_all = sorted(all_conversations.values(), key=lambda x: x["mtime"], reverse=True)
    if sorted_all:
        latest = sorted_all[0]
        print(f"Note: No session explicitly referenced '{repo_root}'. Exporting most recent session: {latest['conv_id']}")
        matching[latest["conv_id"]] = latest

# Step 3: Export each matching conversation to Markdown and copy raw logs
exported_files = []
sorted_matching = sorted(matching.values(), key=lambda x: x["mtime"])

for idx, info in enumerate(sorted_matching, start=1):
    cid = info["conv_id"]
    md_content, step_count = convert_session_to_markdown(info, repo_root)
    if not md_content:
        continue

    # Write individual markdown transcript
    out_md_path = os.path.join(dest_dir, f"session_{idx:02d}.md")
    with open(out_md_path, "w", encoding="utf-8") as f:
        f.write(md_content)
    exported_files.append(out_md_path)

    # Also archive raw JSONL log
    raw_dest = os.path.join(dest_dir, f"session_{idx:02d}.full.jsonl")
    try:
        shutil.copy2(info["log_file"], raw_dest)
    except Exception:
        pass

# Create / update primary transcript.md pointing to the latest session
if exported_files:
    latest_md = exported_files[-1]
    main_transcript_path = os.path.join(dest_dir, "transcript.md")
    shutil.copyfile(latest_md, main_transcript_path)

print(f"Successfully exported {len(exported_files)} Antigravity session(s) into transcripts/:\n")
for ef in exported_files:
    rel = os.path.relpath(ef, repo_root)
    sz = os.path.getsize(ef)
    print(f"  - {rel} ({sz:,} bytes)")
rel_main = os.path.relpath(os.path.join(dest_dir, "transcript.md"), repo_root)
print(f"  - {rel_main} (latest session copy)")

EOF

echo
echo "Next steps:"
echo "  1. Review the exported transcripts in transcripts/ (verify no sensitive credentials or personal tokens)."
echo "  2. Show the exported transcript to your TA during recitation."
echo "     (Note: transcripts/ is in .gitignore; do NOT commit or push transcripts in this lab since your fork is public)."
