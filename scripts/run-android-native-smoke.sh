#!/usr/bin/env bash
# Run the Android integration smoke under a bounded timeout and keep device logs.
#
# Used by Clients / android-native-smoke. The emulator-runner action executes the
# `script` input one line at a time, so the whole bounded run has to live in a
# file rather than in the workflow. The debug APK and its Gradle dependencies are
# pre-built by an earlier workflow step; this only installs and runs the test.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log_path="${repo_root}/android-native-smoke-logcat.txt"
# Ten minutes is roughly ten times the observed post-install test duration, and a
# wait for the Dart VM service is the failure mode this bound exists for.
timeout_seconds="${ANDROID_SMOKE_TIMEOUT_SECONDS:-600}"
device="${ANDROID_SMOKE_DEVICE:-emulator-5554}"

cd "${repo_root}/clients/flutter"

status=0
timeout --signal=INT --kill-after=30 "${timeout_seconds}" \
  flutter test integration_test/android_native_test.dart -d "${device}" --no-pub --reporter expanded \
  || status=$?

if [ "${status}" -ne 0 ]; then
  echo "android native smoke exited with status ${status}; capturing device logcat"
  adb -s "${device}" logcat -d -t 3000 > "${log_path}" 2>&1 || true
fi

exit "${status}"
