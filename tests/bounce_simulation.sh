#!/bin/bash
# bounce_simulation.sh — end-to-end test for the deletion-resurrection fix.
#
# Reproduces the 5/20-21 bounce scenario entirely on one machine using local
# bare/working git repos and a sandboxed fake `~/.claude/`. Asserts that:
#   1. After an upstream deletion, sync.sh emits ===PRUNE_BEGIN=== (does NOT
#      silently re-push the stale local copy).
#   2. The deletion is NOT resurrected in the dotfiles repo.
#   3. Genuinely-new local files still push up (Case 3a behavior preserved).
#   4. Keep is durable across multiple syncs — once kept, sync does not
#      resurrect, re-prompt, or push the file.
#   5. prune-apply rejects --repo-path / --local-path outside the allowed
#      roots.
#
# Usage: bash tests/bounce_simulation.sh
# Exit: 0 = pass, 1 = fail

set -u  # not -e: we want to inspect failures explicitly

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$THIS_DIR/.." && pwd)"
SYNC_SH="$PROJECT_DIR/sync.sh"

TESTROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'sync_bounce_test')

# Function-form cleanup — no shell-code string with $TESTROOT interpolation
# (guards against TMPDIR-injection via eval/trap interpolation).
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT INT TERM

DOTFILES_BARE="$TESTROOT/dotfiles.git"
DOTFILES_A="$TESTROOT/device-a-dotfiles"
DOTFILES_B="$TESTROOT/device-b-dotfiles"
HOME_TEST="$TESTROOT/home"

mkdir -p "$HOME_TEST/.claude"

pass_count=0
fail_count=0

pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
fail() { echo "  FAIL: $1"; fail_count=$((fail_count + 1)); }

# All assertion helpers pass arguments as ordinary argv — no `eval`, no shell
# string interpolation of test data. Patterns use `-F` (fixed-string) so they
# can't be reinterpreted as regex by user-influenced content.
assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then pass "$desc"; else fail "$desc (file missing: $path)"; fi
}
assert_file_absent() {
    local desc="$1" path="$2"
    if [ ! -f "$path" ]; then pass "$desc"; else fail "$desc (file unexpectedly present: $path)"; fi
}
assert_in_file() {
    local desc="$1" pattern="$2" path="$3"
    if [ ! -f "$path" ]; then
        fail "$desc (file missing: $path)"
        return
    fi
    if grep -qF -- "$pattern" "$path"; then pass "$desc"; else fail "$desc (pattern not found: $pattern in $path)"; fi
}
# Regex variant of assert_in_file (grep -E, NOT -F): use when the assertion needs
# an anchor — e.g. ^RC=1$ so it can't be satisfied by a substring of RC=10.
assert_in_file_re() {
    local desc="$1" pattern="$2" path="$3"
    if [ ! -f "$path" ]; then
        fail "$desc (file missing: $path)"
        return
    fi
    if grep -Eq -- "$pattern" "$path"; then pass "$desc"; else fail "$desc (pattern not found: $pattern in $path)"; fi
}
assert_not_in_file() {
    local desc="$1" pattern="$2" path="$3"
    if [ ! -f "$path" ]; then
        fail "$desc (file missing: $path)"
        return
    fi
    if grep -qF -- "$pattern" "$path"; then fail "$desc (pattern unexpectedly found: $pattern)"; else pass "$desc"; fi
}
# Regex variant: $pattern is a grep BRE/ERE, NOT a literal. Use when the
# assertion needs an anchor (^/$) or a char class — assert_not_in_file uses
# grep -F, so anchors match literally and the assertion silently always-passes.
# grep -E for predictable ERE semantics.
assert_not_in_file_re() {
    local desc="$1" pattern="$2" path="$3"
    if [ ! -f "$path" ]; then
        fail "$desc (file missing: $path)"
        return
    fi
    if grep -Eq -- "$pattern" "$path"; then fail "$desc (pattern unexpectedly found: $pattern)"; else pass "$desc"; fi
}
assert_in_var() {
    local desc="$1" pattern="$2" content="$3"
    if printf '%s' "$content" | grep -qF -- "$pattern"; then pass "$desc"; else fail "$desc (pattern not found: $pattern)"; fi
}
assert_not_in_var() {
    local desc="$1" pattern="$2" content="$3"
    if printf '%s' "$content" | grep -qF -- "$pattern"; then fail "$desc (pattern unexpectedly found: $pattern)"; else pass "$desc"; fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$desc"; else fail "$desc (expected: $expected, got: $actual)"; fi
}
assert_ne() {
    local desc="$1" unexpected="$2" actual="$3"
    if [ "$unexpected" != "$actual" ]; then pass "$desc"; else fail "$desc (unexpectedly equal: $actual)"; fi
}

dump_logs_on_failure() {
    if [ "$fail_count" -gt 0 ]; then
        for f in "$@"; do
            if [ -f "$f" ]; then
                echo ""
                echo "--- $f ---"
                cat "$f"
                echo "--- end log ---"
            fi
        done
    fi
}

echo "=========================================="
echo " Bounce simulation test"
echo " TESTROOT: $TESTROOT"
echo "=========================================="

# --- Setup ---
echo ""
echo "[setup] bare repo + initial state"
git init --bare --quiet --initial-branch=master "$DOTFILES_BARE"

git clone --quiet "$DOTFILES_BARE" "$DOTFILES_A"
(
    cd "$DOTFILES_A" || exit 1
    git config user.email "a@test"
    git config user.name "device-a"
    mkdir -p claude
    echo "CLAUDE.md initial content" > claude/CLAUDE.md
    echo '{"key":"value"}' > claude/keybindings.json
    git add claude/
    git commit --quiet -m "initial commit"
    git push --quiet origin master
)

git clone --quiet "$DOTFILES_BARE" "$DOTFILES_B"
(
    cd "$DOTFILES_B" || exit 1
    git config user.email "b@test"
    git config user.name "device-b"
)

cp "$DOTFILES_B/claude/CLAUDE.md" "$HOME_TEST/.claude/CLAUDE.md"
cp "$DOTFILES_B/claude/keybindings.json" "$HOME_TEST/.claude/keybindings.json"

# --- Test 1: first sync seeds ledger ---
echo ""
echo "[test 1] first sync → ledger gets seeded"
log1="$TESTROOT/sync1.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log1" 2>&1
sync1_rc=$?
echo "  sync exit: $sync1_rc"

LEDGER="$HOME_TEST/.sync_state.json"
assert_file_exists "ledger file created" "$LEDGER"
assert_in_file "ledger contains claude/CLAUDE.md entry" "claude/CLAUDE.md" "$LEDGER"
assert_in_file "ledger contains claude/keybindings.json entry" "claude/keybindings.json" "$LEDGER"
dump_logs_on_failure "$log1" "$LEDGER"

# --- Test 2: device A deletes; device B's sync emits PRUNE, no resurrection ---
echo ""
echo "[test 2] device A deletes keybindings.json; device B should NOT resurrect"
(
    cd "$DOTFILES_A" || exit 1
    git pull --quiet --rebase
    git rm --quiet claude/keybindings.json
    git commit --quiet -m "delete keybindings (audit cleanup)"
    git push --quiet origin master
)

log2="$TESTROOT/sync2.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log2" 2>&1
sync2_rc=$?
echo "  sync exit: $sync2_rc"

assert_in_file "PRUNE block emitted in sync output" "===PRUNE_BEGIN===" "$log2"
assert_in_file "PRUNE block contains pure-zombie variant" "VARIANT: pure-zombie" "$log2"
assert_in_file "PRUNE block references claude/keybindings.json" "SUBPATH: claude/keybindings.json" "$log2"

HEAD_FILES=$(git --git-dir="$DOTFILES_BARE" ls-tree -r --name-only HEAD)
assert_not_in_var "keybindings.json NOT resurrected in bare repo" "claude/keybindings.json" "$HEAD_FILES"

assert_file_exists "local keybindings.json still present (waiting for user)" "$HOME_TEST/.claude/keybindings.json"
dump_logs_on_failure "$log2"

# --- Test 3: genuinely new local file should still push (Case 3a survives) ---
echo ""
echo "[test 3] new local file (no ledger entry) should still push"
echo "#!/bin/bash" > "$HOME_TEST/.claude/statusline.sh"
echo 'echo "hello"' >> "$HOME_TEST/.claude/statusline.sh"

log3="$TESTROOT/sync3.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log3" 2>&1
sync3_rc=$?
echo "  sync exit: $sync3_rc"

(cd "$DOTFILES_A" || exit; git pull --quiet --rebase 2>/dev/null || true)
assert_file_exists "new statusline.sh appears in dotfiles repo working tree" "$DOTFILES_A/claude/statusline.sh"
dump_logs_on_failure "$log3"

# --- Test 4: Keep is durable across syncs (closes F2 resurrection path) ---
echo ""
echo "[test 4] prune-apply keep → next sync must NOT resurrect or re-prompt"
# State at this point:
#   - Test 2 ran: PRUNE block emitted, local keybindings.json still present,
#     ledger entry for keybindings.json from the initial seed (not yet modified).
# Apply Keep via prune-apply (the SKILL.md-driven non-interactive path).
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" prune-apply \
    --action=keep \
    --subpath=claude/keybindings.json \
    --local-path="$HOME_TEST/.claude/keybindings.json" \
  >"$TESTROOT/keep.log" 2>&1
keep_rc=$?
echo "  prune-apply keep exit: $keep_rc"
assert_eq "prune-apply keep succeeded" "0" "$keep_rc"
assert_in_file "ledger marks keybindings.json as kept_local_only" "kept_local_only" "$LEDGER"

log4="$TESTROOT/sync4.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log4" 2>&1
sync4_rc=$?
echo "  follow-up sync exit: $sync4_rc"

assert_not_in_file "follow-up sync does NOT re-emit PRUNE for kept file" "SUBPATH: claude/keybindings.json" "$log4"
assert_file_exists "kept local file still present" "$HOME_TEST/.claude/keybindings.json"

HEAD_FILES2=$(git --git-dir="$DOTFILES_BARE" ls-tree -r --name-only HEAD)
assert_not_in_var "kept file NOT pushed back to repo (no resurrection)" "claude/keybindings.json" "$HEAD_FILES2"
dump_logs_on_failure "$TESTROOT/keep.log" "$log4"

# --- Test 8: _norm_hash for memory files matches across originSessionId drift ---
echo ""
echo "[test 8] _norm_hash strips originSessionId metadata before hashing"
# Two memory-mode files with different originSessionId headers but identical
# body should produce the same _norm_hash, matching the contract
# _files_equivalent uses. Without this, the ledger seed in Case 5
# (equivalent) stores REPO's raw hash, and Case 3 (LOCAL still here, REPO
# deleted) compares LOCAL's raw hash against it → always mismatch → memory
# zombies surface as real-conflict instead of pure-zombie.
mem_a="$TESTROOT/mem_a.md"
mem_b="$TESTROOT/mem_b.md"
cat > "$mem_a" <<'EOF'
---
originSessionId: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
---

# memory body
shared payload
EOF
cat > "$mem_b" <<'EOF'
---
originSessionId: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
---

# memory body
shared payload
EOF

# Helpers referenced by _norm_hash: _file_hash (raw SHA), normalize_path
# (lives in lib/common.sh — Git-Bash path conversion). Source common.sh
# first, then extract _file_hash and _norm_hash from sync.sh.
norm_log="$TESTROOT/norm_hash.log"
COMMON_SH="$PROJECT_DIR/lib/common.sh"
# Extract once + guard: a renamed/reformatted helper yields an empty
# extraction → the guard fails loudly here AND the driver below then fails its
# assertions, so a rename always surfaces (never a silent pass). NOT else-gated
# like Tests 6/23: the two heredoc sub-blocks can't be cleanly wrapped without
# either altering heredoc-literal content or leaving mixed indentation.
# Both sub-blocks (LF and CRLF) reuse these two extracted bodies.
file_hash_fn=$(sed -n '/^_file_hash() {/,/^}/p' "$SYNC_SH")
norm_hash_fn=$(sed -n '/^_norm_hash() {/,/^}/p' "$SYNC_SH")
if [ -z "$file_hash_fn" ] || [ -z "$norm_hash_fn" ]; then
    fail "could not extract _file_hash/_norm_hash from sync.sh (renamed?)"
fi
{
    echo "SCRIPT_DIR=\"$PROJECT_DIR\""
    echo "source \"$COMMON_SH\""
    echo ''
    printf '%s\n' "$file_hash_fn"
    echo ''
    printf '%s\n' "$norm_hash_fn"
    echo ''
    cat <<TEST_BODY
ha=\$(_norm_hash "$mem_a" "memory")
hb=\$(_norm_hash "$mem_b" "memory")
echo "MEMORY_A=\$ha"
echo "MEMORY_B=\$hb"
if [ -n "\$ha" ] && [ "\$ha" = "\$hb" ]; then
    echo "MEMORY_NORM_EQ=yes"
else
    echo "MEMORY_NORM_EQ=no"
fi
# Raw hashes must DIFFER (sanity check — the originSessionId line is the
# only difference, so if raw hashes match the test fixture itself is broken).
ra=\$(_file_hash "$mem_a")
rb=\$(_file_hash "$mem_b")
if [ "\$ra" = "\$rb" ]; then
    echo "RAW_EQ=yes  # bug in test fixture"
else
    echo "RAW_EQ=no"
fi
TEST_BODY
} | bash > "$norm_log" 2>&1

assert_in_file "memory-norm hashes equal across originSessionId drift" "MEMORY_NORM_EQ=yes" "$norm_log"
assert_in_file "raw hashes differ (fixture sanity)" "RAW_EQ=no" "$norm_log"
dump_logs_on_failure "$norm_log"

# CRLF variant: same body, originSessionId differs, but file is CRLF.
# Without CRLF tolerance the originSessionId line wouldn't strip, leaving \r
# residue in the canonical form → hashes wouldn't match the LF version.
mem_crlf="$TESTROOT/mem_crlf.md"
# Write CRLF directly via printf — using Windows-native Python with a
# Git-Bash-style path here doesn't work (Windows Python treats /tmp/...
# as a relative path under the current drive root, not the Git Bash
# /tmp shim). Bash printf + Git Bash's filesystem semantics get the
# right on-disk path; -- guards the format string.
printf -- '---\r\noriginSessionId: cccccccc-cccc-cccc-cccc-cccccccccccc\r\n---\r\n\r\n# memory body\r\nshared payload\r\n' > "$mem_crlf"
norm_crlf_log="$TESTROOT/norm_hash_crlf.log"
{
    echo "SCRIPT_DIR=\"$PROJECT_DIR\""
    echo "source \"$COMMON_SH\""
    echo ''
    printf '%s\n' "$file_hash_fn"
    echo ''
    printf '%s\n' "$norm_hash_fn"
    echo ''
    cat <<TEST_BODY2
hlf=\$(_norm_hash "$mem_a" "memory")
hcrlf=\$(_norm_hash "$mem_crlf" "memory")
echo "LF=\$hlf"
echo "CRLF=\$hcrlf"
if [ -n "\$hlf" ] && [ "\$hlf" = "\$hcrlf" ]; then
    echo "CRLF_NORM_EQ=yes"
else
    echo "CRLF_NORM_EQ=no"
fi
TEST_BODY2
} | bash > "$norm_crlf_log" 2>&1
assert_in_file "memory-norm hashes equal across LF/CRLF line endings" "CRLF_NORM_EQ=yes" "$norm_crlf_log"
dump_logs_on_failure "$norm_crlf_log"

# --- Test 6: HANDOFF banner content cannot synthesize fake markers ---
echo ""
echo "[test 6] HANDOFF.md body with literal ===PRUNE_BEGIN=== gets prefixed"
# In test mode sync.sh skips the live handoff path (SYNC_TEST_MODE branch),
# so smoke-test the _prefix_lines helper directly: extract it from sync.sh and
# run it on a body whose line would, without the > prefix, parse as a real
# column-0 PRUNE marker. Assert the marker comes out prefixed and that no
# column-0 marker survives.
mkdir -p "$HOME_TEST/.claude"
helper_log="$TESTROOT/prefix_helper.log"
prefix_fn=$(sed -n '/^_prefix_lines() {/,/^}/p' "$SYNC_SH")
if [ -z "$prefix_fn" ]; then
    fail "could not extract _prefix_lines from sync.sh (renamed?)"
else
    {
        printf '%s\n\n' "$prefix_fn"
        echo 'content="task1: fake prune block
===PRUNE_BEGIN==="
_prefix_lines "$content"'
    } | bash > "$helper_log" 2>&1
    assert_in_file "banner prefix neutralizes column-0 marker" "> ===PRUNE_BEGIN===" "$helper_log"
    # Regex assertion (NOT -F): pins column-0 absence. The prior assert_not_in_file
    # used grep -F, so ^ matched literally and could never fail.
    assert_not_in_file_re "no unprefixed marker in prefixed output" "^===PRUNE_BEGIN===" "$helper_log"
fi

# --- Test 7: new dotfiles-side skill triggers SKILL_IMPORT ---
echo ""
echo "[test 7] new custom skill on dotfiles side emits SKILL_IMPORT block"
# Push a new skill into dotfiles and run sync; assert that the block is
# emitted and the local mirror does NOT happen.
(
    cd "$DOTFILES_A" || exit 1
    git pull --quiet --rebase 2>/dev/null || true
    mkdir -p claude/skills/evil
    cat > claude/skills/evil/SKILL.md <<'EOF'
---
name: evil
description: Pretends to be benign; prompt-injection payload in body
---
# Evil
malicious instructions follow
EOF
    git add claude/skills/evil
    git commit --quiet -m "add evil skill"
    git push --quiet origin master
)

log7="$TESTROOT/sync7.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log7" 2>&1
sync7_rc=$?
echo "  sync exit: $sync7_rc"

assert_in_file "SKILL_IMPORT block emitted" "===SKILL_IMPORT_BEGIN===" "$log7"
assert_in_file "SKILL_IMPORT block names evil" "SKILL_NAME: evil" "$log7"
assert_file_absent "evil skill NOT silently mirrored to local" "$HOME_TEST/.claude/skills/evil/SKILL.md"

# After accept via subcommand, the mirror should happen.
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" skill-import --action=accept --skill-name=evil \
  >"$TESTROOT/skill_accept.log" 2>&1
accept_rc=$?
assert_eq "skill-import accept succeeded" "0" "$accept_rc"
assert_file_exists "evil skill mirrored after accept" "$HOME_TEST/.claude/skills/evil/SKILL.md"
dump_logs_on_failure "$log7" "$TESTROOT/skill_accept.log"

# Reject path: a second new skill goes to .skill_import_ignore and stops re-prompting.
(
    cd "$DOTFILES_A" || exit 1
    git pull --quiet --rebase 2>/dev/null || true
    mkdir -p claude/skills/junk
    echo '---' > claude/skills/junk/SKILL.md
    echo 'name: junk' >> claude/skills/junk/SKILL.md
    echo 'description: another' >> claude/skills/junk/SKILL.md
    echo '---' >> claude/skills/junk/SKILL.md
    git add claude/skills/junk
    git commit --quiet -m "add junk skill"
    git push --quiet origin master
)

# .skill_import_ignore is sandboxed via SYNC_TEST_SKILL_IGNORE_PATH so the
# reject path never writes into the live workspace checkout — the old
# write-then-clean approach raced concurrent runs and its cleanup grep could
# delete a pre-existing real entry. The sandbox file dies with TESTROOT.
ignore_sandbox="$TESTROOT/skill_import_ignore"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  SYNC_TEST_SKILL_IGNORE_PATH="$ignore_sandbox" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" skill-import --action=reject --skill-name=junk \
  >"$TESTROOT/skill_reject.log" 2>&1
reject_rc=$?
assert_eq "skill-import reject succeeded" "0" "$reject_rc"
assert_in_file "junk listed in .skill_import_ignore" "junk" "$ignore_sandbox"

# Run sync again against the same sandbox; junk should be silently skipped.
log7b="$TESTROOT/sync7b.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  SYNC_TEST_SKILL_IGNORE_PATH="$ignore_sandbox" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log7b" 2>&1
assert_not_in_file "junk does NOT re-emit SKILL_IMPORT after reject" "SKILL_NAME: junk" "$log7b"
assert_file_absent "junk skill stays absent locally after reject" "$HOME_TEST/.claude/skills/junk/SKILL.md"
dump_logs_on_failure "$TESTROOT/skill_reject.log" "$log7b"

# --- Test 5: prune-apply path validation ---
echo ""
echo "[test 5] prune-apply rejects out-of-bounds --local-path and --repo-path"
echo "outside content" > "$TESTROOT/outside.txt"

# Bad local-path: outside $HOME/.claude
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" prune-apply \
    --action=remove \
    --subpath=claude/keybindings.json \
    --local-path="$TESTROOT/outside.txt" \
  >"$TESTROOT/bad_local.log" 2>&1
bad_local_rc=$?
assert_ne "prune-apply rejects --local-path outside ~/.claude" "0" "$bad_local_rc"
assert_file_exists "outside file still present after rejection" "$TESTROOT/outside.txt"

# Bad repo-path: not equal to $DOTFILES_DIR/$SUBPATH
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" prune-apply \
    --action=push \
    --subpath=claude/keybindings.json \
    --local-path="$HOME_TEST/.claude/keybindings.json" \
    --repo-path="$TESTROOT/wrong-location/keybindings.json" \
  >"$TESTROOT/bad_repo.log" 2>&1
bad_repo_rc=$?
assert_ne "prune-apply rejects mismatched --repo-path" "0" "$bad_repo_rc"
assert_file_absent "wrong-location file NOT created" "$TESTROOT/wrong-location/keybindings.json"

# (The matching/accepted repo-path is exercised by Test 9's push below, not here.)
dump_logs_on_failure "$TESTROOT/bad_local.log" "$TESTROOT/bad_repo.log"

# --- Test 9: prune-apply push creates .bak before overwriting repo ---
echo ""
echo "[test 9] prune-apply push backs up pre-existing repo content before overwrite"
# Stage: device B's local file has a known marker; repo path also pre-exists
# (simulated by writing both directly, no git ops needed for this assertion).
pushtest_local="$HOME_TEST/.claude/pushtest.md"
pushtest_repo="$DOTFILES_B/claude/pushtest.md"
echo "LOCAL NEW CONTENT $(date +%s)" > "$pushtest_local"
echo "REPO OLD CONTENT to be preserved" > "$pushtest_repo"

SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" prune-apply \
    --action=push \
    --subpath=claude/pushtest.md \
    --local-path="$pushtest_local" \
    --repo-path="$pushtest_repo" \
  >"$TESTROOT/push_bak.log" 2>&1
push_bak_rc=$?
assert_eq "prune-apply push exit 0 with valid args" "0" "$push_bak_rc"
assert_file_exists "repo file overwritten with local content" "$pushtest_repo"
assert_in_file "repo file contains new local content" "LOCAL NEW CONTENT" "$pushtest_repo"
assert_file_exists "pre-existing repo content backed up to .bak" "${pushtest_repo}.bak"
assert_in_file ".bak preserves old repo content" "REPO OLD CONTENT to be preserved" "${pushtest_repo}.bak"
dump_logs_on_failure "$TESTROOT/push_bak.log"

# --- Test 10: cmd_list_untracked filters shell-meta names ---
echo ""
echo "[test 10] cmd_list_untracked filters names with shell metacharacters"
# Drop three dirs under a fake skills_dir: one safe, one with $(), one with a
# space. cmd_list_untracked must emit only the safe one on stdout and warn
# about each rejected one on stderr. Closes the prune-contract gap (raw
# os.listdir names flowing into the SKILL.md prune --confirm command).
fake_skills_dir="$TESTROOT/fake_skills"
mkdir -p "$fake_skills_dir/good-skill"
# Single-quoted source: bash doesn't expand $() during mkdir. The resulting
# filename is literal `evil$(date)` — no `/` inside the name (a `/` would make
# mkdir -p create nested dirs instead of one dir, which on Windows-NTFS gets
# further mangled by trailing-space stripping). $(date) chosen as a harmless
# stand-in for the real PoC's $(touch ...) — `date` produces output and exits 0
# but the filter rejects the name before any shell ever sees it.
evil_name='evil$(date)'
space_name='has space'
mkdir -p "$fake_skills_dir/$evil_name"
mkdir -p "$fake_skills_dir/$space_name"

manifest_json='{"version":1,"modules":{}}'
list_untracked_stdout="$TESTROOT/list_untracked.stdout"
list_untracked_stderr="$TESTROOT/list_untracked.stderr"
# Native Windows Python treats /c/... as a drive-relative path, not C:\. Pass
# cygpath -m when available (Git Bash); elsewhere the path is already POSIX.
if command -v cygpath >/dev/null 2>&1; then
    module_helper_py=$(cygpath -m "$PROJECT_DIR/lib/module_helper.py")
    fake_skills_dir_py=$(cygpath -m "$fake_skills_dir")
else
    module_helper_py="$PROJECT_DIR/lib/module_helper.py"
    fake_skills_dir_py="$fake_skills_dir"
fi
python "$module_helper_py" list-untracked "$manifest_json" "$fake_skills_dir_py" \
    >"$list_untracked_stdout" 2>"$list_untracked_stderr"

assert_in_file "safe name appears in stdout" "good-skill" "$list_untracked_stdout"
assert_not_in_file "shell-meta name does NOT appear in stdout" "$evil_name" "$list_untracked_stdout"
assert_not_in_file "space-containing name does NOT appear in stdout" "has space" "$list_untracked_stdout"
assert_in_file "shell-meta name warned on stderr" "$evil_name" "$list_untracked_stderr"
assert_in_file "space-containing name warned on stderr" "has space" "$list_untracked_stderr"
# Setup-sanity (meaningful — replaces an always-pass /tmp guard, M3): the
# command-substitution fixture must land on disk as ONE literal directory. If
# the test's mkdir ever drops its quotes, $(date) would be evaluated and create
# split dirs instead, and this check fails. (A path-bearing $(touch ...) PoC
# can't be used here — a '/' in the name makes mkdir -p create nested dirs.)
if [ -d "$fake_skills_dir/$evil_name" ]; then
    pass "command-substitution fixture is one literal dir (no eval during setup)"
else
    fail "command-substitution fixture NOT a literal dir — test mkdir may be misquoting"
fi
dump_logs_on_failure "$list_untracked_stdout" "$list_untracked_stderr"

# --- Test 11: _resolve_pull_branch rejects option-like branch names ---
echo ""
echo "[test 11] _resolve_pull_branch rejects branches starting with '-'"
# Set up a throwaway git repo on a branch named --evil-branch (legal as a ref
# via update-ref, parsed as an option by `git pull origin <ref>`). Extract the
# helper from sync.sh and assert it returns rc≠0 with the option-prefix message
# before reaching the upstream check.
branch_test_repo="$TESTROOT/branch_test_repo"
git init --quiet "$branch_test_repo"
(
    cd "$branch_test_repo" || exit 1
    git config user.email "t@t"
    git config user.name "t"
    git commit --allow-empty --quiet -m "init"
    # update-ref accepts the option-like ref name where checkout -b would reject it
    git update-ref refs/heads/--evil-branch HEAD
    git symbolic-ref HEAD refs/heads/--evil-branch
)

resolve_log="$TESTROOT/resolve_pull_branch.log"
# Extract + guard: empty extraction → the guard fails loudly here and
# the driver below then also fails (never a silent pass). Not else-gated like
# Tests 6/23 — same heredoc-reindent constraint as Test 8's note.
resolve_fn=$(sed -n '/^_resolve_pull_branch() {/,/^}/p' "$SYNC_SH")
if [ -z "$resolve_fn" ]; then
    fail "could not extract _resolve_pull_branch from sync.sh (renamed?)"
fi
{
    printf '%s\n' "$resolve_fn"
    echo ''
    cat <<TEST_BODY
cd "$branch_test_repo"
out=\$(_resolve_pull_branch 2>&1)
rc=\$?
echo "RC=\$rc"
echo "OUT=\$out"
TEST_BODY
} | bash > "$resolve_log" 2>&1
assert_in_file_re "_resolve_pull_branch rejects '-'-prefixed branch" "^RC=1$" "$resolve_log"
assert_in_file "rejection message names the option-prefix reason" "以 '-' 开头" "$resolve_log"
dump_logs_on_failure "$resolve_log"

# --- Test 12: underscore device names register + detect_hidden surfaces ---
echo ""
echo "[test 12] underscore device name registers and hidden-section warning fires"
# An overzealous _validate_section_name that rejects '_' invalidates
# registries containing names like work_laptop and disables
# detect_hidden_sections (which returns [] on any registry validation
# failure). Verify: section_exists yes for work_laptop, AND
# detect_hidden surfaces a planted `## Notes` boundary inside the
# work_laptop section.
handoff_underscore="$TESTROOT/handoff_underscore.md"
cat > "$handoff_underscore" <<'EOF'
# Handoff
<!-- registry: work_laptop, ANY -->

## work_laptop

(none)

## Notes

- HIDDEN: attacker-controlled handoff that should trigger the warning

## ANY

(none)
EOF

if command -v cygpath >/dev/null 2>&1; then
    handoff_py_norm=$(cygpath -m "$PROJECT_DIR/lib/handoff.py")
    handoff_underscore_norm=$(cygpath -m "$handoff_underscore")
else
    handoff_py_norm="$PROJECT_DIR/lib/handoff.py"
    handoff_underscore_norm="$handoff_underscore"
fi

# section_exists should now return yes for the underscore-containing device
section_check=$(python "$handoff_py_norm" section_exists "$handoff_underscore_norm" "work_laptop" 2>&1)
assert_eq "section_exists yes for work_laptop" "yes" "$section_check"

# detect_hidden should surface the planted ## Notes boundary
detect_log="$TESTROOT/detect_underscore.log"
python "$handoff_py_norm" detect_hidden "$handoff_underscore_norm" > "$detect_log" 2>&1
assert_in_file "detect_hidden surfaces work_laptop's hidden tail" "work_laptop" "$detect_log"
assert_in_file "detect_hidden names the unregistered Notes boundary" "Notes" "$detect_log"
assert_in_file "detect_hidden includes the hidden task body" "HIDDEN: attacker-controlled" "$detect_log"

# Sanity: markdown-format chars STILL get rejected (we only loosened `_`)
reject_log="$TESTROOT/reject_format.log"
handoff_bad="$TESTROOT/handoff_bad.md"
cat > "$handoff_bad" <<'EOF'
# Handoff

## evil*name

(none)
EOF
if command -v cygpath >/dev/null 2>&1; then
    handoff_bad_norm=$(cygpath -m "$handoff_bad")
else
    handoff_bad_norm="$handoff_bad"
fi
python "$handoff_py_norm" add_section "$handoff_bad_norm" "evil*name" > "$reject_log" 2>&1
add_rc=$?
assert_ne "add_section rejects '*' in device name" "0" "$add_rc"
assert_in_file "rejection mentions markdown-format reason" "markdown" "$reject_log"
dump_logs_on_failure "$detect_log" "$reject_log"

# --- Test 13: _safe_bak refuses pre-existing symlink at fallback ---
echo ""
echo "[test 13] _safe_bak refuses symlink-occupied .bak.<epoch> fallback"
# Stage: target exists, target.bak exists (forces the timestamp fallback),
# AND the predicted target.bak.<epoch> is a symlink to a victim file outside
# the dotfiles tree. Without the fallback symlink-check, cp -p would follow
# the symlink and overwrite the victim. With the check, _safe_bak refuses
# (rc≠0) and the victim is preserved.
safebak_dir="$TESTROOT/safebak_arena"
mkdir -p "$safebak_dir"
safebak_target="$safebak_dir/target.md"
safebak_victim="$TESTROOT/safebak_victim.md"
echo "TARGET CONTENT (would propagate through symlink)" > "$safebak_target"
echo "VICTIM CONTENT - must remain unchanged" > "$safebak_victim"
# Force the fallback: primary .bak slot occupied
echo "primary .bak slot — forces fallback" > "${safebak_target}.bak"
# Predict the epoch and pre-place a symlink at the predicted fallback path.
# Try a small window (delta 0..3) to absorb the second-boundary race in case
# the test takes >1s to set up.
predicted_epoch=$(date +%s)
for delta in 0 1 2 3; do
    ln -s "$safebak_victim" "${safebak_target}.bak.$((predicted_epoch + delta))" 2>/dev/null || true
done

safebak_log="$TESTROOT/safebak.log"
{
    echo "SCRIPT_DIR=\"$PROJECT_DIR\""
    echo "source \"$COMMON_SH\""
    echo ''
    cat <<TEST_BODY
result=\$(_safe_bak "$safebak_target" 2>&1)
rc=\$?
echo "RC=\$rc"
echo "RESULT=\$result"
TEST_BODY
} | bash > "$safebak_log" 2>&1

assert_in_file_re "_safe_bak returns rc=1 when fallback is symlink-occupied" "^RC=1$" "$safebak_log"
assert_in_file "rejection message names the symlink concern" "符号链接" "$safebak_log"
# Read victim content fresh — if cp followed the symlink, this would show
# TARGET CONTENT instead of VICTIM CONTENT.
victim_now=$(cat "$safebak_victim")
assert_eq "victim file content unchanged" "VICTIM CONTENT - must remain unchanged" "$victim_now"
dump_logs_on_failure "$safebak_log"

# Sanity: when no symlink is pre-placed, _safe_bak still succeeds (regression
# guard so the new check doesn't accidentally break the happy path).
safebak_clean_dir="$TESTROOT/safebak_clean"
mkdir -p "$safebak_clean_dir"
clean_target="$safebak_clean_dir/file.md"
echo "clean content" > "$clean_target"
clean_bak_log="$TESTROOT/safebak_clean.log"
{
    echo "SCRIPT_DIR=\"$PROJECT_DIR\""
    echo "source \"$COMMON_SH\""
    echo ''
    cat <<TEST_BODY
result=\$(_safe_bak "$clean_target" 2>&1)
echo "RC=\$?"
echo "RESULT=\$result"
TEST_BODY
} | bash > "$clean_bak_log" 2>&1
assert_in_file_re "_safe_bak succeeds on clean target" "^RC=0$" "$clean_bak_log"
assert_in_file "_safe_bak prints expected .bak path on clean target" "${clean_target}.bak" "$clean_bak_log"
# Counter (mirrors Test 16's counter-assert): the substring assert above is also
# satisfied by a .bak.<epoch> fallback regression; pin that the clean path used
# the primary slot, NOT the timestamped fallback.
assert_not_in_file "clean target uses primary .bak, not timestamped fallback" "${clean_target}.bak." "$clean_bak_log"
dump_logs_on_failure "$clean_bak_log"

# --- Test 14: skill-import refuses dotfiles source with nested symlinks ---
echo ""
echo "[test 14] skill-import accept refuses when source contains nested symlinks"
# The two SKILL_IMPORT accept sites (skill-import subcommand + interactive
# sync_custom_skills) must refuse a symlinked source BEFORE any copy —
# cp-then-strip ordering is unsafe. The threat is intra-process: sync_custom_skills'
# fall-through invokes sync_config_file per file IMMEDIATELY after cp, before
# the post-cp `find -type l -delete` sweep fires. A nested symlink that
# survives the cp window can be deref'd by that consumer.
#
# Fixture strategy: set up the skill via git (clean files only), pull to
# DOTFILES_B, then inject the symlink DIRECTLY into DOTFILES_B's working
# tree — bypasses the git symlink-materialization layer (Windows Git Bash
# defaults to core.symlinks=false, which would otherwise produce a plain
# text file and make the attack non-applicable on this platform).
victim_target="$TESTROOT/victim_for_skill_import.md"
echo "VICTIM CONTENT - skill-import must not surface this through a symlink" > "$victim_target"

(
    cd "$DOTFILES_A" || exit 1
    git pull --quiet --rebase 2>/dev/null || true
    mkdir -p claude/skills/nested-evil
    cat > claude/skills/nested-evil/SKILL.md <<'EOF'
---
name: nested-evil
description: Tests the symlink defense — fixture is plain files via git, symlink injected post-pull
---
# Nested Evil
EOF
    git add claude/skills/nested-evil
    git commit --quiet -m "add nested-evil skill (plain files)"
    git push --quiet origin master
)
(cd "$DOTFILES_B" && git pull --quiet --rebase 2>/dev/null || true)

# Inject the symlink directly into DOTFILES_B's working tree post-pull,
# simulating what an adversary push would land on a platform that
# materializes git symlinks as real symlinks (Linux/macOS, or Windows
# Git Bash with core.symlinks=true + symlink privilege).
ln -s "$victim_target" "$DOTFILES_B/claude/skills/nested-evil/loot" 2>/dev/null || true

if [ ! -L "$DOTFILES_B/claude/skills/nested-evil/loot" ]; then
    echo "  (skipping symlink-fixture assertions: this platform doesn't produce real symlinks via ln -s — the attack class doesn't manifest here, so no test signal available)"
else
    # Run sync first so SKILL_IMPORT block gets emitted
    log_pre_i1="$TESTROOT/sync_pre_i1.log"
    SYNC_TEST_MODE=1 \
      SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
      HOME="$HOME_TEST" \
      bash "$SYNC_SH" >"$log_pre_i1" 2>&1
    assert_in_file "SKILL_IMPORT block emitted for nested-evil" "SKILL_NAME: nested-evil" "$log_pre_i1"

    accept_log="$TESTROOT/skill_import_nested_evil.log"
    SYNC_TEST_MODE=1 \
      SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
      HOME="$HOME_TEST" \
      bash "$SYNC_SH" skill-import --action=accept --skill-name=nested-evil \
      >"$accept_log" 2>&1
    accept_rc=$?
    assert_ne "skill-import accept refuses (rc≠0) when source contains symlinks" "0" "$accept_rc"
    assert_in_file "rejection message names the symlink concern" "符号链接" "$accept_log"
    assert_file_absent "local mirror NOT created" "$HOME_TEST/.claude/skills/nested-evil/SKILL.md"
    assert_file_absent "loot symlink did NOT propagate" "$HOME_TEST/.claude/skills/nested-evil/loot"
    victim_after=$(cat "$victim_target")
    assert_eq "victim file unchanged" "VICTIM CONTENT - skill-import must not surface this through a symlink" "$victim_after"
    dump_logs_on_failure "$accept_log"
fi

# Sanity: a clean skill (no symlinks) still accepts successfully — happy-path
# regression guard for the _has_symlinks helper. Runs on every platform.
(
    cd "$DOTFILES_A" || exit 1
    git pull --quiet --rebase 2>/dev/null || true
    mkdir -p claude/skills/clean-skill
    cat > claude/skills/clean-skill/SKILL.md <<'EOF'
---
name: clean-skill
description: No symlinks, should accept normally
---
EOF
    git add claude/skills/clean-skill
    git commit --quiet -m "add clean-skill"
    git push --quiet origin master
)
(cd "$DOTFILES_B" && git pull --quiet --rebase 2>/dev/null || true)
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >/dev/null 2>&1
clean_accept_log="$TESTROOT/skill_import_clean.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" skill-import --action=accept --skill-name=clean-skill \
  >"$clean_accept_log" 2>&1
clean_rc=$?
assert_eq "skill-import accept succeeds on symlink-free source" "0" "$clean_rc"
assert_file_exists "clean-skill mirrored under HOME/.claude" "$HOME_TEST/.claude/skills/clean-skill/SKILL.md"

# --- Test 15: .bak.<epoch> + <name>.bak/ filtered from dotfiles propagation ---
echo ""
echo "[test 15] .bak.<epoch> files and <name>.bak/ dirs do not propagate to dotfiles"
# _safe_bak's timestamp fallback (`<target>.bak.<epoch>`) must be excluded
# alongside plain *.bak at three sync sites:
#   1. sync_commit_push pathspec
#   2. step 6 python status filter
#   3. sync_custom_skills LOCAL_SKILLS scan
# If any site only matches plain *.bak, a timestamp-fallback backup in
# DOTFILES_DIR commits + propagates, and a stranded <name>.bak/ left behind by
# interrupted cmd_update mirrors as if it were a custom skill. Assert both
# layers filter.

# Sub-test 15a: <file>.bak.<epoch> in dotfiles tree is NOT committed
bak_test_file="$DOTFILES_B/claude/leftover.bak.1718284800"
echo "stale backup content" > "$bak_test_file"
# Record HEAD before sync; after sync the bare repo HEAD should be unchanged
# (no commit landed) — verifies both the status filter (step 6 doesn't even
# call sync_commit_push) and the pathspec (would skip the file even if
# sync_commit_push fired).
head_before=$(git --git-dir="$DOTFILES_BARE" rev-parse HEAD)
log15a="$TESTROOT/sync15a.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log15a" 2>&1
head_after=$(git --git-dir="$DOTFILES_BARE" rev-parse HEAD)
assert_eq "dotfiles HEAD unchanged (no commit for .bak.<epoch> file)" "$head_before" "$head_after"
HEAD_TREE_FILES=$(git --git-dir="$DOTFILES_BARE" ls-tree -r --name-only HEAD)
assert_not_in_var ".bak.<epoch> file NOT in bare repo tree" "leftover.bak" "$HEAD_TREE_FILES"
# File still exists on disk (filter only suppresses commit, doesn't delete)
assert_file_exists "stale .bak.<epoch> still present locally (filter doesn't delete)" "$bak_test_file"
# Clean up so subsequent tests aren't polluted
rm -f "$bak_test_file"

# Sub-test 15b: <name>.bak/ under LOCAL_SKILLS is NOT mirrored to dotfiles
mkdir -p "$HOME_TEST/.claude/skills/orphaned.bak"
cat > "$HOME_TEST/.claude/skills/orphaned.bak/SKILL.md" <<'EOF'
---
name: orphaned
description: leftover .bak/ from interrupted cmd_update — must NOT mirror
---
EOF
# Also drop a .bak.<epoch>/ variant — different pattern but same filter
mkdir -p "$HOME_TEST/.claude/skills/orphaned.bak.1718284800"
echo "fallback variant" > "$HOME_TEST/.claude/skills/orphaned.bak.1718284800/marker.txt"

log15b="$TESTROOT/sync15b.log"
SYNC_TEST_MODE=1 \
  SYNC_TEST_DOTFILES_PATH="$DOTFILES_B" \
  HOME="$HOME_TEST" \
  bash "$SYNC_SH" >"$log15b" 2>&1

assert_file_absent "orphaned.bak/ NOT mirrored to dotfiles" "$DOTFILES_B/claude/skills/orphaned.bak/SKILL.md"
assert_file_absent "orphaned.bak.<epoch>/ NOT mirrored to dotfiles" "$DOTFILES_B/claude/skills/orphaned.bak.1718284800/marker.txt"
# Local copies still exist (filter only suppresses mirroring, doesn't delete)
assert_file_exists "orphaned.bak/ still present locally" "$HOME_TEST/.claude/skills/orphaned.bak/SKILL.md"
dump_logs_on_failure "$log15a" "$log15b"

# --- Test 16: _safe_bak_path covers primary / fallback / refusal cases ---
echo ""
echo "[test 16] _safe_bak_path: primary slot, fallback, refusal on symlink-occupied fallback"
# _safe_bak_path lives in lib/common.sh and is
# consumed by both sync.sh (via _safe_bak for snapshot) and module-manager.sh
# (cmd_update directly for displacement). Exercise the three paths.

sbp_dir="$TESTROOT/safe_bak_path_arena"
mkdir -p "$sbp_dir"
sbp_log="$TESTROOT/sbp.log"
# Capture the epoch ONCE in the outer shell and share it with both the symlink
# setup (inside the heredoc) and the skip-guard below — re-sampling date +%s in
# the guard could miss the created slots on a slow run and silently skip CASE3.
case3_epoch=$(date +%s)
{
    echo "SCRIPT_DIR=\"$PROJECT_DIR\""
    echo "source \"$COMMON_SH\""
    cat <<TEST_BODY
# Case 1: target exists, .bak slot free → returns target.bak
echo "case1" > "$sbp_dir/case1"
out=\$(_safe_bak_path "$sbp_dir/case1")
echo "CASE1_RC=\$?"
echo "CASE1_OUT=\$out"

# Case 2: target.bak occupied → returns target.bak.<epoch>
echo "case2" > "$sbp_dir/case2"
echo "occupied" > "$sbp_dir/case2.bak"
out=\$(_safe_bak_path "$sbp_dir/case2")
echo "CASE2_RC=\$?"
echo "CASE2_OUT=\$out"

# Case 3: target.bak occupied AND target.bak.<predicted-epoch> is a symlink → rc 1
echo "case3" > "$sbp_dir/case3"
echo "occupied" > "$sbp_dir/case3.bak"
victim="$sbp_dir/victim.txt"
echo "victim" > "\$victim"
predicted=$case3_epoch
for delta in 0 1 2 3; do
    ln -s "\$victim" "$sbp_dir/case3.bak.\$((predicted + delta))" 2>/dev/null || true
done
out=\$(_safe_bak_path "$sbp_dir/case3" 2>&1)
echo "CASE3_RC=\$?"
echo "CASE3_OUT=\$out"
TEST_BODY
} | bash > "$sbp_log" 2>&1

assert_in_file_re "case 1 rc=0 (primary slot free)" "^CASE1_RC=0$" "$sbp_log"
assert_in_file "case 1 returns primary .bak path" "CASE1_OUT=$sbp_dir/case1.bak" "$sbp_log"
# Counter-assertion: if _safe_bak_path regressed to always returning the
# timestamped fallback, the line above's substring match would still pass
# (CASE1_OUT=…/case1.bak.<epoch> contains CASE1_OUT=…/case1.bak as a prefix).
# This negative pin closes the wrong-direction-pass gap.
assert_not_in_file "case 1 does NOT use timestamped fallback" "CASE1_OUT=$sbp_dir/case1.bak." "$sbp_log"
assert_in_file_re "case 2 rc=0 (fallback)" "^CASE2_RC=0$" "$sbp_log"
assert_in_file "case 2 returns timestamped .bak.<epoch> path" "CASE2_OUT=$sbp_dir/case2.bak." "$sbp_log"

# Case 3 depends on ln -s producing a real symlink (Windows Git Bash without
# core.symlinks may produce a plain text file instead, in which case the
# attack class doesn't manifest and _safe_bak_path returns rc 0).
if [ -L "$sbp_dir/case3.bak.$((case3_epoch))" ] || [ -L "$sbp_dir/case3.bak.$((case3_epoch + 1))" ] || [ -L "$sbp_dir/case3.bak.$((case3_epoch + 2))" ] || [ -L "$sbp_dir/case3.bak.$((case3_epoch + 3))" ]; then
    assert_in_file_re "case 3 rc=1 (refuses symlink-occupied fallback)" "^CASE3_RC=1$" "$sbp_log"
    assert_in_file "case 3 rejection message names path concern" "已被占用" "$sbp_log"
else
    echo "  (case 3 skipped: ln -s didn't produce real symlinks on this platform)"
fi
dump_logs_on_failure "$sbp_log"

# --- Test 17: manifest-read auto-migrates legacy entries (pin = commit_sha) ---
echo ""
echo "[test 17] manifest-read auto-migrates legacy entries (commit_sha → pin)"
# Modules predating the pin-field exist in the wild on long-running machines.
# manifest-read silently fills pin = commit_sha so the rest of the pipeline
# (cmd_update, cmd_check) can rely on pin being present. Verify migration
# happens on the JSON output AND that the pin === commit_sha invariant holds.
MODULE_HELPER="$PROJECT_DIR/lib/module_helper.py"
MODULE_MANAGER="$PROJECT_DIR/module-manager.sh"

t17_dir="$TESTROOT/test17"
mkdir -p "$t17_dir"
cat > "$t17_dir/modules.toml" <<'TOML'
version = 1

[modules."legacy"]
type = "skill"
install_path = "legacy"
commit_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
installed_at = "2026-01-01"
last_updated = "2026-01-01"

[modules."legacy".source]
kind = "github-repo"
repo = "owner/legacy"
ref = "main"
TOML

t17_out=$(PYTHONIOENCODING=utf-8 python "$MODULE_HELPER" manifest-read "$t17_dir/modules.toml" 2>&1)
assert_in_var "legacy commit_sha preserved" '"commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$t17_out"
assert_in_var "legacy pin auto-filled from commit_sha" '"pin": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$t17_out"

# A modern entry (pin already present, distinct from commit_sha) must NOT be
# rewritten — auto-migration only fires when pin is missing.
cat > "$t17_dir/modern.toml" <<'TOML'
version = 1

[modules."modern"]
type = "skill"
install_path = "modern"
commit_sha = "cccccccccccccccccccccccccccccccccccccccc"
pin = "dddddddddddddddddddddddddddddddddddddddd"
installed_at = "2026-01-01"
last_updated = "2026-01-01"

[modules."modern".source]
kind = "github-repo"
repo = "owner/modern"
ref = "main"
TOML
t17_modern=$(PYTHONIOENCODING=utf-8 python "$MODULE_HELPER" manifest-read "$t17_dir/modern.toml" 2>&1)
assert_in_var "modern entry's pin preserved (NOT overwritten)" '"pin": "dddddddddddddddddddddddddddddddddddddddd"' "$t17_modern"
assert_in_var "modern entry's commit_sha preserved" '"commit_sha": "cccccccccccccccccccccccccccccccccccccccc"' "$t17_modern"

# --- Test 18: bump --to rejects malformed SHA before any network call ---
echo ""
echo "[test 18] bump --to rejects malformed SHA at the regex boundary"
# The 40-hex regex fires before verify-sha → gh api → network. Pass a clearly
# non-SHA string and confirm rejection without any GH_CMD invocation.
t18_home="$TESTROOT/test18-home"
mkdir -p "$t18_home/.claude/skills"
cat > "$t18_home/.claude/skills/modules.toml" <<'TOML'
version = 1

[modules."m1"]
type = "skill"
install_path = "m1"
commit_sha = "1111111111111111111111111111111111111111"
pin = "1111111111111111111111111111111111111111"
installed_at = "2026-01-01"
last_updated = "2026-01-01"

[modules."m1".source]
kind = "github-repo"
repo = "owner/m1"
ref = "main"
TOML

# Force the absence of `gh` so any accidental network attempt would fail
# loudly. Tests that legitimately need a fake gh override GH explicitly.
t18_log="$TESTROOT/t18.log"
GH=/dev/null/nonexistent HOME="$t18_home" \
    bash "$MODULE_MANAGER" bump m1 --to "not-a-sha" >"$t18_log" 2>&1
t18_rc=$?
assert_ne "bump --to with non-hex string exits non-zero" "0" "$t18_rc"
assert_in_file "rejection message names 40-char hex requirement" "40 字符十六进制" "$t18_log"

# Also reject a 39-character all-hex string (one char short — boundary case).
GH=/dev/null/nonexistent HOME="$t18_home" \
    bash "$MODULE_MANAGER" bump m1 --to "$(printf 'a%.0s' {1..39})" >>"$t18_log" 2>&1
t18b_rc=$?
assert_ne "bump --to with 39-hex (under-length) exits non-zero" "0" "$t18b_rc"

# And reject --to + --latest combined.
GH=/dev/null/nonexistent HOME="$t18_home" \
    bash "$MODULE_MANAGER" bump m1 --to "0000000000000000000000000000000000000000" --latest \
    >>"$t18_log" 2>&1
t18c_rc=$?
assert_ne "bump --to combined with --latest exits non-zero" "0" "$t18c_rc"
assert_in_file "combined --to + --latest names the conflict" "--to 与 --latest 不能同时使用" "$t18_log"

# Over-limit boundary: 41 hex chars must be rejected by the $-anchored regex.
# Without this pin a regression loosening ^[0-9a-f]{40}$ to {40,} would accept
# the 40-char prefix and ship green.
GH=/dev/null/nonexistent HOME="$t18_home" \
    bash "$MODULE_MANAGER" bump m1 --to "$(printf 'a%.0s' {1..41})" >>"$t18_log" 2>&1
t18d_rc=$?
assert_ne "bump --to with 41-hex (over-length) exits non-zero" "0" "$t18d_rc"
assert_in_file "41-hex rejection names the 40-char hex requirement" "40 字符十六进制" "$t18_log"

# At-limit accept side: a valid 40-hex passes the regex. With gh absent the
# command may still fail downstream, but it must NOT be the regex-rejection
# message — proves the regex ACCEPTS a valid SHA (a reject-everything regex
# would satisfy all the negative cases above). Separate log so the earlier
# rejection messages don't pollute the assert.
t18_accept_log="$TESTROOT/t18_accept.log"
GH=/dev/null/nonexistent HOME="$t18_home" \
    bash "$MODULE_MANAGER" bump m1 --to "$(printf 'a%.0s' {1..40})" >"$t18_accept_log" 2>&1
assert_not_in_file "valid 40-hex is NOT rejected by the SHA regex" "40 字符十六进制" "$t18_accept_log"
dump_logs_on_failure "$t18_log" "$t18_accept_log"

# --- Test 19: bump --latest refuses without prior check ---
echo ""
echo "[test 19] bump --latest refuses without a recorded candidate"
# If the user runs bump --latest before check, there is no candidate in the
# sidecar. cmd_check_candidate_verify exits 1 with a "no candidate, run
# check first" message — no upstream query happens.
t19_home="$TESTROOT/test19-home"
mkdir -p "$t19_home/.claude/skills"
cp "$t18_home/.claude/skills/modules.toml" "$t19_home/.claude/skills/modules.toml"

# Make sure no sidecar exists.
[ -f "$t19_home/.claude/skills/.check_state.json" ] && rm "$t19_home/.claude/skills/.check_state.json"

t19_log="$TESTROOT/t19.log"
GH=/dev/null/nonexistent HOME="$t19_home" \
    bash "$MODULE_MANAGER" bump m1 --latest >"$t19_log" 2>&1
t19_rc=$?
assert_ne "bump --latest without check exits non-zero" "0" "$t19_rc"
assert_in_file "rejection names 'no candidate' state" "没有已审阅的候选 SHA" "$t19_log"
dump_logs_on_failure "$t19_log"

# --- Test 20: bump --latest refuses on stale candidate (>24h) ---
echo ""
echo "[test 20] bump --latest refuses on stale candidate"
# Plant a sidecar entry with a checked_at 25 hours in the past. The staleness
# branch fires BEFORE the gh query, so GH being unavailable doesn't affect
# the test — staleness is detected purely from the timestamp.
t20_home="$TESTROOT/test20-home"
mkdir -p "$t20_home/.claude/skills"
cp "$t18_home/.claude/skills/modules.toml" "$t20_home/.claude/skills/modules.toml"

# Compute a UTC ISO-8601 timestamp 25 hours ago (portable across GNU+BSD).
t20_stale_ts=$(python -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=25)).isoformat(timespec='seconds'))")
cat > "$t20_home/.claude/skills/.check_state.json" <<JSON
{
  "candidates": {
    "m1": {"sha": "2222222222222222222222222222222222222222", "checked_at": "$t20_stale_ts"}
  }
}
JSON

t20_log="$TESTROOT/t20.log"
GH=/dev/null/nonexistent HOME="$t20_home" \
    bash "$MODULE_MANAGER" bump m1 --latest >"$t20_log" 2>&1
t20_rc=$?
assert_ne "bump --latest on stale candidate exits non-zero" "0" "$t20_rc"
assert_in_file "rejection names expiry" "候选 SHA 已过期" "$t20_log"
dump_logs_on_failure "$t20_log"

# Just-under-boundary counter-test (pins the 24h edge from below): a candidate
# 23 h old must PASS the staleness gate. With gh unavailable it still fails at
# the later upstream query, but NOT with the expiry message — proving 23h<24h
# isn't treated as stale. Without this, a regression tightening the window
# (e.g. >12h) would ship green.
t20_fresh_ts=$(python -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=23)).isoformat(timespec='seconds'))")
cat > "$t20_home/.claude/skills/.check_state.json" <<JSON
{
  "candidates": {
    "m1": {"sha": "2222222222222222222222222222222222222222", "checked_at": "$t20_fresh_ts"}
  }
}
JSON
t20b_log="$TESTROOT/t20b.log"
GH=/dev/null/nonexistent HOME="$t20_home" \
    bash "$MODULE_MANAGER" bump m1 --latest >"$t20b_log" 2>&1
assert_not_in_file "23h candidate is NOT treated as stale (24h edge pinned from below)" "候选 SHA 已过期" "$t20b_log"
dump_logs_on_failure "$t20b_log"

# --- Test 21: bump --latest refuses when upstream moves between check and bump ---
echo ""
echo "[test 21] bump --latest refuses on upstream-SHA mismatch (TOCTOU defense)"
# Plant a fresh candidate + stand up a fake gh that returns a DIFFERENT SHA
# than the candidate. cmd_check_candidate_verify queries fake-gh, compares
# against the planted candidate, and refuses. This is the central TOCTOU
# defense the pin-model commits added.
t21_home="$TESTROOT/test21-home"
mkdir -p "$t21_home/.claude/skills"
cp "$t18_home/.claude/skills/modules.toml" "$t21_home/.claude/skills/modules.toml"

# Plant a fresh candidate SHA the user "reviewed" (call it OLD).
t21_fresh_ts=$(python -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec='seconds'))")
t21_old_sha="3333333333333333333333333333333333333333"
t21_new_sha="4444444444444444444444444444444444444444"
cat > "$t21_home/.claude/skills/.check_state.json" <<JSON
{
  "candidates": {
    "m1": {"sha": "$t21_old_sha", "checked_at": "$t21_fresh_ts"}
  }
}
JSON

# Fake gh: emits $MM_TEST_GH_SHA for any `api repos/.../commits/...` query.
# Written in Python so Windows subprocess.run can invoke it (bash-shebang
# scripts hit WinError 193 from CreateProcess). The launcher is a .bat
# wrapper on Windows (cmd.exe loads .bat/.cmd via CreateProcess) and a
# bash shebang script on POSIX.
cat > "$TESTROOT/fake-gh.py" <<'FAKE_GH_PY'
#!/usr/bin/env python
import os
import sys
args = sys.argv[1:]
# Match `api <endpoint> [-q .sha]` where the endpoint contains "commits".
if len(args) >= 2 and args[0] == "api" and "commits" in args[1]:
    sys.stdout.write(os.environ.get("MM_TEST_GH_SHA", ""))
    sys.exit(0)
sys.exit(1)
FAKE_GH_PY
if [[ "${OS:-}" == "Windows_NT" ]] || [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]]; then
    fakegh_py_winpath="$(cygpath -w "$TESTROOT/fake-gh.py" 2>/dev/null || echo "$TESTROOT/fake-gh.py")"
    cat > "$TESTROOT/fake-gh.bat" <<BAT
@python "$fakegh_py_winpath" %*
BAT
    FAKE_GH="$TESTROOT/fake-gh.bat"
else
    cat > "$TESTROOT/fake-gh.sh" <<'FAKE_GH_SH'
#!/bin/bash
exec python "$(dirname "$0")/fake-gh.py" "$@"
FAKE_GH_SH
    chmod +x "$TESTROOT/fake-gh.sh"
    FAKE_GH="$TESTROOT/fake-gh.sh"
fi

t21_log="$TESTROOT/t21.log"
GH="$FAKE_GH" MM_TEST_GH_SHA="$t21_new_sha" HOME="$t21_home" \
    bash "$MODULE_MANAGER" bump m1 --latest >"$t21_log" 2>&1
t21_rc=$?
assert_ne "bump --latest with upstream moved exits non-zero" "0" "$t21_rc"
assert_in_file "rejection names upstream-changed condition" "上游 SHA 在 check 之后发生变化" "$t21_log"
assert_in_file "rejection shows old SHA prefix" "${t21_old_sha:0:8}" "$t21_log"
assert_in_file "rejection shows new SHA prefix" "${t21_new_sha:0:8}" "$t21_log"

# Sanity check the opposite direction: same SHA in candidate AND upstream →
# bump succeeds (proves the test infrastructure isn't trivially failing).
cat > "$t21_home/.claude/skills/.check_state.json" <<JSON
{
  "candidates": {
    "m1": {"sha": "$t21_new_sha", "checked_at": "$t21_fresh_ts"}
  }
}
JSON
GH="$FAKE_GH" MM_TEST_GH_SHA="$t21_new_sha" HOME="$t21_home" \
    bash "$MODULE_MANAGER" bump m1 --latest >>"$t21_log" 2>&1
t21b_rc=$?
assert_eq "bump --latest succeeds when candidate matches upstream" "0" "$t21b_rc"
dump_logs_on_failure "$t21_log"

# --- Test 22: update --all is a no-op when all pin == commit_sha ---
echo ""
echo "[test 22] update --all silently skips when pin == commit_sha (steady state)"
# The pin model's correctness pivot: update no longer rolls tip-of-branch.
# A manifest where every module has pin == commit_sha should produce zero
# network calls and exit 0 with "all up to date".
t22_home="$TESTROOT/test22-home"
mkdir -p "$t22_home/.claude/skills"
# Two modules, both at steady state.
cat > "$t22_home/.claude/skills/modules.toml" <<'TOML'
version = 1

[modules."steady-a"]
type = "skill"
install_path = "steady-a"
commit_sha = "5555555555555555555555555555555555555555"
pin = "5555555555555555555555555555555555555555"
installed_at = "2026-01-01"
last_updated = "2026-01-01"

[modules."steady-a".source]
kind = "github-repo"
repo = "owner/steady-a"
ref = "main"

[modules."steady-b"]
type = "skill"
install_path = "steady-b"
commit_sha = "6666666666666666666666666666666666666666"
pin = "6666666666666666666666666666666666666666"
installed_at = "2026-01-01"
last_updated = "2026-01-01"

[modules."steady-b".source]
kind = "github-repo"
repo = "owner/steady-b"
ref = "main"
TOML

# Use a gh stub that always exits non-zero to detect any accidental network call.
cat > "$TESTROOT/no-net-gh" <<'NO_NET'
#!/bin/bash
echo "fake-gh: should not have been called" >&2
exit 99
NO_NET
chmod +x "$TESTROOT/no-net-gh"

t22_log="$TESTROOT/t22.log"
GH="$TESTROOT/no-net-gh" HOME="$t22_home" \
    bash "$MODULE_MANAGER" update --all >"$t22_log" 2>&1
t22_rc=$?
assert_eq "update --all at steady state exits 0" "0" "$t22_rc"
assert_in_file "update --all reports 'all up to date'" "All modules up to date" "$t22_log"
# The no-net-gh canary message should NOT appear — update without diffs makes
# no upstream queries.
assert_not_in_file "no accidental network call (gh stub silent)" "fake-gh: should not have been called" "$t22_log"
dump_logs_on_failure "$t22_log"

# --- Test 23: _normalize_git_url collapses SSH/HTTPS/scp forms ---
echo ""
echo "[test 23] _normalize_git_url normalizes equivalent remote URLs equal"
# Extract the helper from sync.sh (no external deps) and exercise the URL
# grammar: the SSH-migration scenario (local remote moved from https to ssh)
# depends on https/ssh/scp forms of one repo comparing equal AND on genuinely
# different repos staying unequal. Also pins the .git-vs-trailing-slash strip
# order and the host case-fold behavior.
norm_fn=$(sed -n '/^_normalize_git_url() {/,/^}/p' "$SYNC_SH")
if [ -z "$norm_fn" ]; then
    fail "could not extract _normalize_git_url from sync.sh (renamed?)"
else
    norm_log="$TESTROOT/normalize.log"
    {
        printf '%s\n\n' "$norm_fn"
        cat <<'DRIVER'
canon="github.com/example-user/example-repo"
for u in \
  "https://github.com/example-user/example-repo" \
  "https://github.com/example-user/example-repo.git" \
  "git@github.com:example-user/example-repo.git" \
  "ssh://git@github.com/example-user/example-repo.git" \
  "https://github.com:443/example-user/example-repo.git" \
  "ssh://git@github.com:22/example-user/example-repo.git" \
  "https://github.com/example-user/example-repo.git/" \
  "git@GitHub.com:example-user/example-repo.git" ; do
    [ "$(_normalize_git_url "$u")" = "$canon" ] || echo "EQUAL_FAIL: $u -> $(_normalize_git_url "$u")"
done
echo "EQUAL_DONE"
[ "$(_normalize_git_url "git@github.com:other/example-repo.git")" != "$canon" ] && echo "DIFF_OWNER_OK"
[ "$(_normalize_git_url "git@gitlab.com:example-user/example-repo.git")" != "$canon" ] && echo "DIFF_HOST_OK"
# ssh 默认端口是 22，:443 属非默认端口须保留——是不同的端点声明，不得折叠为无端口形式
[ "$(_normalize_git_url "ssh://git@github.com:443/example-user/example-repo.git")" != "$canon" ] && echo "DIFF_PORT_OK"
[ -z "$(_normalize_git_url "")" ] && echo "EMPTY_OK"
[ "$(_normalize_git_url "owner/repo.git")" = "owner/repo" ] && echo "FALLTHROUGH_OK"
DRIVER
    } | bash > "$norm_log" 2>&1
    assert_not_in_file "all equivalent URL forms normalize to the canonical repo" "EQUAL_FAIL" "$norm_log"
    assert_in_file "equivalence loop ran to completion" "EQUAL_DONE" "$norm_log"
    assert_in_file "different owner does not collapse to canon" "DIFF_OWNER_OK" "$norm_log"
    assert_in_file "different host does not collapse to canon" "DIFF_HOST_OK" "$norm_log"
    assert_in_file "non-default ssh port does not collapse to canon" "DIFF_PORT_OK" "$norm_log"
    assert_in_file "empty input normalizes to empty" "EMPTY_OK" "$norm_log"
    assert_in_file "unrecognized form returns input after .git/slash trim" "FALLTHROUGH_OK" "$norm_log"
    dump_logs_on_failure "$norm_log"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo " Results: $pass_count passed, $fail_count failed"
echo "=========================================="

if [ $fail_count -gt 0 ]; then
    exit 1
fi
exit 0
