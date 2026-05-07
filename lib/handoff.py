#!/usr/bin/env python
"""HANDOFF.md parser/modifier for cross-machine task handoff system.

Used two ways:
- CLI: `python lib/handoff.py <command> <file> [args...]` (called from sync.sh)
- Import: `from handoff import section_exists, ...` (called from preflight.py)
"""
import re
import sys


def _ensure_utf8():
    if hasattr(sys.stdout, "reconfigure") and sys.stdout.encoding \
            and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
        sys.stdout.reconfigure(encoding="utf-8")


# 模块级编码保护，防止 Windows cp936 环境下中文输出乱码（import 模式也生效）
_ensure_utf8()


def _extract_all_headers(text):
    """Return all ## header names from text."""
    return [m.group(1).strip() for m in re.finditer(r"(?m)^## (.+)$", text)]


def read_file(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write_file(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def read_registry(text):
    """Parse <!-- registry: name1, name2, ANY --> comment. Returns list or None if absent."""
    m = re.search(r"<!--\s*registry:\s*(.+?)\s*-->", text)
    if not m:
        return None
    names = [n.strip() for n in m.group(1).split(",") if n.strip()]
    # ANY is always implicitly included
    if "ANY" not in names:
        names.append("ANY")
    return names


def write_registry(text, devices):
    """Insert or replace the registry comment line after '# Handoff'."""
    # Ensure ANY is included
    if "ANY" not in devices:
        devices = list(devices) + ["ANY"]
    registry_line = f"<!-- registry: {', '.join(devices)} -->"
    # Replace existing registry line
    new_text, count = re.subn(r"<!--\s*registry:\s*.+?\s*-->", registry_line, text)
    if count > 0:
        return new_text
    # Insert after "# Handoff\n" (first h1 header)
    new_text, count = re.subn(
        r"(# Handoff\s*\n)",
        lambda m: m.group(1) + registry_line + "\n",
        text, count=1
    )
    if count > 0:
        return new_text
    # Fallback: prepend
    return registry_line + "\n" + text


def _get_device_names(text):
    """Return device names: from registry if present, else from ## headers."""
    registry = read_registry(text)
    if registry is not None:
        return registry
    return _extract_all_headers(text)


def _build_boundary_pattern(text):
    """Build a lookahead pattern that only matches registered device section headers."""
    names = _get_device_names(text)
    if names:
        escaped = "|".join(re.escape(n) for n in names)
        return rf"(?=^## (?:{escaped})\s*$|\Z)"
    # Legacy fallback: match any ## header
    return r"(?=^## |\Z)"


def section_exists(text, name):
    """Check if a ## section exists in the markdown text."""
    pattern = rf"(?m)^## {re.escape(name)}\s*$"
    return bool(re.search(pattern, text))


def extract_section_body(text, name):
    """Extract the body content of a named section. Returns None if not found."""
    boundary = _build_boundary_pattern(text)
    pattern = rf"(?m)^## {re.escape(name)}\s*\n(.*?){boundary}"
    m = re.search(pattern, text, re.DOTALL | re.MULTILINE)
    return m.group(1).strip() if m else None


def _modify_registry(text, modify_fn):
    """Read registry, apply modify_fn, write back. No-op if no registry."""
    registry = read_registry(text)
    if registry is not None:
        registry = modify_fn(registry)
        text = write_registry(text, registry)
    return text


def _is_fence_line(line):
    """Line starts a code fence (``` or ~~~ after optional indent)."""
    stripped = line.lstrip()
    return stripped.startswith("```") or stripped.startswith("~~~")


def add_section(text, name):
    """Insert a new (none) section before ## ANY and update registry.

    Uses line-by-line scanning that SKIPS markdown fenced code blocks (``` or ~~~),
    so a literal "## ANY" appearing inside a code example in a task body cannot be
    matched (the older regex approach couldn't tell fence-inside from real header).
    Only the first non-fenced `## ANY` at start-of-line is used.

    Also rejects names containing newlines (sync.sh wraps with `tr -d '\r\n'` but
    direct Python callers need defense-in-depth).
    """
    if "\n" in name or "\r" in name:
        raise ValueError("设备名不能包含换行字符")
    new_section_lines = [f"## {name}", "", "(none)", ""]
    lines = text.split("\n")
    in_code_fence = False
    insert_index = None
    for i, line in enumerate(lines):
        if _is_fence_line(line):
            in_code_fence = not in_code_fence
            continue
        if in_code_fence:
            continue
        if line.rstrip() == "## ANY":
            insert_index = i
            break
    if insert_index is None:
        raise ValueError("HANDOFF.md 中未找到 '## ANY' 锚点（或仅在代码块内），无法插入新设备节")
    # Insert new-section block + trailing blank line before the ## ANY line
    lines[insert_index:insert_index] = new_section_lines + [""]
    result = "\n".join(lines)
    # Update registry
    result = _modify_registry(result, lambda reg: reg if name in reg else reg + [name])
    return result


def remove_section(text, name):
    """Remove a section, normalize whitespace, and update registry.

    Uses line-by-line scanning + code-fence tracking to avoid matching a literal
    ## Name line that appears inside a code fenced block (which would corrupt
    unrelated content).
    """
    lines = text.split("\n")
    in_code_fence = False
    # Collect device-section-header indices (non-fenced `## <Name>` lines)
    boundary_indices = []
    target_index = None
    target_header = f"## {name}"
    for i, line in enumerate(lines):
        if _is_fence_line(line):
            in_code_fence = not in_code_fence
            continue
        if in_code_fence:
            continue
        stripped = line.rstrip()
        if stripped.startswith("## "):
            boundary_indices.append(i)
            if stripped == target_header and target_index is None:
                target_index = i
    if target_index is None:
        # Nothing to remove; still normalize whitespace + registry for idempotency
        result = re.sub(r"\n{3,}", "\n\n", text)
        return _modify_registry(result, lambda reg: [n for n in reg if n != name])
    # Find the next non-fenced ## header after target_index (section end)
    next_boundaries = [b for b in boundary_indices if b > target_index]
    end_index = next_boundaries[0] if next_boundaries else len(lines)
    del lines[target_index:end_index]
    result = "\n".join(lines)
    result = re.sub(r"\n{3,}", "\n\n", result)
    # Update registry
    result = _modify_registry(result, lambda reg: [n for n in reg if n != name])
    return result


def list_devices(text):
    """Return list of device names (excluding ANY). Uses registry if available."""
    return [n for n in _get_device_names(text) if n != "ANY"]


def migrate_format(text):
    """Add registry comment to legacy HANDOFF.md (idempotent)."""
    if read_registry(text) is not None:
        return text  # Already migrated
    # Discover devices using legacy method
    devices = _extract_all_headers(text)
    if not devices:
        return text  # Nothing to migrate
    return write_registry(text, devices)


def get_pending_tasks(text, *targets):
    """Return list of (target, body) tuples for sections with pending tasks."""
    results = []
    for target in targets:
        body = extract_section_body(text, target)
        if body and body != "(none)":
            results.append((target, body))
    return results


# --- CLI interface (called from bash) ---
if __name__ == "__main__":
    # 模块级已处理编码，此处保留作为 CLI 入口的防御性保证
    _ensure_utf8()

    if len(sys.argv) < 2:
        print("Usage: handoff.py <command> <file> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "section_exists":
        text = read_file(sys.argv[2])
        print("yes" if section_exists(text, sys.argv[3]) else "no")

    elif cmd == "add_section":
        path = sys.argv[2]
        try:
            text = add_section(read_file(path), sys.argv[3])
        except ValueError as e:
            print(f"错误：{e}", file=sys.stderr)
            sys.exit(1)
        write_file(path, text)

    elif cmd == "remove_section":
        path = sys.argv[2]
        text = remove_section(read_file(path), sys.argv[3])
        write_file(path, text)

    elif cmd == "list_devices":
        for name in list_devices(read_file(sys.argv[2])):
            print(name)

    elif cmd == "get_pending":
        for target, body in get_pending_tasks(read_file(sys.argv[2]), *sys.argv[3:]):
            print(f"[{target}]")
            print(body)
            print()

    elif cmd == "migrate":
        path = sys.argv[2]
        text = migrate_format(read_file(path))
        write_file(path, text)
        print("Migration complete.")

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
