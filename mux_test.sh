#!/usr/bin/env bash
# mux_test.sh — Integration tests for the mux tool
# Run with: ./mux_test.sh (sudo password will be prompted for mount ops)
# All tests use temporary directories — no risk to real repos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUX="${SCRIPT_DIR}/mux"
TMPBASE=""
PASS=0
FAIL=0

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

setup() {
    TMPBASE="$(mktemp -d /tmp/mux_test.XXXXXX)"
    echo -e "${BOLD}Test workspace: ${TMPBASE}${NC}"

    # Create fake repos at "external" paths
    REPO_A="${TMPBASE}/external/project/a"
    REPO_B="${TMPBASE}/external/build/b"
    REPO_C="${TMPBASE}/external/firmware/c"
    WORKSPACE="${TMPBASE}/workspace"

    mkdir -p "$REPO_A" "$REPO_B" "$REPO_C" "$WORKSPACE"

    # Initialize repo a with git and a file
    cd "$REPO_A"
    git init -q
    git config user.email "test@mux.dev"
    git config user.name "mux-test"
    echo "original_a" > file_a.txt
    git add . && git commit -q -m "init a"

    # Initialize repo b with git and a file
    cd "$REPO_B"
    git init -q
    git config user.email "test@mux.dev"
    git config user.name "mux-test"
    echo "original_b" > file_b.txt
    git add . && git commit -q -m "init b"

    # Initialize repo c with git and a file
    cd "$REPO_C"
    git init -q
    git config user.email "test@mux.dev"
    git config user.name "mux-test"
    echo "original_c" > file_c.txt
    mkdir -p src
    echo "int main() { return 0; }" > src/main.c
    git add . && git commit -q -m "init c"

    cd "$WORKSPACE"
    echo ""
}

# Track all mounts we create so cleanup is thorough
MOUNTS_CREATED=()

cleanup() {
    echo ""
    echo -e "${BOLD}Cleaning up...${NC}"
    # Unmount everything in reverse order
    for mp in $(echo "${MOUNTS_CREATED[@]:-}" | tr ' ' '\n' | tac); do
        if sudo findmnt -rn "$mp" >/dev/null 2>&1; then
            sudo umount "$mp" 2>/dev/null || true
        fi
    done
    # Also try unmounting known paths
    for path in "${REPO_A:-}" "${REPO_B:-}" "${REPO_C:-}" \
                "${REPO_A:-}_1" "${REPO_A:-}_2" "${REPO_A:-}_3" \
                "${REPO_B:-}_1" "${REPO_B:-}_2" "${REPO_B:-}_3" \
                "${REPO_C:-}_1" "${REPO_C:-}_2" "${REPO_C:-}_3" \
                "${REPO_C:-}_agent1" "${REPO_C:-}_agent2"; do
        if [[ -n "$path" ]] && sudo findmnt -rn "$path" >/dev/null 2>&1; then
            sudo umount "$path" 2>/dev/null || true
        fi
    done
    # Unmount origin references
    if [[ -n "${WORKSPACE:-}" && -d "${WORKSPACE}/.mux/origins" ]]; then
        for origin_dir in "${WORKSPACE}/.mux/origins"/*/; do
            if [[ -d "$origin_dir" ]] && sudo findmnt -rn "$origin_dir" >/dev/null 2>&1; then
                sudo umount "$origin_dir" 2>/dev/null || true
            fi
        done
    fi
    if [[ -n "$TMPBASE" && -d "$TMPBASE" ]]; then
        rm -rf "$TMPBASE"
    fi
    echo -e "${BOLD}Done.${NC}"
}

trap cleanup EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        (( ++PASS ))
    else
        echo -e "  ${RED}✗${NC} ${desc}"
        echo -e "    expected: ${expected}"
        echo -e "    actual:   ${actual}"
        (( ++FAIL ))
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -e "$path" ]]; then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        (( ++PASS ))
    else
        echo -e "  ${RED}✗${NC} ${desc}: file not found: ${path}"
        (( ++FAIL ))
    fi
}

assert_file_not_exists() {
    local desc="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        (( ++PASS ))
    else
        echo -e "  ${RED}✗${NC} ${desc}: file unexpectedly exists: ${path}"
        (( ++FAIL ))
    fi
}

assert_mounted() {
    local desc="$1" path="$2"
    if sudo findmnt -rn "$path" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        (( ++PASS ))
    else
        echo -e "  ${RED}✗${NC} ${desc}: not mounted: ${path}"
        (( ++FAIL ))
    fi
}

assert_not_mounted() {
    local desc="$1" path="$2"
    if ! sudo findmnt -rn "$path" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        (( ++PASS ))
    else
        echo -e "  ${RED}✗${NC} ${desc}: unexpectedly mounted: ${path}"
        (( ++FAIL ))
    fi
}

# ─── Tests ───────────────────────────────────────────────────────────────────

test_1_init() {
    echo -e "${BOLD}Test 1: init${NC}"
    "$MUX" init -w "$WORKSPACE" -r "${REPO_A},${REPO_B},${REPO_C}"
    assert_file_exists "config created" "${WORKSPACE}/.mux/config"
    assert_eq "repos registered" "3" "$(grep -c '^REPO=' "${WORKSPACE}/.mux/config")"
    assert_eq "active view is origin" "origin" "$(grep '^ACTIVE_VIEW=' "${WORKSPACE}/.mux/config" | sed 's/ACTIVE_VIEW=//')"
    echo ""
}

test_2_create_sessions() {
    echo -e "${BOLD}Test 2: create sessions${NC}"

    "$MUX" create 1
    MOUNTS_CREATED+=("${REPO_A}_1" "${REPO_B}_1")
    assert_mounted "a_1 overlay mounted" "${REPO_A}_1"
    assert_mounted "b_1 overlay mounted" "${REPO_B}_1"
    assert_eq "a_1 has original content" "original_a" "$(cat "${REPO_A}_1/file_a.txt")"
    assert_eq "b_1 has original content" "original_b" "$(cat "${REPO_B}_1/file_b.txt")"

    "$MUX" create 2
    MOUNTS_CREATED+=("${REPO_A}_2" "${REPO_B}_2")
    assert_mounted "a_2 overlay mounted" "${REPO_A}_2"
    assert_mounted "b_2 overlay mounted" "${REPO_B}_2"
    assert_eq "a_2 has original content" "original_a" "$(cat "${REPO_A}_2/file_a.txt")"
    echo ""
}

test_3_isolation() {
    echo -e "${BOLD}Test 3: write isolation between sessions${NC}"

    echo "session_1_only" > "${REPO_A}_1/only_in_1.txt"
    echo "session_2_only" > "${REPO_A}_2/only_in_2.txt"

    assert_file_exists "only_in_1.txt exists in session 1" "${REPO_A}_1/only_in_1.txt"
    assert_file_not_exists "only_in_1.txt absent from session 2" "${REPO_A}_2/only_in_1.txt"
    assert_file_not_exists "only_in_1.txt absent from origin" "${REPO_A}/only_in_1.txt"

    assert_file_exists "only_in_2.txt exists in session 2" "${REPO_A}_2/only_in_2.txt"
    assert_file_not_exists "only_in_2.txt absent from session 1" "${REPO_A}_1/only_in_2.txt"
    assert_file_not_exists "only_in_2.txt absent from origin" "${REPO_A}/only_in_2.txt"
    echo ""
}

test_4_git_cow() {
    echo -e "${BOLD}Test 4: git CoW isolation${NC}"

    # Record origin's git log
    local origin_log
    origin_log="$(cd "$REPO_A" && git log --oneline)"

    # Commit in session 1
    cd "${REPO_A}_1"
    git config user.email "test@mux.dev"
    git config user.name "mux-test"
    echo "new_in_1" > new_file.txt
    git add new_file.txt
    git commit -q -m "session 1 commit"
    local sess1_log
    sess1_log="$(git log --oneline)"

    # Verify origin unchanged
    cd "$REPO_A"
    local origin_log_after
    origin_log_after="$(git log --oneline)"
    assert_eq "origin git log unchanged" "$origin_log" "$origin_log_after"
    assert_file_not_exists "new_file.txt absent from origin" "${REPO_A}/new_file.txt"

    # Verify session 2 unchanged
    local sess2_log
    sess2_log="$(cd "${REPO_A}_2" && git log --oneline)"
    assert_eq "session 2 git log unchanged" "$origin_log" "$sess2_log"

    cd "$WORKSPACE"
    echo ""
}

test_5_switch_session() {
    echo -e "${BOLD}Test 5: switch compiler view to session 1${NC}"

    "$MUX" switch 1
    MOUNTS_CREATED+=("${REPO_A}" "${REPO_B}")
    assert_mounted "a is bind-mounted" "${REPO_A}"
    assert_file_exists "compiler view shows session 1 file" "${REPO_A}/only_in_1.txt"
    assert_eq "compiler view content matches" "session_1_only" "$(cat "${REPO_A}/only_in_1.txt")"
    echo ""
}

test_6_switch_origin() {
    echo -e "${BOLD}Test 6: switch compiler view back to origin${NC}"

    "$MUX" switch origin
    assert_not_mounted "a is not bind-mounted (origin visible)" "${REPO_A}"
    assert_file_not_exists "only_in_1.txt gone from compiler view" "${REPO_A}/only_in_1.txt"
    assert_eq "original content restored" "original_a" "$(cat "${REPO_A}/file_a.txt")"
    echo ""
}

test_7_build_artifact_routing() {
    echo -e "${BOLD}Test 7: build artifact routing through compiler view${NC}"

    "$MUX" switch 2
    MOUNTS_CREATED+=("${REPO_A}" "${REPO_B}")

    # Simulate build artifact written via compiler path
    echo "build_output" > "${REPO_A}/build_artifact.o"

    # Verify it landed in session 2's upper dir
    assert_file_exists "artifact in session 2 agent view" "${REPO_A}_2/build_artifact.o"
    assert_file_not_exists "artifact not in session 1" "${REPO_A}_1/build_artifact.o"
    assert_file_exists "artifact in session 2 upper dir" "${WORKSPACE}/.mux/sessions/2/a/upper/build_artifact.o"

    "$MUX" switch origin
    echo ""
}

test_8_status() {
    echo -e "${BOLD}Test 8: status output${NC}"

    local status_out
    status_out="$("$MUX" status 2>&1)"
    assert_eq "status shows workspace" "true" "$( [[ "$status_out" == *"$WORKSPACE"* ]] && echo true || echo false )"
    assert_eq "status shows origin view" "true" "$( [[ "$status_out" == *"origin"* ]] && echo true || echo false )"
    echo ""
}

test_9_remount() {
    echo -e "${BOLD}Test 9: remount after unmount${NC}"

    # Unmount everything manually
    sudo umount "${REPO_A}_1" 2>/dev/null || true
    sudo umount "${REPO_B}_1" 2>/dev/null || true
    sudo umount "${REPO_A}_2" 2>/dev/null || true
    sudo umount "${REPO_B}_2" 2>/dev/null || true

    assert_not_mounted "a_1 unmounted" "${REPO_A}_1"
    assert_not_mounted "a_2 unmounted" "${REPO_A}_2"

    # Remount all
    "$MUX" remount

    assert_mounted "a_1 re-mounted" "${REPO_A}_1"
    assert_mounted "b_1 re-mounted" "${REPO_B}_1"
    assert_mounted "a_2 re-mounted" "${REPO_A}_2"
    assert_mounted "b_2 re-mounted" "${REPO_B}_2"

    # Verify data survived
    assert_file_exists "session 1 data survived remount" "${REPO_A}_1/only_in_1.txt"
    assert_file_exists "session 2 data survived remount" "${REPO_A}_2/only_in_2.txt"
    echo ""
}

test_10_cleanup() {
    echo -e "${BOLD}Test 10: originals untouched after full lifecycle${NC}"

    # Switch to origin view
    "$MUX" switch origin

    assert_eq "origin file_a intact" "original_a" "$(cat "${REPO_A}/file_a.txt")"
    assert_eq "origin file_b intact" "original_b" "$(cat "${REPO_B}/file_b.txt")"
    assert_file_not_exists "no session files leaked to origin" "${REPO_A}/only_in_1.txt"
    echo ""
}

# ─── Corner Case Tests ───────────────────────────────────────────────────────

test_11_double_create() {
    echo -e "${BOLD}Test 11: idempotent double create${NC}"

    # Creating session 1 again should not fail (already exists)
    "$MUX" create 1
    assert_mounted "a_1 still mounted after double create" "${REPO_A}_1"
    assert_eq "session 1 data intact after double create" "session_1_only" "$(cat "${REPO_A}_1/only_in_1.txt")"
    echo ""
}

test_12_create_without_init() {
    echo -e "${BOLD}Test 12: create without init (error case)${NC}"

    # Use a fresh temp dir with no .mux config
    local tmpdir
    tmpdir="$(mktemp -d /tmp/mux_no_init.XXXXXX)"
    local output
    if output="$(MUX_WORKSPACE="$tmpdir" "$MUX" create 99 2>&1)"; then
        echo -e "  ${RED}✗${NC} should have failed but succeeded"
        (( ++FAIL ))
    else
        echo -e "  ${GREEN}✓${NC} correctly failed: create without init"
        (( ++PASS ))
    fi
    rm -rf "$tmpdir"
    echo ""
}

test_13_switch_nonexistent() {
    echo -e "${BOLD}Test 13: switch to non-existent session (error case)${NC}"

    local output
    if output="$("$MUX" switch 999 2>&1)"; then
        echo -e "  ${RED}✗${NC} should have failed but succeeded"
        (( ++FAIL ))
    else
        echo -e "  ${GREEN}✓${NC} correctly failed: switch to non-existent session"
        (( ++PASS ))
    fi
    echo ""
}

test_14_file_deletion_isolation() {
    echo -e "${BOLD}Test 14: file deletion isolation (whiteout)${NC}"

    # Delete origin file in session 1
    rm -f "${REPO_A}_1/file_a.txt"
    assert_file_not_exists "file_a.txt deleted in session 1" "${REPO_A}_1/file_a.txt"
    assert_file_exists "file_a.txt still in session 2" "${REPO_A}_2/file_a.txt"
    assert_file_exists "file_a.txt still in origin" "${REPO_A}/file_a.txt"
    echo ""
}

test_15_file_modification_isolation() {
    echo -e "${BOLD}Test 15: file modification isolation${NC}"

    # Modify a file in session 2
    echo "modified_by_session_2" > "${REPO_A}_2/file_a.txt"
    assert_eq "session 2 sees modified content" "modified_by_session_2" "$(cat "${REPO_A}_2/file_a.txt")"
    assert_eq "origin still has original" "original_a" "$(cat "${REPO_A}/file_a.txt")"

    # Session 1 deleted it, so it should still be absent
    assert_file_not_exists "session 1 still has it deleted" "${REPO_A}_1/file_a.txt"
    echo ""
}

test_16_direct_session_switch() {
    echo -e "${BOLD}Test 16: direct switch between sessions (no origin in between)${NC}"

    # Switch to session 1
    "$MUX" switch 1

    # Verify session 1 is active (file_a.txt was deleted in session 1)
    assert_file_not_exists "compiler view matches session 1 (file_a deleted)" "${REPO_A}/file_a.txt"
    assert_file_exists "compiler view has session 1 file" "${REPO_A}/only_in_1.txt"

    # Switch directly to session 2 (no switch origin first)
    "$MUX" switch 2
    assert_eq "compiler view now shows session 2 modified file" "modified_by_session_2" "$(cat "${REPO_A}/file_a.txt")"
    assert_file_exists "compiler view has session 2 file" "${REPO_A}/only_in_2.txt"
    assert_file_not_exists "session 1 file not visible" "${REPO_A}/only_in_1.txt"

    "$MUX" switch origin
    echo ""
}

test_17_git_branch_divergence() {
    echo -e "${BOLD}Test 17: git branch divergence between sessions${NC}"

    # Create branch in session 1
    cd "${REPO_A}_1"
    git checkout -qb feature-session-1
    echo "branch1" > branch1.txt
    git add branch1.txt
    git commit -q -m "session 1 branch commit"
    local s1_branch
    s1_branch="$(git branch --show-current)"

    # Create different branch in session 2
    cd "${REPO_A}_2"
    git checkout -qb feature-session-2
    echo "branch2" > branch2.txt
    git add branch2.txt
    git commit -q -m "session 2 branch commit"
    local s2_branch
    s2_branch="$(git branch --show-current)"

    # Verify divergence
    assert_eq "session 1 on its own branch" "feature-session-1" "$s1_branch"
    assert_eq "session 2 on its own branch" "feature-session-2" "$s2_branch"

    # Origin should still be on original branch (could be main or master)
    cd "${REPO_A}"
    local origin_branch expected_branch
    origin_branch="$(git branch --show-current)"
    expected_branch="$(git -C "${REPO_A}" rev-parse --abbrev-ref HEAD)"
    assert_eq "origin still on default branch" "$expected_branch" "$origin_branch"

    # Cross-session file isolation
    assert_file_not_exists "branch1.txt not in session 2" "${REPO_A}_2/branch1.txt"
    assert_file_not_exists "branch2.txt not in session 1" "${REPO_A}_1/branch2.txt"

    cd "$WORKSPACE"
    echo ""
}

test_18_remount_specific_session() {
    echo -e "${BOLD}Test 18: remount specific session only${NC}"

    # Unmount only session 1
    sudo umount "${REPO_A}_1" 2>/dev/null || true
    sudo umount "${REPO_B}_1" 2>/dev/null || true

    assert_not_mounted "a_1 unmounted" "${REPO_A}_1"
    assert_mounted "a_2 still mounted" "${REPO_A}_2"

    # Remount only session 1
    "$MUX" remount 1

    assert_mounted "a_1 re-mounted" "${REPO_A}_1"
    assert_mounted "b_1 re-mounted" "${REPO_B}_1"
    assert_mounted "a_2 still mounted (untouched)" "${REPO_A}_2"

    # Verify session 1 data survived
    assert_file_exists "session 1 branch file intact" "${REPO_A}_1/branch1.txt"
    echo ""
}

test_19_full_antigravity_workflow() {
    echo -e "${BOLD}Test 19: full Antigravity workflow (3 repos, 2 agents, edit→compile→reback)${NC}"

    # ── Phase 1: Agent 1 edits across all 3 repos ──
    echo "  Phase 1: Agent 1 editing a_1, b_1, c_1..."
    # Simulate agent patching kernel
    echo '#include "new_feature.h"' >> "${REPO_A}_1/file_a.txt"
    echo 'void new_feature() {}' > "${REPO_A}_1/new_feature.h"
    # Simulate agent patching rmm
    echo 'handle_new_feature();' >> "${REPO_B}_1/file_b.txt"
    # Simulate agent patching firmware
    echo 'int new_feature() { return 42; }' > "${REPO_C}_1/src/new_feature.c"
    git -C "${REPO_A}_1" add -A && git -C "${REPO_A}_1" commit -q -m "agent1: add new feature"
    git -C "${REPO_B}_1" add -A && git -C "${REPO_B}_1" commit -q -m "agent1: handle new feature"
    git -C "${REPO_C}_1" add -A && git -C "${REPO_C}_1" commit -q -m "agent1: firmware support"

    # ── Phase 2: Agent 2 makes different edits (parallel) ──
    echo "  Phase 2: Agent 2 editing a_2, b_2, c_2..."
    echo 'void bugfix() {}' > "${REPO_A}_2/bugfix.h"
    echo '#include "bugfix.h"' >> "${REPO_A}_2/file_a.txt"
    echo 'apply_bugfix();' >> "${REPO_B}_2/file_b.txt"
    echo '// firmware bugfix' >> "${REPO_C}_2/src/main.c"
    git -C "${REPO_A}_2" add -A && git -C "${REPO_A}_2" commit -q -m "agent2: bugfix"
    git -C "${REPO_B}_2" add -A && git -C "${REPO_B}_2" commit -q -m "agent2: apply bugfix"
    git -C "${REPO_C}_2" add -A && git -C "${REPO_C}_2" commit -q -m "agent2: firmware bugfix"

    # ── Phase 3: Switch compiler view to agent 1, simulate build ──
    echo "  Phase 3: Switch to agent 1, compile..."
    "$MUX" switch 1
    MOUNTS_CREATED+=("${REPO_A}" "${REPO_B}" "${REPO_C}")

    # Verify compiler sees agent 1's changes
    assert_file_exists "compiler sees agent 1 new_feature.h" "${REPO_A}/new_feature.h"
    assert_file_not_exists "compiler does NOT see agent 2 bugfix.h" "${REPO_A}/bugfix.h"
    assert_file_exists "compiler sees agent 1 firmware" "${REPO_C}/src/new_feature.c"

    # Simulate build output across all 3 repos
    echo "COMPILED" > "${REPO_A}/a.o"
    echo "COMPILED" > "${REPO_B}/b.o"
    echo "COMPILED" > "${REPO_C}/firmware.bin"

    # Verify build artifacts routed to session 1's upper
    assert_file_exists "build artifact a.o in session 1 upper" "${WORKSPACE}/.mux/sessions/1/a/upper/a.o"
    assert_file_exists "build artifact b.o in session 1 upper" "${WORKSPACE}/.mux/sessions/1/b/upper/b.o"
    assert_file_exists "build artifact firmware.bin in session 1 upper" "${WORKSPACE}/.mux/sessions/1/c/upper/firmware.bin"
    assert_file_not_exists "build artifact NOT in session 2" "${REPO_A}_2/a.o"

    # ── Phase 4: Switch to agent 2, compile ──
    echo "  Phase 4: Switch to agent 2, compile..."
    "$MUX" switch 2

    # Verify compiler now sees agent 2's changes
    assert_file_exists "compiler sees agent 2 bugfix.h" "${REPO_A}/bugfix.h"
    assert_file_not_exists "compiler does NOT see agent 1 new_feature.h" "${REPO_A}/new_feature.h"
    assert_file_not_exists "agent 1 build artifacts gone" "${REPO_A}/a.o"

    # Build with agent 2's code
    echo "COMPILED_V2" > "${REPO_A}/a.o"
    assert_file_exists "agent 2 build artifact in upper" "${WORKSPACE}/.mux/sessions/2/a/upper/a.o"
    assert_eq "agent 2 build content correct" "COMPILED_V2" "$(cat "${REPO_A}_2/a.o")"

    # ── Phase 5: Switch back to agent 1 (reback) ──
    echo "  Phase 5: Switch back to agent 1 (reback)..."
    "$MUX" switch 1

    # Agent 1's build artifacts should still be there
    assert_eq "agent 1 build artifact preserved" "COMPILED" "$(cat "${REPO_A}/a.o")"
    assert_file_exists "agent 1 new_feature still there" "${REPO_A}/new_feature.h"
    assert_eq "agent 1 firmware build preserved" "COMPILED" "$(cat "${REPO_C}/firmware.bin")"

    # ── Phase 6: Switch to origin, verify completely clean ──
    echo "  Phase 6: Switch to origin, verify clean..."
    "$MUX" switch origin

    assert_eq "origin a untouched" "original_a" "$(cat "${REPO_A}/file_a.txt")"
    assert_eq "origin b untouched" "original_b" "$(cat "${REPO_B}/file_b.txt")"
    assert_eq "origin c untouched" "original_c" "$(cat "${REPO_C}/file_c.txt")"
    assert_file_not_exists "no build artifacts in origin a" "${REPO_A}/a.o"
    assert_file_not_exists "no agent files in origin" "${REPO_A}/new_feature.h"
    assert_eq "origin firmware source intact" 'int main() { return 0; }' "$(cat "${REPO_C}/src/main.c")"

    # ── Phase 7: Verify both sessions independently intact ──
    echo "  Phase 7: Verify both agent sessions still intact..."
    local s1_commits s2_commits origin_commits
    s1_commits="$(git -C "${REPO_A}_1" log --oneline | wc -l)"
    s2_commits="$(git -C "${REPO_A}_2" log --oneline | wc -l)"
    origin_commits="$(git -C "${REPO_A}" log --oneline | wc -l)"
    assert_eq "origin has only initial commit" "1" "$origin_commits"
    # Sessions have more commits than origin (agent edits + earlier tests)
    assert_eq "session 1 has more commits than origin" "true" "$( [[ $s1_commits -gt $origin_commits ]] && echo true || echo false )"
    assert_eq "session 2 has more commits than origin" "true" "$( [[ $s2_commits -gt $origin_commits ]] && echo true || echo false )"
    # Sessions are independent (different commit counts)
    assert_eq "sessions have diverged" "true" "$( [[ $s1_commits -ne $s2_commits ]] && echo true || echo false )"

    echo ""
}

test_20_create_while_switched() {
    echo -e "${BOLD}Test 20: create session while another is switched in${NC}"

    # Switch to session 1 (compiler view shows session 1)
    "$MUX" switch 1
    MOUNTS_CREATED+=("${REPO_A}" "${REPO_B}" "${REPO_C}")

    # Write a unique file in session 1's agent view
    echo "session_1_unique" > "${REPO_A}_1/switched_marker.txt"

    # Verify compiler view sees session 1's content
    assert_file_exists "compiler view sees session 1 marker" "${REPO_A}/switched_marker.txt"

    # Create session 3 WHILE session 1 is switched in
    "$MUX" create 3
    MOUNTS_CREATED+=("${REPO_A}_3" "${REPO_B}_3" "${REPO_C}_3")

    # Session 3 must NOT contain session 1's file (must fork from origin)
    assert_file_not_exists "session 3 does NOT have session 1 marker" "${REPO_A}_3/switched_marker.txt"

    # Session 3 must have original content (forked from origin)
    assert_eq "session 3 has origin content" "original_a" "$(cat "${REPO_A}_3/file_a.txt")"

    # Compiler view must still be on session 1 (undisturbed)
    assert_file_exists "compiler view still has session 1 marker" "${REPO_A}/switched_marker.txt"
    local active_view
    active_view="$(grep '^ACTIVE_VIEW=' "${WORKSPACE}/.mux/config" | sed 's/ACTIVE_VIEW=//')"
    assert_eq "active view still session 1" "1" "$active_view"

    "$MUX" switch origin
    echo ""
}

test_21_delete_session() {
    echo -e "${BOLD}Test 21: delete a session${NC}"

    # Session 3 was created in test 20 — delete it
    "$MUX" delete 3

    # Verify overlays unmounted
    assert_not_mounted "a_3 unmounted after delete" "${REPO_A}_3"
    assert_not_mounted "b_3 unmounted after delete" "${REPO_B}_3"
    assert_not_mounted "c_3 unmounted after delete" "${REPO_C}_3"

    # Verify agent view dirs removed
    assert_file_not_exists "a_3 dir removed" "${REPO_A}_3"
    assert_file_not_exists "b_3 dir removed" "${REPO_B}_3"
    assert_file_not_exists "c_3 dir removed" "${REPO_C}_3"

    # Verify session storage removed
    assert_file_not_exists "session 3 storage removed" "${WORKSPACE}/.mux/sessions/3"

    # Verify session removed from config
    if grep -q '^SESSION=3$' "${WORKSPACE}/.mux/config" 2>/dev/null; then
        echo -e "  ${RED}✗${NC} session 3 still in config"
        (( ++FAIL ))
    else
        echo -e "  ${GREEN}✓${NC} session 3 removed from config"
        (( ++PASS ))
    fi

    # Verify other sessions still intact
    assert_mounted "a_1 still mounted" "${REPO_A}_1"
    assert_mounted "a_2 still mounted" "${REPO_A}_2"
    assert_file_exists "session 1 data intact" "${REPO_A}_1/only_in_1.txt"
    assert_file_exists "session 2 data intact" "${REPO_A}_2/only_in_2.txt"
    echo ""
}

test_22_delete_switched_session() {
    echo -e "${BOLD}Test 22: delete currently switched session (error case)${NC}"

    "$MUX" switch 1
    MOUNTS_CREATED+=("${REPO_A}" "${REPO_B}" "${REPO_C}")

    local output
    if output="$("$MUX" delete 1 2>&1)"; then
        echo -e "  ${RED}\u2717${NC} should have failed but succeeded"
        (( ++FAIL ))
    else
        echo -e "  ${GREEN}\u2713${NC} correctly refused: delete switched session"
        (( ++PASS ))
    fi

    # Verify session 1 is still intact
    assert_mounted "a_1 still mounted after refused delete" "${REPO_A}_1"

    "$MUX" switch origin
    echo ""
}

test_23_destroy_workspace() {
    echo -e "${BOLD}Test 23: destroy entire workspace${NC}"

    # Switch to session 1 to test that destroy handles active compiler view
    "$MUX" switch 1

    "$MUX" destroy

    # All session overlays gone
    assert_not_mounted "a_1 unmounted after destroy" "${REPO_A}_1"
    assert_not_mounted "a_2 unmounted after destroy" "${REPO_A}_2"
    assert_not_mounted "b_1 unmounted after destroy" "${REPO_B}_1"

    # Agent view dirs gone
    assert_file_not_exists "a_1 dir removed" "${REPO_A}_1"
    assert_file_not_exists "a_2 dir removed" "${REPO_A}_2"

    # Compiler view unmounted (origin visible)
    assert_not_mounted "compiler view unmounted" "${REPO_A}"
    assert_eq "origin content restored" "original_a" "$(cat "${REPO_A}/file_a.txt")"

    # Origin refs gone
    assert_not_mounted "origin ref a unmounted" "${WORKSPACE}/.mux/origins/a"

    # .mux directory gone
    assert_file_not_exists ".mux removed" "${WORKSPACE}/.mux"

    echo ""
}

test_24_destroy_no_config() {
    echo -e "${BOLD}Test 24: destroy with no config (edge case)${NC}"

    # Use a fresh temp dir with no .mux config
    local tmpdir
    tmpdir="$(mktemp -d /tmp/mux_no_config.XXXXXX)"
    local output
    # Should not fail, just warn
    if output="$(MUX_WORKSPACE="$tmpdir" "$MUX" destroy 2>&1)"; then
        echo -e "  ${GREEN}✓${NC} destroy with no config exits gracefully"
        (( ++PASS ))
    else
        echo -e "  ${RED}✗${NC} destroy with no config should not fail"
        (( ++FAIL ))
    fi
    rm -rf "$tmpdir"
    echo ""
}

# ─── Run ─────────────────────────────────────────────────────────────────────

main() {
    # Prompt for sudo early to cache credentials
    sudo -v || { echo "sudo access required for mount operations"; exit 1; }

    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}  mux integration tests${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    setup

    test_1_init
    test_2_create_sessions
    test_3_isolation
    test_4_git_cow
    test_5_switch_session
    test_6_switch_origin
    test_7_build_artifact_routing
    test_8_status
    test_9_remount
    test_10_cleanup

    # Corner cases
    test_11_double_create
    test_12_create_without_init
    test_13_switch_nonexistent
    test_14_file_deletion_isolation
    test_15_file_modification_isolation
    test_16_direct_session_switch
    test_17_git_branch_divergence
    test_18_remount_specific_session

    # End-to-end workflow
    test_19_full_antigravity_workflow

    # Origin reference tests
    test_20_create_while_switched

    # Delete tests
    test_21_delete_session
    test_22_delete_switched_session

    # Destroy tests (must be last — tears down workspace)
    test_23_destroy_workspace
    test_24_destroy_no_config

    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "  ${GREEN}Passed: ${PASS}${NC}  ${RED}Failed: ${FAIL}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"

    [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}

main "$@"
