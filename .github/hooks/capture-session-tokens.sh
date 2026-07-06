#!/usr/bin/env bash
set -euo pipefail

# Bash entrypoint for capturing Copilot CLI session token usage.
# The heavy JSON parsing is handled by the Python standard library so this hook
# does not depend on jq and keeps the report schema identical to the PowerShell version.

script_path="${BASH_SOURCE[0]}"
stdin_file="$(mktemp "${TMPDIR:-/tmp}/capture-session-tokens.XXXXXX")"
cleanup() {
  rm -f "$stdin_file"
}
trap cleanup EXIT

if [[ ! -t 0 ]]; then
  cat > "$stdin_file"
else
  : > "$stdin_file"
fi

python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin="python3"
elif command -v python >/dev/null 2>&1; then
  python_bin="python"
else
  echo "capture-session-tokens: python3 or python is required for JSON parsing." >&2
  exit 1
fi

CAPTURE_SESSION_TOKENS_STDIN="$stdin_file" \
CAPTURE_SESSION_TOKENS_SCRIPT="$script_path" \
"$python_bin" - "$@" <<'PY'
import datetime as _dt
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

SCRIPT_VERSION = "1.2.0"
SESSION_ISSUES = []


def utc_now_text():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def add_session_issue(message, emit_warning=False):
    SESSION_ISSUES.append(f"{utc_now_text()} {message}")
    if emit_warning:
        print(f"WARNING: {message}", file=sys.stderr)


def write_session_issue_log(out_dir, session_id):
    if not session_id or not out_dir or not SESSION_ISSUES:
        return
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    (out_path / f"{session_id}.err.log").write_text(
        "\n".join(SESSION_ISSUES) + "\n",
        encoding="utf-8",
    )


def normalized_script_sha256(path):
    content = Path(path).read_text(encoding="utf-8")
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def copilot_home():
    return os.environ.get("COPILOT_HOME") or str(Path.home() / ".copilot")


def parse_bool_flag(args, index):
    return True, index + 1


def parse_value(args, index, option):
    if index + 1 >= len(args):
        raise SystemExit(f"capture-session-tokens: missing value for {option}")
    return args[index + 1], index + 2


def parse_args(argv):
    options = {
        "SessionId": None,
        "LogDir": None,
        "OutDir": None,
        "Label": None,
        "MaxWaitSeconds": 12,
        "StableSeconds": 2.0,
        "PollSeconds": 0.5,
        "NoWait": False,
        "Json": False,
        "Fingerprint": False,
    }
    aliases = {
        "-SessionId": "SessionId",
        "--session-id": "SessionId",
        "--SessionId": "SessionId",
        "-LogDir": "LogDir",
        "--log-dir": "LogDir",
        "--LogDir": "LogDir",
        "-OutDir": "OutDir",
        "--out-dir": "OutDir",
        "--OutDir": "OutDir",
        "-Label": "Label",
        "--label": "Label",
        "--Label": "Label",
        "-MaxWaitSeconds": "MaxWaitSeconds",
        "--max-wait-seconds": "MaxWaitSeconds",
        "--MaxWaitSeconds": "MaxWaitSeconds",
        "-StableSeconds": "StableSeconds",
        "--stable-seconds": "StableSeconds",
        "--StableSeconds": "StableSeconds",
        "-PollSeconds": "PollSeconds",
        "--poll-seconds": "PollSeconds",
        "--PollSeconds": "PollSeconds",
        "-NoWait": "NoWait",
        "--no-wait": "NoWait",
        "--NoWait": "NoWait",
        "-Json": "Json",
        "--json": "Json",
        "--Json": "Json",
        "-Fingerprint": "Fingerprint",
        "--fingerprint": "Fingerprint",
        "--Fingerprint": "Fingerprint",
    }
    numeric = {"MaxWaitSeconds": int, "StableSeconds": float, "PollSeconds": float}
    flags = {"NoWait", "Json", "Fingerprint"}

    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg not in aliases:
            raise SystemExit(f"capture-session-tokens: unknown argument: {arg}")
        key = aliases[arg]
        if key in flags:
            options[key], index = parse_bool_flag(argv, index)
        else:
            value, index = parse_value(argv, index, arg)
            options[key] = numeric.get(key, str)(value)
    return options


def safe_label(label):
    if label is None:
        return None
    label = str(label).strip()
    if not label:
        return None
    sanitized = []
    for char in label:
        if char.isspace() or char in '<>:"/\\|?*' or ord(char) < 32:
            sanitized.append("-")
        else:
            sanitized.append(char)
    value = re.sub(r"-{2,}", "-", "".join(sanitized)).strip("-")
    return value or None


def get_session_candidate_logs(session_id, log_dir, descending=False):
    try:
        entries = [p for p in Path(log_dir).glob("process-*.log") if p.is_file()]
    except OSError as exc:
        add_session_issue(f"capture-session-tokens: could not list log directory '{log_dir}': {exc}")
        return []

    entries.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=descending)
    candidates = []
    for log_file in entries:
        try:
            if session_id in log_file.read_text(encoding="utf-8", errors="replace"):
                candidates.append(log_file)
        except OSError as exc:
            add_session_issue(f"capture-session-tokens: skipping candidate log '{log_file}': {exc}")
    return candidates


def session_name_label(session_id, candidate_logs):
    logs = sorted(candidate_logs, key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)
    for log_file in logs:
        try:
            lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            add_session_issue(f"capture-session-tokens: could not read session-name log '{log_file}': {exc}")
            continue

        starts = [i for i, line in enumerate(lines) if f"Workspace initialized: {session_id}" in line]
        for start_index in reversed(starts):
            end_index = len(lines) - 1
            for i in range(start_index + 1, len(lines)):
                if "Workspace initialized:" in lines[i]:
                    end_index = i - 1
                    break
            for line in reversed(lines[start_index : end_index + 1]):
                match = re.search(r'Session named: "([^"]+)"', line)
                if match:
                    return safe_label(match.group(1))
                match = re.search(r'Generated session name: "([^"]+)"', line)
                if match:
                    return safe_label(match.group(1))
                match = re.search(r"<session-title>([^<]+)</session-title>", line)
                if match:
                    return safe_label(match.group(1))
    return None


def resolve_output_label(label, session_id, candidate_logs):
    return (
        safe_label(label)
        or safe_label(os.environ.get("COPILOT_TOKEN_USAGE_LABEL"))
        or session_name_label(session_id, candidate_logs)
    )


def telemetry_blocks(lines):
    blocks = []
    for i, line in enumerate(lines):
        if not re.search(r"\[Telemetry\] cli\.telemetry:", line):
            continue
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j >= len(lines) or lines[j].rstrip() != "{":
            continue
        block_lines = []
        for k in range(j, len(lines)):
            block_lines.append(lines[k])
            if lines[k] == "}":
                break
        try:
            blocks.append(json.loads("\n".join(block_lines)))
        except json.JSONDecodeError:
            pass
    return blocks


def session_usage_events(candidate_logs, session_id):
    seen = set()
    events = []
    for log_file in candidate_logs:
        try:
            lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            add_session_issue(f"capture-session-tokens: could not read usage log '{log_file}': {exc}")
            continue
        for block in telemetry_blocks(lines):
            if block.get("kind") != "assistant_usage":
                continue
            if block.get("session_id") != session_id:
                continue
            event_id = str(block.get("properties", {}).get("event_id") or "")
            if event_id and event_id in seen:
                continue
            if event_id:
                seen.add(event_id)
            events.append(block)
    return events


def normalized_reasoning_effort(reasoning_effort):
    value = "" if reasoning_effort is None else str(reasoning_effort)
    value = value.strip().lower()
    return value or "unspecified"


def add_count(counts, key):
    counts[key] = counts.get(key, 0) + 1


def effort_summary_value(counts):
    if not counts:
        return "unspecified"
    if len(counts) == 1:
        return next(iter(counts.keys()))
    return "mixed"


def metric(metrics, key):
    value = metrics.get(key, 0)
    return int(value or 0)


def main():
    options = parse_args(sys.argv[1:])

    script_path = os.environ.get("CAPTURE_SESSION_TOKENS_SCRIPT")
    if options["Fingerprint"]:
        if not script_path:
            print("capture-session-tokens: script path is unavailable.", file=sys.stderr)
            return 1
        print(json.dumps({
            "script_version": SCRIPT_VERSION,
            "content_sha256": normalized_script_sha256(script_path),
        }, separators=(",", ":")))
        return 0

    session_id = options["SessionId"]
    session_cwd = None

    if not session_id:
        stdin_path = os.environ.get("CAPTURE_SESSION_TOKENS_STDIN")
        raw = Path(stdin_path).read_text(encoding="utf-8") if stdin_path else ""
        if raw.strip():
            try:
                payload = json.loads(raw)
                session_id = payload.get("sessionId") or payload.get("session_id")
                if payload.get("cwd"):
                    session_cwd = str(payload["cwd"])
            except json.JSONDecodeError as exc:
                add_session_issue(f"capture-session-tokens: could not parse hook payload: {exc}", emit_warning=True)

    out_dir = options["OutDir"]
    if not session_id:
        add_session_issue("capture-session-tokens: no sessionId provided or found on stdin; nothing to do.", emit_warning=True)
        write_session_issue_log(out_dir, session_id)
        return 0

    log_dir = options["LogDir"] or str(Path(copilot_home()) / "logs")
    if not out_dir:
        if os.environ.get("COPILOT_TOKEN_USAGE_DIR"):
            out_dir = os.environ["COPILOT_TOKEN_USAGE_DIR"]
        elif session_cwd and Path(session_cwd).exists():
            out_dir = str(Path(session_cwd) / "token-usage")
        else:
            out_dir = str(Path.cwd() / "token-usage")

    if not Path(log_dir).exists():
        add_session_issue(f"capture-session-tokens: log directory not found: {log_dir}", emit_warning=True)
        write_session_issue_log(out_dir, session_id)
        return 0

    candidate_logs = get_session_candidate_logs(session_id, log_dir)
    events = session_usage_events(candidate_logs, session_id)
    if not options["NoWait"]:
        deadline = time.monotonic() + options["MaxWaitSeconds"]
        last_count = len(events)
        stable_since = time.monotonic()
        while time.monotonic() < deadline:
            time.sleep(options["PollSeconds"])
            candidate_logs = get_session_candidate_logs(session_id, log_dir)
            events = session_usage_events(candidate_logs, session_id)
            if len(events) != last_count:
                last_count = len(events)
                stable_since = time.monotonic()
            elif time.monotonic() - stable_since >= options["StableSeconds"]:
                break

    label = resolve_output_label(options["Label"], session_id, candidate_logs)

    by_model = {}
    effort_breakdown = {}
    for event in events:
        properties = event.get("properties", {})
        metrics = event.get("metrics", {})
        model = str(properties.get("model") or "unknown")
        if model not in by_model:
            by_model[model] = {
                "model": model,
                "api_calls": 0,
                "input_tokens_total": 0,
                "input_tokens_fresh": 0,
                "cached_input_tokens": 0,
                "cache_write_tokens": 0,
                "output_tokens": 0,
                "reasoning_tokens": 0,
                "reasoning_effort": "unspecified",
                "effort_breakdown": {},
            }

        effort = normalized_reasoning_effort(properties.get("reasoning_effort"))
        row = by_model[model]
        row["api_calls"] += 1
        row["input_tokens_total"] += metric(metrics, "input_tokens")
        row["input_tokens_fresh"] += metric(metrics, "input_tokens_uncached")
        row["cached_input_tokens"] += metric(metrics, "cache_read_tokens")
        row["cache_write_tokens"] += metric(metrics, "cache_write_tokens")
        row["output_tokens"] += metric(metrics, "output_tokens")
        row["reasoning_tokens"] += metric(metrics, "reasoning_tokens")
        add_count(row["effort_breakdown"], effort)
        add_count(effort_breakdown, effort)

    for row in by_model.values():
        row["reasoning_effort"] = effort_summary_value(row["effort_breakdown"])

    models = sorted(by_model.values(), key=lambda row: row["input_tokens_total"], reverse=True)
    totals = {
        "api_calls": sum(row["api_calls"] for row in models),
        "input_tokens_total": sum(row["input_tokens_total"] for row in models),
        "input_tokens_fresh": sum(row["input_tokens_fresh"] for row in models),
        "cached_input_tokens": sum(row["cached_input_tokens"] for row in models),
        "cache_write_tokens": sum(row["cache_write_tokens"] for row in models),
        "output_tokens": sum(row["output_tokens"] for row in models),
        "reasoning_tokens": sum(row["reasoning_tokens"] for row in models),
        "effort_breakdown": effort_breakdown,
    }

    report = {
        "schema": "copilot-cli-session-token-usage/v1",
        "generated_at": utc_now_text(),
        "cli_version_note": "Field layout verified against Copilot CLI v1.0.57; re-verify if your /version differs.",
        "session_id": session_id,
        "label": label,
        "field_meaning": {
            "input_tokens_fresh": "Billed at the model's 'Input' rate (fresh, non-cached input).",
            "cached_input_tokens": "Billed at the model's 'Cached input' rate.",
            "cache_write_tokens": "Billed at the model's 'Cache write' rate (Anthropic models only).",
            "output_tokens": "Billed at the model's 'Output' rate (includes reasoning tokens).",
            "reasoning_tokens": "Informational only; already counted within output_tokens.",
            "input_tokens_total": "fresh + cached input; informational.",
            "reasoning_effort": "Informational only; copied from assistant_usage.properties.reasoning_effort.",
            "effort_breakdown": "Informational only; count of API calls grouped by reasoning_effort.",
        },
        "totals": totals,
        "by_model": models,
    }

    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    file_name = f"{label}__{session_id}.json" if label else f"{session_id}.json"
    report_path = out_path / file_name
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    write_session_issue_log(out_dir, session_id)

    header_label = f"label {label}, " if label else ""
    print(f"Copilot CLI token usage  ({header_label}session {session_id})", file=sys.stderr)
    print(f"{'model':<30} {'calls':>6} {'effort':>12} {'input_fresh':>14} {'input_cached':>14} {'cache_write':>14} {'output':>12}", file=sys.stderr)
    for row in models:
        print(
            f"{row['model']:<30} {row['api_calls']:>6} {row['reasoning_effort']:>12} "
            f"{row['input_tokens_fresh']:>14} {row['cached_input_tokens']:>14} "
            f"{row['cache_write_tokens']:>14} {row['output_tokens']:>12}",
            file=sys.stderr,
        )
    print(
        f"{'TOTAL':<30} {totals['api_calls']:>6} {effort_summary_value(totals['effort_breakdown']):>12} "
        f"{totals['input_tokens_fresh']:>14} {totals['cached_input_tokens']:>14} "
        f"{totals['cache_write_tokens']:>14} {totals['output_tokens']:>12}",
        file=sys.stderr,
    )
    print(f"Saved: {report_path}", file=sys.stderr)

    if options["Json"]:
        print(json.dumps(report, indent=2))
    return 0


try:
    raise SystemExit(main())
except Exception as exc:
    add_session_issue(f"capture-session-tokens: unhandled error: {exc}", emit_warning=True)
    raise
PY
