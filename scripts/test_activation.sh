#!/bin/bash
#
# Manual/black-box verification of Peek3D's single-machine activation layer
# (PolarLicenseAPIClient / HTTPPolarLicenseAPIClient / LicenseActivationService)
# against a REAL local HTTP server, driving the REAL compiled app binary —
# not a mock used inside a unit test. See scripts/fake_polar_server.py for
# the fake server and PolarLicenseAPIClientQuery.swift for the in-app probe
# this script drives (PEEK3D_POLAR_CLIENT_QUERY=activate/validate/deactivate).
#
# Why this probe instead of driving LicenseActivationService/launchTimeCheck
# directly: that path is @MainActor, and bridging a synchronous
# Peek3DApp.init() into an await on MainActor-isolated work before this
# process's real run loop is running proved unreliable (hung indefinitely
# more often than it completed). HTTPPolarLicenseAPIClient itself is NOT
# actor-isolated, so PolarLicenseAPIClientQuery can safely block with a
# DispatchSemaphore while its Task runs on a background executor — this
# still exercises the exact same URLSession calls, request/response
# schema, and PolarLicenseConfig.apiBase override LicenseActivationService
# uses internally. The state machine BUILT on top of this client (24h gate,
# 72h grace, never-downgrade-on-failure) is separately verified
# deterministically by LicenseActivationSelfTest (PEEK3D_ACTIVATION_SELFTEST),
# which uses a scripted FakePolarLicenseAPIClient instead of the network.
#
# NOTE on flakiness observed during development: the very first HTTP
# request to a freshly-started local fake-server port sometimes times out
# once or twice before succeeding (NSURLErrorDomain -1001, "Tempo di
# richiesta scaduto") even though `curl` reaches the same port instantly.
# This reproduced with a fresh ad-hoc-signed sandboxed binary against a
# fresh Python http.server port and self-resolved on retry every time it
# was observed; it was never seen against an already-"warm" port. This
# script retries each case a few times for exactly that reason. It is
# environmental, not a defect in the app: every attempt that DID complete
# showed byte-for-byte correct request/response handling, and the app's
# own behavior on failure (a clean, fast .transportFailure, well within
# the 15s configured timeout, no crash, no hang) was correct every time.
#
# Usage: scripts/test_activation.sh   (run from anywhere)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED="$REPO_ROOT/build-release/DerivedData-activation-test"

TOTAL_FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; TOTAL_FAILURES=$((TOTAL_FAILURES + 1)); }
phase() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

phase "0/4 — Build"
xcodebuild -project "$REPO_ROOT/Peek3D.xcodeproj" -scheme Peek3D \
    -configuration Debug -derivedDataPath "$DERIVED" build > "$DERIVED.build.log" 2>&1
if [ $? -ne 0 ]; then
    fail "build — see $DERIVED.build.log"
    exit 1
fi
APP="$DERIVED/Build/Products/Debug/Peek3D.app"
BINARY="$APP/Contents/MacOS/Peek3D"
# Ad-hoc re-sign — xcodebuild-from-CLI builds of this project crash at
# launch with "GLTFKit2 not loaded" unless deep-re-signed. Known project
# gotcha, see CLAUDE.md / build_codesign_gltfkit2 memory.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
pass "build produced $BINARY"

run_query() {
    # run_query <port> <mode env var> <query mode> [extra env...]
    # Retries generously: a FRESHLY ad-hoc-signed binary's first few
    # outbound loopback connections in this headless environment were
    # observed to time out (NSURLErrorDomain -1001) up to 4-5 times before
    # succeeding, while an already-exercised binary (same bytes, already
    # attempted once) succeeded immediately on every later call. Looks like
    # a macOS-side one-time cost tied to this exact code signature/binary
    # instance (see this script's top doc comment) — not app-code flakiness,
    # confirmed by the fake server logging zero bytes received during every
    # failed attempt (never even reached its accept() loop).
    local attempt out
    for attempt in 1 2 3 4 5 6; do
        out="$(env "$@" timeout 15 "$BINARY" 2>&1 | grep 'POLAR_CLIENT_QUERY_RESULT')"
        if ! echo "$out" | grep -q transportFailure; then
            echo "$out"
            return 0
        fi
    done
    echo "$out"
    return 1
}

phase "1/4 — Fresh activation succeeds (real HTTP call, machine identifier in the body)"
pkill -f fake_polar_server.py 2>/dev/null; sleep 1
PEEK3D_FAKE_POLAR_MODE=success python3 "$SCRIPT_DIR/fake_polar_server.py" 8933 > /tmp/peek3d_fake_polar_1.log 2>&1 &
sleep 1
RESULT="$(run_query PEEK3D_POLAR_API_BASE_OVERRIDE=http://127.0.0.1:8933 PEEK3D_POLAR_CLIENT_QUERY=activate PEEK3D_POLAR_CLIENT_QUERY_KEY=POLAR-VERIFY-KEY)"
echo "  $RESULT"
if echo "$RESULT" | grep -q '^POLAR_CLIENT_QUERY_RESULT: success' && grep -q '"key": "POLAR-VERIFY-KEY"' /tmp/peek3d_fake_polar_1.log; then
    pass "activation succeeded and the fake server logged the exact request body"
else
    fail "activation did not succeed — see /tmp/peek3d_fake_polar_1.log"
fi
pkill -f "fake_polar_server.py 8933" 2>/dev/null

phase "2/4 — Device conflict (403, activation limit reached elsewhere)"
PEEK3D_FAKE_POLAR_MODE=conflict python3 "$SCRIPT_DIR/fake_polar_server.py" 8934 > /tmp/peek3d_fake_polar_2.log 2>&1 &
sleep 1
RESULT="$(run_query PEEK3D_POLAR_API_BASE_OVERRIDE=http://127.0.0.1:8934 PEEK3D_POLAR_CLIENT_QUERY=activate PEEK3D_POLAR_CLIENT_QUERY_KEY=POLAR-VERIFY-KEY)"
echo "  $RESULT"
if echo "$RESULT" | grep -q '^POLAR_CLIENT_QUERY_RESULT: notPermitted'; then
    pass "device conflict correctly surfaced as .notPermitted"
else
    fail "device conflict not detected — see $RESULT"
fi
pkill -f "fake_polar_server.py 8934" 2>/dev/null

phase "3/4 — Server completely down (never becomes 'license invalid')"
RESULT="$(env PEEK3D_POLAR_API_BASE_OVERRIDE=http://127.0.0.1:8935 PEEK3D_POLAR_CLIENT_QUERY=activate PEEK3D_POLAR_CLIENT_QUERY_KEY=POLAR-VERIFY-KEY timeout 20 "$BINARY" 2>&1 | grep 'POLAR_CLIENT_QUERY_RESULT')"
echo "  $RESULT"
if echo "$RESULT" | grep -q '^POLAR_CLIENT_QUERY_RESULT: transportFailure'; then
    pass "server down -> clean .transportFailure, not a crash or hang, not treated as revoked"
else
    fail "unexpected result with server down — see $RESULT"
fi

phase "4/4 — 24-hour reverify gate + state-machine correctness (scripted, deterministic)"
PEEK3D_ACTIVATION_SELFTEST=1 timeout 30 "$BINARY" > /tmp/peek3d_activation_selftest.log 2>&1
if grep -q '^ACTIVATION_SELFTEST_OK$' /tmp/peek3d_activation_selftest.log; then
    pass "LicenseActivationSelfTest — every scripted assertion passed (24h gate, 72h grace, never-downgrade-on-failure)"
else
    fail "LicenseActivationSelfTest — see /tmp/peek3d_activation_selftest.log"
fi

phase "Cleanup"
pkill -f fake_polar_server.py 2>/dev/null
security delete-generic-password -s "com.seb.Peek3D.activation" >/dev/null 2>&1 || true
echo "  fake servers stopped, com.seb.Peek3D.activation Keychain item cleared."

phase "Summary"
if [ "$TOTAL_FAILURES" -eq 0 ]; then
    echo "All phases passed."
    exit 0
else
    echo "$TOTAL_FAILURES check(s) failed — see FAIL lines above."
    exit 1
fi
