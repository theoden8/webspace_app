#!/usr/bin/env bash
# Android-emulator passkey tier (PASSKEY-012): the Credential Manager bridge
# end to end, with a real relying party and a real credential provider.
#
#   tool/passkey_gate/rp_server      @simplewebauthn/server on the host, reached
#                                    as http://localhost:8443 through adb reverse
#   tool/passkey_gate/test_provider  a CredentialProviderService that checks the
#                                    caller against a privileged allowlist, the
#                                    way Bitwarden checks its lists
#   integration_test/passkey_test.dart  the page side, one run per phase
#
# Each gate is graded from what was observed -- the RP's /results, the
# provider's logcat, dumpsys, the test's own PASSKEY_GATE lines -- never from
# the test having run. Evidence lands in build/passkey_gate/.
#
# Single entry point for the usual reason: the emulator runner executes each
# script line as its own `sh -c`.
set -uo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

APP_ID=org.codeberg.theoden8.webspace.debug
PROVIDER_ID=org.codeberg.theoden8.webspace.testprovider
PROVIDER_SVC="$PROVIDER_ID/$PROVIDER_ID.TestProviderService"
PORT=8443
FLUTTER="${FLUTTER:-fvm flutter}"
GRADLE="${GRADLE:-gradle}"
OUT=build/passkey_gate
mkdir -p "$OUT"
rm -f "$OUT"/*.txt "$OUT"/*.json "$OUT"/*.xml "$OUT"/*.log

adb_() { adb -s "$device_id" "$@"; }

failures=0
summary=()
pass() { echo "PASS $1: $2"; summary+=("PASS $1: $2"); }
fail() { echo "FAIL $1: $2"; summary+=("FAIL $1: $2"); failures=$((failures + 1)); }
note() { echo "NOTE $1: $2"; summary+=("NOTE $1: $2"); }

cleanup() {
  rm -f "$OUT/.tapping"
  [ -n "${TAP_PID:-}" ] && kill "$TAP_PID" 2>/dev/null
  [ -n "${LOGCAT_PID:-}" ] && kill "$LOGCAT_PID" 2>/dev/null
  [ -n "${RP_PID:-}" ] && kill "$RP_PID" 2>/dev/null
  adb_ reverse --remove "tcp:$PORT" >/dev/null 2>&1
}
trap cleanup EXIT

echo "── device ──"
adb_ shell getprop ro.build.version.sdk | sed 's/^/sdk /'
bash scripts/print_android_webview_version.sh "$device_id" | tee "$OUT/webview_version.txt"

# ── G0: the harness ──────────────────────────────────────────────────────────
if adb_ shell pm list features | grep -q 'feature:android.software.credentials'; then
  pass G0-feature "android.software.credentials present"
else
  fail G0-feature "android.software.credentials missing; Credential Manager does not run on this image"
fi

echo "── test provider ──"
if ! (cd tool/passkey_gate/test_provider && $GRADLE assembleDebug --console=plain -q); then
  fail G0-provider "test provider did not build"
fi
adb_ install -r -t tool/passkey_gate/test_provider/app/build/outputs/apk/debug/app-debug.apk
# Written after the install: the service only re-reads the setting on
# change, and a provider missing at that moment is dropped for good.
adb_ shell settings put secure credential_service "$PROVIDER_SVC"
adb_ shell settings put secure credential_service_primary "$PROVIDER_SVC"
enabled="$(adb_ shell settings get secure credential_service | tr -d '\r')"
if [ "$enabled" = "$PROVIDER_SVC" ]; then
  pass G0-provider "credential_service=$enabled"
else
  fail G0-provider "credential_service is '$enabled', wanted $PROVIDER_SVC"
fi

echo "── relying party ──"
(cd tool/passkey_gate/rp_server && npm ci --no-audit --no-fund --silent)
PORT=$PORT node tool/passkey_gate/rp_server/server.mjs > "$OUT/rp.log" 2>&1 &
RP_PID=$!
for _ in $(seq 30); do
  curl -fs "http://127.0.0.1:$PORT/" >/dev/null && break
  sleep 1
done
adb_ reverse "tcp:$PORT" "tcp:$PORT"
if adb_ reverse --list | grep -q "tcp:$PORT"; then
  pass G0-reverse "adb reverse tcp:$PORT active"
else
  fail G0-reverse "adb reverse not active"
fi

adb_ logcat -c
adb_ logcat -v time > "$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!

# The system passkey sheet (com.android.credentialmanager) always asks before
# a creation. Tap its confirm button whenever it is up. The first sightings
# are kept as evidence. uiautomator is only run while the sheet has focus: it
# turns accessibility on, and a Flutter app under test then holds a semantics
# handle that fails the test's end-of-test check.
touch "$OUT/.tapping"
(
  seen=0
  while [ -f "$OUT/.tapping" ]; do
    focus="$(adb_ shell dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=')"
    if printf '%s' "$focus" | grep -q 'com.android.credentialmanager' \
        && adb_ shell uiautomator dump /sdcard/ws_ui.xml >/dev/null 2>&1; then
      xml="$(adb_ shell cat /sdcard/ws_ui.xml 2>/dev/null)"
      if printf '%s' "$xml" | grep -q 'package="com.android.credentialmanager"'; then
        seen=$((seen + 1))
        [ "$seen" -le 6 ] && printf '%s' "$xml" > "$OUT/sheet-$seen.xml"
        for label in Continue Create Save "Use passkey" "Sign in"; do
          b="$(printf '%s' "$xml" | tr '>' '\n' \
            | grep "text=\"$label\"" | grep 'package="com.android.credentialmanager"' \
            | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 \
            | grep -o '[0-9]*' | tr '\n' ' ')"
          if [ -n "$b" ]; then
            set -- $b
            echo "tap '$label' at $((($1 + $3) / 2)),$((($2 + $4) / 2))" >> "$OUT/taps.log"
            adb_ shell input tap $((($1 + $3) / 2)) $((($2 + $4) / 2))
            break
          fi
        done
      fi
    fi
    sleep 1
  done
) &
TAP_PID=$!

run_phase() {
  local phase="$1"
  echo "── phase $phase ──"
  # A ceremony the previous phase left waiting keeps its sheet on top of
  # the next launch, and the app under test never gets to run.
  for _ in 1 2 3; do
    adb_ shell dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=' \
      | grep -q 'com.android.credentialmanager' || break
    adb_ shell input keyevent KEYCODE_BACK
    sleep 1
  done
  adb_ shell am force-stop "$APP_ID" >/dev/null 2>&1
  timeout -k 30s 20m $FLUTTER test integration_test/passkey_test.dart \
    -d "$device_id" --flavor fdebug \
    --dart-define=PASSKEY_GATE=true --dart-define=PASSKEY_GATE_PHASE="$phase" \
    2>&1 | tee "$OUT/phase-$phase.txt"
  return "${PIPESTATUS[0]}"
}

# Trust names the package; the provider pins the certificate of the first
# request it makes, as Bitwarden's "Trust" does with the caller's signature.
adb_ shell am broadcast -n "$PROVIDER_ID/.ControlReceiver" -a "$PROVIDER_ID.TRUST" \
  --es package "$APP_ID" >/dev/null
run_phase main
main_rc=$?
curl -fs "http://127.0.0.1:$PORT/results" > "$OUT/rp_results_main.json" || echo '[]' > "$OUT/rp_results_main.json"

gate_line() { grep -h "PASSKEY_GATE $1 " "$OUT"/phase-*.txt | head -1 | sed "s/.*PASSKEY_GATE $1 //"; }

# ── G1: the origin permission is held ───────────────────────────────────────
# `flutter test` may uninstall the app when it finishes; the app's own
# checkSelfPermission, which the test prints, stands in when it has.
adb_ shell dumpsys package "$APP_ID" > "$OUT/dumpsys_package.txt"
status="$(gate_line status)"
for perm in CREDENTIAL_MANAGER_SET_ORIGIN CREDENTIAL_MANAGER_QUERY_CANDIDATE_CREDENTIALS; do
  line="$(grep "android.permission.$perm:" "$OUT/dumpsys_package.txt" | head -1 | tr -d '\r' | sed 's/^ *//')"
  if printf '%s' "$line" | grep -q 'granted=true'; then
    pass G1-$perm "dumpsys: $line"
  elif [ -z "$line" ] && [ "$perm" = CREDENTIAL_MANAGER_SET_ORIGIN ] \
      && printf '%s' "$status" | grep -q '"permission":true'; then
    pass G1-$perm "app no longer installed; in-app checkSelfPermission: $status"
  elif [ -z "$line" ] && ! grep -q "Package \[$APP_ID\]" "$OUT/dumpsys_package.txt"; then
    note G1-$perm "app no longer installed, nothing to read"
  else
    fail G1-$perm "not granted: '${line:-absent}'"
  fi
done
rp() { node -e "
  const r = require('./$OUT/rp_results_main.json');
  const f = r.filter($1);
  process.stdout.write(JSON.stringify(f));
"; }

# ── G0: the page ────────────────────────────────────────────────────────────
probe="$(gate_line probe)"
echo "probe: $probe"
if printf '%s' "$probe" | grep -q '"secure":true' && printf '%s' "$probe" | grep -q '"uvpaa":true'; then
  pass G0-page "$probe"
else
  fail G0-page "probe was '${probe:-missing}'"
fi

# ── G2: registration, verified by the RP, asserted with the page origin ─────
reg="$(rp "e => e.ceremony === 'register' && e.name === 'alice'")"
prov_create="$(grep 'TESTPROVIDER.*create origin=' "$OUT/logcat.txt" | head -1 | tr -d '\r')"
if printf '%s' "$reg" | grep -q '"verified":true' \
    && printf '%s' "$reg" | grep -q '"origin":"http://localhost:8443"' \
    && printf '%s' "$prov_create" | grep -q 'create origin=http://localhost:8443 '; then
  pass G2-register "RP: $reg | provider: ${prov_create#*: }"
else
  fail G2-register "RP: ${reg:-none} | provider: ${prov_create:-no create line}"
fi

# ── G3: two sign-ins, counter rising ────────────────────────────────────────
logins="$(rp "e => e.ceremony === 'login' && e.name === 'alice'")"
prov_gets="$(grep 'TESTPROVIDER.*get origin=http://localhost:8443' "$OUT/logcat.txt" | tr -d '\r' | sed 's/.*: //' | head -4 | paste -sd'|' -)"
if [ "$(printf '%s' "$logins" | grep -o '"verified":true' | wc -l)" -ge 2 ] \
    && node -e "const l=$logins; process.exit(l.length>=2 && l[1].counter>l[0].counter ? 0 : 1)"; then
  pass G3-login "RP: $logins | provider: $prov_gets"
else
  fail G3-login "RP: ${logins:-none} | provider: ${prov_gets:-no get lines}"
fi

# ── G8: a second webview uses the first one's passkey ───────────────────────
bob="$(rp "e => e.name === 'bob'")"
if [ "$(printf '%s' "$bob" | grep -o '"verified":true' | wc -l)" -ge 2 ]; then
  pass G8-two-webviews "RP: $bob"
else
  fail G8-two-webviews "RP: ${bob:-none}"
fi
[ "$main_rc" -eq 0 ] || fail main-phase "integration test exited $main_rc (see $OUT/phase-main.txt)"

# ── G4: the provider stops trusting the app ─────────────────────────────────
adb_ shell am broadcast -n "$PROVIDER_ID/.ControlReceiver" -a "$PROVIDER_ID.CLEAR" >/dev/null
run_phase refused
refused_rc=$?
refused="$(gate_line refused-register)"
prov_refuse="$(grep "TESTPROVIDER.*refuse create caller=$APP_ID" "$OUT/logcat.txt" | head -1 | tr -d '\r')"
if [ "$refused_rc" -eq 0 ] && printf '%s' "$refused" | grep -q '"name":"NotAllowedError"' && [ -n "$prov_refuse" ]; then
  pass G4-refused "page: $refused | provider: ${prov_refuse#*: }"
else
  fail G4-refused "exit $refused_rc | page: ${refused:-none} | provider: ${prov_refuse:-no refusal line}"
fi
if grep -E "FATAL EXCEPTION|Process: $APP_ID" "$OUT/logcat.txt" | grep -q "$APP_ID"; then
  fail no-crash "$(grep -A3 'FATAL EXCEPTION' "$OUT/logcat.txt" | head -8 | tr -d '\r')"
else
  pass no-crash "no FATAL EXCEPTION for $APP_ID in logcat"
fi

# ── Path A: the WebView's own FOR_BROWSER WebAuthn, best effort ─────────────
adb_ shell am broadcast -n "$PROVIDER_ID/.ControlReceiver" -a "$PROVIDER_ID.TRUST" \
  --es package "$APP_ID" >/dev/null
run_phase webview
webview_rc=$?
note path-a "exit $webview_rc: $(gate_line webview)"

rm -f "$OUT/.tapping"
kill "$LOGCAT_PID" 2>/dev/null
curl -fs "http://127.0.0.1:$PORT/results" > "$OUT/rp_results.json" || true
grep 'TESTPROVIDER' "$OUT/logcat.txt" | tr -d '\r' > "$OUT/provider.log"

echo
echo "── passkey gate ──"
printf '%s\n' "${summary[@]}" | tee "$OUT/summary.txt"
exit "$failures"
