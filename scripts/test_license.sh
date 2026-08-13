#!/bin/bash
#
# Black-box test suite for Peek3D's trial/license system.
#
# Peek3D.xcodeproj has no test target (adding one means hand-editing
# project.pbxproj — fragile, out of scope, see CLAUDE.md). This script is
# the other half of the test suite alongside PeekLicenseKitTests: it drives
# the REAL compiled app binary through environment-variable hooks
# (PEEK3D_LICENSE_SELFTEST, PEEK3D_LICENSE_DEBUG_STATE, PEEK3D_LICENSE_STATE_QUERY
# — see LicenseSelfTest.swift, LicenseDebugHarness.swift, LicenseStateQuery.swift)
# and checks its stdout, exactly the pattern this project already uses for
# GLBVIEWER_SELFTEST.
#
# Phases:
#   1. PeekLicenseKit's own unit tests (`swift test`) — crypto verification.
#   2. LicenseSelfTest — trial counter boundaries, dedup, corrupted-state
#      fail-open, licensed-forever, all through production code in one
#      process.
#   3. Uninstall/reinstall persistence — the one behavior that genuinely
#      needs two separate process launches and real filesystem surgery:
#      seed 9 seen files, delete the sandbox container (simulating an
#      uninstall) and the built app copy, build a SECOND independent copy
#      (simulating a reinstall), and confirm the count survived via the
#      Keychain alone.
#
# WARNING — destructive. This overwrites the real com.seb.Peek3D Keychain
# item and its UserDefaults mirror, and deletes
# ~/Library/Containers/com.seb.Peek3D entirely. Never run this on a machine
# whose actual Peek3D trial/license state you care about. It ends by
# resetting to a fresh-install state, not by restoring whatever was there
# before.
#
# Usage: scripts/test_license.sh   (run from anywhere; paths are resolved
# relative to this script's location)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="com.seb.Peek3D"
KEYCHAIN_SERVICE="com.seb.Peek3D.entitlement"
CONTAINER_DIR="$HOME/Library/Containers/$BUNDLE_ID"
DERIVED1="$REPO_ROOT/build-release/DerivedData-license-test-1"
DERIVED2="$REPO_ROOT/build-release/DerivedData-license-test-2"

TOTAL_FAILURES=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; TOTAL_FAILURES=$((TOTAL_FAILURES + 1)); }
phase() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

build_app() {
    local derived_data="$1"
    xcodebuild -project "$REPO_ROOT/Peek3D.xcodeproj" -scheme Peek3D \
        -configuration Debug -derivedDataPath "$derived_data" \
        build > "$derived_data.build.log" 2>&1
    local status=$?
    if [ $status -ne 0 ]; then
        echo "    build failed — see $derived_data.build.log"
        tail -40 "$derived_data.build.log"
        return 1
    fi
    echo "$derived_data/Build/Products/Debug/Peek3D.app/Contents/MacOS/Peek3D"
}

clean_slate() {
    security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
    rm -rf "$CONTAINER_DIR"
}

# ---------------------------------------------------------------------------
phase "1/3 — PeekLicenseKit unit tests (crypto verification)"
# ---------------------------------------------------------------------------

( cd "$REPO_ROOT/PeekLicenseKit" && swift test 2>&1 | tee "$REPO_ROOT/build-release/peeklicensekit-test.log" )
PLK_STATUS=${PIPESTATUS[0]:-$?}
if [ "$PLK_STATUS" -eq 0 ]; then
    pass "swift test (PeekLicenseKitTests) — all cases green, including the trustedPublicKeys security guard"
else
    fail "swift test (PeekLicenseKitTests) — see build-release/peeklicensekit-test.log"
fi

# ---------------------------------------------------------------------------
phase "2/3 — In-process license self-test (build #1)"
# ---------------------------------------------------------------------------

mkdir -p "$REPO_ROOT/build-release"
BINARY1="$(build_app "$DERIVED1")"
if [ -z "$BINARY1" ] || [ ! -x "$BINARY1" ]; then
    fail "build #1 — could not produce a runnable Peek3D binary"
else
    pass "build #1 produced $BINARY1"

    clean_slate
    SELFTEST_OUTPUT="$(PEEK3D_LICENSE_SELFTEST=1 "$BINARY1" 2>&1)"
    echo "$SELFTEST_OUTPUT" | sed 's/^/    /'
    if echo "$SELFTEST_OUTPUT" | grep -q '^LICENSE_SELFTEST_OK$'; then
        pass "LicenseSelfTest — every in-process assertion passed"
    else
        fail "LicenseSelfTest — see output above (look for FAIL: lines)"
    fi
fi

# ---------------------------------------------------------------------------
phase "3/3 — Uninstall/reinstall persistence (survives Keychain-only)"
# ---------------------------------------------------------------------------

if [ -z "${BINARY1:-}" ] || [ ! -x "$BINARY1" ]; then
    fail "uninstall/reinstall check — build #1 unavailable, skipped"
else
    clean_slate

    echo "  seeding 9 seen files via PEEK3D_LICENSE_DEBUG_STATE=trial9 ..."
    SEED_OUTPUT="$(PEEK3D_LICENSE_DEBUG_STATE=trial9 PEEK3D_LICENSE_STATE_QUERY=1 "$BINARY1" 2>&1)"
    echo "$SEED_OUTPUT" | sed 's/^/    /'
    if echo "$SEED_OUTPUT" | grep -q '^LICENSE_STATE: trial opensRemaining=1$'; then
        pass "seed: 9 files recorded, opensRemaining=1 before the simulated uninstall"
    else
        fail "seed: expected 'LICENSE_STATE: trial opensRemaining=1', got: $SEED_OUTPUT"
    fi

    if [ -d "$CONTAINER_DIR" ]; then
        pass "sandbox container exists at $CONTAINER_DIR (app really is sandboxed — see build_codesign_gltfkit2 memory for what it looks like when it silently isn't)"
    else
        fail "sandbox container NOT found at $CONTAINER_DIR after a real launch — the app may not actually be running sandboxed; the persistence result below would not be trustworthy"
    fi

    echo "  simulating uninstall: removing the sandbox container and build #1's app bundle ..."
    rm -rf "$CONTAINER_DIR"
    rm -rf "$DERIVED1/Build/Products/Debug/Peek3D.app"
    if [ -d "$CONTAINER_DIR" ] || [ -d "$DERIVED1/Build/Products/Debug/Peek3D.app" ]; then
        fail "simulated uninstall — container or app bundle still present"
    else
        pass "simulated uninstall — container and app bundle both removed, Keychain item untouched"
    fi

    echo "  simulating reinstall: building an independent second copy ..."
    BINARY2="$(build_app "$DERIVED2")"
    if [ -z "$BINARY2" ] || [ ! -x "$BINARY2" ]; then
        fail "build #2 (simulated reinstall) — could not produce a runnable Peek3D binary"
    else
        pass "build #2 (simulated reinstall) produced $BINARY2"

        QUERY_OUTPUT="$(PEEK3D_LICENSE_STATE_QUERY=1 "$BINARY2" 2>&1)"
        echo "$QUERY_OUTPUT" | sed 's/^/    /'
        if echo "$QUERY_OUTPUT" | grep -q '^LICENSE_STATE: trial opensRemaining=1$'; then
            pass "reinstall: opensRemaining is STILL 1 — the trial count survived the uninstall via the Keychain"
        else
            fail "reinstall: expected 'LICENSE_STATE: trial opensRemaining=1', got: $QUERY_OUTPUT (trial count did NOT survive — Keychain persistence is broken)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
phase "Cleanup"
# ---------------------------------------------------------------------------

if [ -n "${BINARY2:-}" ] && [ -x "$BINARY2" ]; then
    PEEK3D_LICENSE_DEBUG_STATE=reset PEEK3D_LICENSE_STATE_QUERY=1 "$BINARY2" >/dev/null 2>&1
elif [ -n "${BINARY1:-}" ] && [ -x "$BINARY1" ]; then
    PEEK3D_LICENSE_DEBUG_STATE=reset PEEK3D_LICENSE_STATE_QUERY=1 "$BINARY1" >/dev/null 2>&1
fi
echo "  Keychain/UserDefaults reset to fresh-install state."
echo "  (Derived data left at build-release/DerivedData-license-test-{1,2} for inspection — safe to rm -rf.)"

# ---------------------------------------------------------------------------
phase "Summary"
# ---------------------------------------------------------------------------

if [ "$TOTAL_FAILURES" -eq 0 ]; then
    echo "All phases passed."
    exit 0
else
    echo "$TOTAL_FAILURES check(s) failed — see FAIL lines above."
    exit 1
fi
