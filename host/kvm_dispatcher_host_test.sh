#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert() {
    "$@" || fail "assertion failed: $*"
}
assert_contains() {
    local haystack=$1 needle=$2
    [[ $haystack == *"$needle"* ]] || fail "expected output to contain: $needle"
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/config/repos.d" "$TMP_DIR/state" "$TMP_DIR/status" "$TMP_DIR/github" "$TMP_DIR/creds"
export PATH="$TMP_DIR/bin:$PATH"
export KVD_API_URL=https://api.github.test
export FAKE_GITHUB_DIR="$TMP_DIR/github"
export FAKE_ARGV_LOG="$TMP_DIR/argv.log"
export FAKE_SYSTEMCTL_ACTIVE="$TMP_DIR/active-units"
export FAKE_START_FAILURES="$TMP_DIR/start-failures"
export FAKE_START_LOG="$TMP_DIR/start.log"
export FAKE_STOP_LOG="$TMP_DIR/stop.log"
export FAKE_TOKEN_COUNT="$TMP_DIR/token-count"
export CREDENTIALS_DIRECTORY="$TMP_DIR/creds"
printf '%s\n' 'PRIVATE_KEY_DO_NOT_LEAK' > "$CREDENTIALS_DIRECTORY/app-key"
printf '0\n' > "$FAKE_START_FAILURES"
printf '0\n' > "$FAKE_TOKEN_COUNT"
: > "$FAKE_ARGV_LOG"
: > "$FAKE_SYSTEMCTL_ACTIVE"
: > "$FAKE_START_LOG"
: > "$FAKE_STOP_LOG"

cat > "$TMP_DIR/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"
config=$(</dev/stdin)
[[ $config == *'Authorization: Bearer '* ]] || { printf 'missing stdin authorization config\n' >&2; exit 4; }
method=GET
for ((i = 1; i <= $#; i++)); do
    if [[ ${!i} == --request ]]; then
        next=$((i + 1))
        method=${!next}
    fi
done
url=${!#}
path=${url#https://api.github.test}
status=200
body='{}'

if [[ $method == POST && $path == /app/installations/*/access_tokens ]]; then
    count=$(<"$FAKE_TOKEN_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_TOKEN_COUNT"
    token=${FAKE_TOKEN_VALUE:-ghs_fake_token_secret_$count}
    expiry=${FAKE_TOKEN_EXPIRY:-2026-01-01T01:00:00Z}
    body=$(printf '{"token":"%s","expires_at":"%s"}' "$token" "$expiry")
elif [[ $method == GET && $path == */actions/runs\?* ]]; then
    repo=${path#/repos/}
    repo=${repo%%/actions/runs*}
    repo_key=${repo//\//_}
    run_status=${path#*status=}
    run_status=${run_status%%&*}
    fixture="$FAKE_GITHUB_DIR/$repo_key.runs.$run_status.json"
    [[ -r $fixture ]] && body=$(<"$fixture") || body='{"workflow_runs":[]}'
elif [[ $method == GET && $path == */actions/runs/*/jobs\?* ]]; then
    repo=${path#/repos/}
    repo=${repo%%/actions/runs/*}
    repo_key=${repo//\//_}
    remainder=${path#*/actions/runs/}
    run_id=${remainder%%/*}
    fixture="$FAKE_GITHUB_DIR/$repo_key.jobs.$run_id.json"
    [[ -r $fixture ]] && body=$(<"$fixture") || body='{"jobs":[]}'
elif [[ $method == GET && $path == */actions/runners\?* ]]; then
    repo=${path#/repos/}
    repo=${repo%%/actions/runners*}
    repo_key=${repo//\//_}
    fixture="$FAKE_GITHUB_DIR/$repo_key.runners.json"
    [[ -r $fixture ]] && body=$(<"$fixture") || body='{"runners":[]}'
elif [[ $method == DELETE && $path == */actions/runners/* ]]; then
    body='{}'
    status=204
else
    status=404
    body='{"message":"fake route not found"}'
fi
if [[ -n ${FAKE_HTTP_FAIL_MATCH:-} && $path == *"$FAKE_HTTP_FAIL_MATCH"* ]]; then
    status=500
    body='{"message":"fake server error"}'
fi
printf '%s\n%s' "$body" "$status"
FAKE_CURL

cat > "$TMP_DIR/bin/openssl" <<'FAKE_OPENSSL'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
printf '%s\n' "$*" >> "$FAKE_ARGV_LOG"
if [[ ${1:-} == dgst ]]; then
    cat >/dev/null
    printf 'fake-rsa-signature'
elif [[ ${1:-} == base64 ]]; then
    exec /usr/bin/base64 -w0
else
    printf 'unexpected fake openssl invocation\n' >&2
    exit 2
fi
FAKE_OPENSSL

cat > "$TMP_DIR/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
command=${1:-}
shift || true
case $command in
    list-units)
        while IFS= read -r unit; do
            [[ -n $unit ]] && printf '%s loaded active running KVM job\n' "$unit"
        done < "$FAKE_SYSTEMCTL_ACTIVE"
        ;;
    is-active)
        [[ ${1:-} == --quiet ]] && shift
        grep -Fxq -- "${1:-}" "$FAKE_SYSTEMCTL_ACTIVE"
        ;;
    start)
        unit=${1:?missing unit}
        printf '%s\n' "$unit" >> "$FAKE_START_LOG"
        failures=$(<"$FAKE_START_FAILURES")
        if (( failures > 0 )); then
            printf '%s\n' "$((failures - 1))" > "$FAKE_START_FAILURES"
            exit 1
        fi
        grep -Fxq -- "$unit" "$FAKE_SYSTEMCTL_ACTIVE" || printf '%s\n' "$unit" >> "$FAKE_SYSTEMCTL_ACTIVE"
        ;;
    stop)
        unit=${1:?missing unit}
        printf '%s\n' "$unit" >> "$FAKE_STOP_LOG"
        tmp="$FAKE_SYSTEMCTL_ACTIVE.tmp"
        grep -Fxv -- "$unit" "$FAKE_SYSTEMCTL_ACTIVE" > "$tmp" || true
        mv "$tmp" "$FAKE_SYSTEMCTL_ACTIVE"
        ;;
    show)
        property=
        unit=${!#}
        for arg in "$@"; do
            case $arg in
                --property=*) property=${arg#--property=} ;;
                -p) ;;
                *) [[ $arg == "$unit" ]] || true ;;
            esac
        done
        case $property in
            ExecMainStatus) printf '%s\n' "${FAKE_EXEC_MAIN_STATUS:-0}" ;;
            ControlGroup) printf '/system.slice/%s\n' "$unit" ;;
            MemoryPeak) printf '%s\n' "${FAKE_MEMORY_PEAK:-12582912}" ;;
            ActiveEnterTimestamp) printf '%s\n' '2026-01-01 00:00:00 UTC' ;;
            *) printf '\n' ;;
        esac
        ;;
    *)
        printf 'unsupported fake systemctl command: %s\n' "$command" >&2
        exit 2
        ;;
esac
FAKE_SYSTEMCTL
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/openssl" "$TMP_DIR/bin/systemctl"

BASE_NOW=$(date -u -d '2026-01-01T00:00:00Z' +%s)
export FAKE_TOKEN_EXPIRY=2026-01-01T01:00:00Z

write_config() {
    local capacity=${1:-12288} priority=${2:-}
    mkdir -p "$TMP_DIR/config/repos.d"
    printf '%s\n' \
        'KVM_DISPATCHER_APP_ID=5405924' \
        'KVM_DISPATCHER_INSTALLATION_QNIAPP=173623654' \
        'KVM_DISPATCHER_INSTALLATION_QORRAQ=173623739' \
        'KVM_DISPATCHER_INSTALLATIONS="qniapp qorraq"' \
        'KVM_DISPATCHER_REPOSITORY_QNIAPP=qniapp/qa2' \
        'KVM_DISPATCHER_REPOSITORY_QORRAQ=qorraq/qoral' \
        "KVM_DISPATCHER_CAPACITY_MIB=$capacity" \
        'KVM_DISPATCHER_POLL_SECONDS=20' \
        "KVM_DISPATCHER_PRIORITY=$priority" \
        "KVM_DISPATCHER_REPOS_DIR=$TMP_DIR/config/repos.d" \
        "KVM_DISPATCHER_STATE_DIR=$TMP_DIR/state" \
        "KVM_DISPATCHER_STATUS_FILE=$TMP_DIR/status/status.json" > "$TMP_DIR/config/dispatcher.conf"
    cp "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TMP_DIR/config/repos.d/qa2.conf"
    cp "$ROOT_DIR/host/repos.d/qoral.conf.example" "$TMP_DIR/config/repos.d/qoral.conf"
    export KVM_DISPATCHER_CONFIG="$TMP_DIR/config/dispatcher.conf"
    export KVM_DISPATCHER_TEST_NOW=$BASE_NOW
    export KVM_DISPATCHER_ONCE=1
}

clear_fixtures() {
    rm -f "$FAKE_GITHUB_DIR"/*
    : > "$FAKE_SYSTEMCTL_ACTIVE"
    : > "$FAKE_START_LOG"
    : > "$FAKE_STOP_LOG"
    : > "$FAKE_ARGV_LOG"
    printf '0\n' > "$FAKE_START_FAILURES"
    printf '0\n' > "$FAKE_TOKEN_COUNT"
    rm -rf "$TMP_DIR/state" "$TMP_DIR/status"
    mkdir -p "$TMP_DIR/state" "$TMP_DIR/status"
    write_config
    for repo in qniapp_qa2 qorraq_qoral; do
        for status in queued pending in_progress; do
            printf '{"workflow_runs":[]}\n' > "$FAKE_GITHUB_DIR/$repo.runs.$status.json"
        done
        printf '{"runners":[]}\n' > "$FAKE_GITHUB_DIR/$repo.runners.json"
    done
}

set_runs() {
    local repo_key=$1 status=$2 runs_json=$3
    printf '{"workflow_runs":%s}\n' "$runs_json" > "$FAKE_GITHUB_DIR/$repo_key.runs.$status.json"
}
set_jobs() {
    local repo_key=$1 run_id=$2 jobs_json=$3
    printf '{"jobs":%s}\n' "$jobs_json" > "$FAKE_GITHUB_DIR/$repo_key.jobs.$run_id.json"
}
run_dispatcher() {
    "$ROOT_DIR/host/kvm_dispatcher.sh" > "$TMP_DIR/output.log" 2>&1 || {
        printf '%s\n' 'dispatcher output:' >&2
        printf '%s\n' "$(<"$TMP_DIR/output.log")" >&2
        fail 'dispatcher exited nonzero'
    }
}

add_job_state() {
    local adapter=$1 repo=$2 job_id=$3 unit=$4 started=$5 max_seconds=$6
    mkdir -p "$TMP_DIR/state/jobs/$job_id"
    jq -cn --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$job_id" \
        --arg unit "$unit" --arg phase RUNNING --arg since '2026-01-01T00:00:00Z' \
        --argjson claimed_epoch "$started" --argjson started_epoch "$started" \
        --argjson memory_mib 12288 --argjson max_unit_seconds "$max_seconds" \
        '{adapter:$adapter,repo:$repo,job_id:$job_id,unit:$unit,phase:$phase,since:$since,claimed_epoch:$claimed_epoch,started_epoch:$started_epoch,memory_mib:$memory_mib,max_unit_seconds:$max_unit_seconds}' > "$TMP_DIR/state/jobs/$job_id/state.json"
    printf 'old-token' > "$TMP_DIR/state/jobs/$job_id/github-token"
    printf '%s\n' "$unit" >> "$FAKE_SYSTEMCTL_ACTIVE"
}

# With no adapters installed, the service still verifies both GitHub App installations.
clear_fixtures
rm -f "$TMP_DIR/config/repos.d"/*.conf
run_dispatcher
assert_contains "$(<"$FAKE_ARGV_LOG")" '/repos/qniapp/qa2/actions/runners?per_page=100'
assert_contains "$(<"$FAKE_ARGV_LOG")" '/repos/qorraq/qoral/actions/runners?per_page=100'
[[ $(jq '.last_poll | length' "$TMP_DIR/status/status.json") -eq 2 ]] || fail 'empty-adapter installation probe was incomplete'

# Queued and pending runs are both scanned. The oldest pending Qoral job wins FIFO;
# capacity=12 GiB then holds the QA2 job until the slot is free.
clear_fixtures
set_runs qniapp_qa2 queued '[{"id":101}]'
set_jobs qniapp_qa2 101 '[{"id":1001,"status":"queued","created_at":"2026-01-01T00:00:10Z","labels":["qa2-kvm"]}]'
set_runs qorraq_qoral pending '[{"id":201}]'
set_jobs qorraq_qoral 201 '[{"id":2001,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["self-hosted","linux","x64","qoral-kvm"]}]'
run_dispatcher
assert_contains "$(<"$FAKE_START_LOG")" 'qoral-runner-job@2001.service'
[[ $(wc -l < "$FAKE_START_LOG") -eq 1 ]] || fail 'capacity semaphore started more than one 12 GiB job'
[[ $(jq '.queued | length' "$TMP_DIR/status/status.json") -eq 1 ]] || fail 'queued status did not separate the in-flight job from waiting jobs'
[[ $(jq '.in_flight | length' "$TMP_DIR/status/status.json") -eq 1 ]] || fail 'status did not include the running job'
jq -e 'keys == ["blocked","capacity_mib","in_flight","last_poll","queued","updated_at"] and .capacity_mib == 12288 and (.in_flight|type == "array") and (.queued|type == "array") and (.last_poll|type == "object") and (.blocked|type == "array")' "$TMP_DIR/status/status.json" >/dev/null || fail 'status.json shape is incorrect'

# Configurable priority puts QA2 first even when its job is newer.
clear_fixtures
write_config 12288 qa2
set_runs qniapp_qa2 queued '[{"id":102}]'
set_jobs qniapp_qa2 102 '[{"id":1002,"status":"queued","created_at":"2026-01-01T00:00:20Z","labels":["qa2-kvm"]}]'
set_runs qorraq_qoral pending '[{"id":202}]'
set_jobs qorraq_qoral 202 '[{"id":2002,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qoral-kvm"]}]'
run_dispatcher
assert_contains "$(<"$FAKE_START_LOG")" 'qa2-runner-job@1002.service'
[[ $(wc -l < "$FAKE_START_LOG") -eq 1 ]] || fail 'priority scheduling did not preserve single-slot capacity'

# Per-repository concurrency is independent of total host capacity.
clear_fixtures
write_config 24576
set_runs qniapp_qa2 queued '[{"id":103}]'
set_jobs qniapp_qa2 103 '[{"id":1003,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]},{"id":1004,"status":"queued","created_at":"2026-01-01T00:00:02Z","labels":["qa2-kvm"]}]'
run_dispatcher
[[ $(grep -c '^qa2-runner-job@' "$FAKE_START_LOG") -eq 1 ]] || fail 'per-repository concurrency cap was exceeded'

# A failed systemd start is backed off for 300s and blocked on the third failure.
clear_fixtures
set_runs qniapp_qa2 queued '[{"id":104}]'
set_jobs qniapp_qa2 104 '[{"id":1005,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]}]'
printf '3\n' > "$FAKE_START_FAILURES"
run_dispatcher
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 299))
run_dispatcher
[[ $(wc -l < "$FAKE_START_LOG") -eq 1 ]] || fail 'start failure was not backed off'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 300))
run_dispatcher
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 600))
run_dispatcher
[[ $(wc -l < "$FAKE_START_LOG") -eq 3 ]] || fail 'dispatcher did not retry exactly three times'
jq -e '.blocked | any(.[]; .job_id == "1005" and .attempts == 3)' "$TMP_DIR/status/status.json" >/dev/null || fail 'three-strike blocked list is missing the job'

# A vanished, non-busy job stops its unit and sweeps its runner registration.
clear_fixtures
add_job_state qa2 qniapp/qa2 1006 qa2-runner-job@1006.service "$BASE_NOW" 5400
printf '{"runners":[{"id":77,"name":"qa2-kvm-1006","status":"online","busy":false}]}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.runners.json"
run_dispatcher
assert_contains "$(<"$FAKE_STOP_LOG")" 'qa2-runner-job@1006.service'
if ! grep -Fq 'DELETE' "$FAKE_ARGV_LOG"; then
    printf 'cancel dispatcher output:\n%s\nargv:\n%s\n' "$(<"$TMP_DIR/output.log")" "$(<"$FAKE_ARGV_LOG")" >&2
    fail 'cancel cleanup did not delete the runner registration'
fi

# Finished units report cgroup memory peaks and are not relaunched for a still-queued job ID.
clear_fixtures
add_job_state qa2 qniapp/qa2 1010 qa2-runner-job@1010.service "$((BASE_NOW - 90))" 5400
: > "$FAKE_SYSTEMCTL_ACTIVE"
set_runs qniapp_qa2 queued '[{"id":105}]'
set_jobs qniapp_qa2 105 '[{"id":1010,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]}]'
run_dispatcher
assert_contains "$(<"$TMP_DIR/output.log")" 'event=job-finished unit=qa2-runner-job@1010.service exit=0 duration=90s memory_peak_mib=12'
[[ ! -s $FAKE_START_LOG ]] || fail 'dispatcher relaunched a job ID after its runner unit had already run'
jq -e '.blocked | any(.[]; .job_id == "1010" and .reason == "unit-already-ran")' "$TMP_DIR/status/status.json" >/dev/null || fail 'consumed queued job was not exposed as blocked'

# A unit over its adapter limit is stopped, independent of GitHub visibility.
clear_fixtures
add_job_state qa2 qniapp/qa2 1007 qa2-runner-job@1007.service "$((BASE_NOW - 5401))" 5400
run_dispatcher
assert_contains "$(<"$FAKE_STOP_LOG")" 'qa2-runner-job@1007.service'

# Startup resync adopts an active configured unit whose state file was lost.
clear_fixtures
printf '%s\n' 'qoral-runner-job@1011.service' > "$FAKE_SYSTEMCTL_ACTIVE"
printf '{"runners":[{"id":66,"name":"qoral-kvm-1011","status":"online","busy":true}]}\n' > "$FAKE_GITHUB_DIR/qorraq_qoral.runners.json"
run_dispatcher
jq -e '.in_flight | any(.[]; .job_id == "1011" and .unit == "qoral-runner-job@1011.service")' "$TMP_DIR/status/status.json" >/dev/null || fail 'startup resync did not adopt the active unit'
[[ $(jq -r '.phase' "$TMP_DIR/state/jobs/1011/state.json") == RUNNING ]] || fail 'adopted unit has the wrong phase'

# Startup resync removes offline registrations with no active unit.
clear_fixtures
printf '{"runners":[{"id":88,"name":"qa2-kvm-1008","status":"offline","busy":false},{"id":89,"name":"unrelated-1008","status":"offline","busy":false}]}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.runners.json"
run_dispatcher
assert_contains "$(<"$FAKE_ARGV_LOG")" '/repos/qniapp/qa2/actions/runners/88'
[[ $(grep -c 'DELETE' "$FAKE_ARGV_LOG") -eq 1 ]] || fail 'resync deleted a non-matching runner or missed its orphan'

# Installation tokens are reused at exactly 10 minutes remaining and refreshed below it.
clear_fixtures
export KVM_DISPATCHER_TEST_NOW=$BASE_NOW
# Load the helper in this process so the cache is not invalidated by startup resync.
# shellcheck source=host/kvm_dispatcher_lib.sh
source "$ROOT_DIR/host/kvm_dispatcher_lib.sh"
kvd_load_config
add_job_state qa2 qniapp/qa2 1009 qa2-runner-job@1009.service "$BASE_NOW" 5400
kvd_get_installation_token qniapp
[[ $(<"$FAKE_TOKEN_COUNT") -eq 1 ]] || fail 'initial installation token was not fetched'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 3000))
kvd_get_installation_token qniapp
[[ $(<"$FAKE_TOKEN_COUNT") -eq 1 ]] || fail 'token refreshed at exactly 10 minutes remaining'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 3001))
kvd_get_installation_token qniapp
[[ $(<"$FAKE_TOKEN_COUNT") -eq 2 ]] || fail 'token was not refreshed with less than 10 minutes remaining'
[[ $(<"$TMP_DIR/state/jobs/1009/github-token") == ghs_fake_token_secret_2 ]] || fail 'refreshed installation token was not made available to the running job'

# GitHub failures back off 20/60/300 seconds while active units remain monitored.
clear_fixtures
export FAKE_HTTP_FAIL_MATCH='/repos/qniapp/qa2/actions/runs?status=queued'
source "$ROOT_DIR/host/kvm_dispatcher_lib.sh"
kvd_load_config
add_job_state qa2 qniapp/qa2 1012 qa2-runner-job@1012.service "$BASE_NOW" 5400
kvd_poll_all
kvd_monitor_inflight
[[ -z $(<"$FAKE_STOP_LOG") ]] || fail 'poll failure incorrectly cancelled an in-flight unit'
[[ ${KVD_NEXT_POLL[qa2]} -eq $((BASE_NOW + 20)) ]] || fail 'first GitHub error backoff is not 20 seconds'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 19))
kvd_poll_all
[[ ${KVD_POLL_FAILURES[qa2]} -eq 1 ]] || fail 'adapter was polled before its first backoff expired'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 20))
kvd_poll_all
[[ ${KVD_NEXT_POLL[qa2]} -eq $((BASE_NOW + 80)) ]] || fail 'second GitHub error backoff is not 60 seconds'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 80))
kvd_poll_all
[[ ${KVD_NEXT_POLL[qa2]} -eq $((BASE_NOW + 380)) ]] || fail 'repeated GitHub errors did not back off for 300 seconds'
unset FAKE_HTTP_FAIL_MATCH

# Neither secret contents nor installation tokens may appear in process argv.
if grep -F -e 'PRIVATE_KEY_DO_NOT_LEAK' -e 'ghs_fake_token_secret' "$FAKE_ARGV_LOG"; then
    fail 'a private key or GitHub token appeared in argv'
fi

# Verify that the polkit expression allows only the intended template units.
rule_file="$ROOT_DIR/host/polkit/50-kvm-dispatcher.rules"
rule_line=$(grep -F 'var allowedUnit =' "$rule_file")
pattern=${rule_line#*= /}
pattern=${pattern%;*}
pattern=${pattern%/}
for unit in qa2-runner-job@123.service qoral-runner-job@a-1.service qa2-agent-loop-runner-job@0.service; do
    [[ $unit =~ $pattern ]] || fail "polkit regex rejected $unit"
done
for unit in qa2-runner@123.service qoral-runner-job@ABC.service qa2-runner-job@123.service.service; do
    [[ ! $unit =~ $pattern ]] || fail "polkit regex accepted $unit"
done

# Verify the unit together with its isolation drop-in in a disposable systemd root.
VERIFY_ROOT="$TMP_DIR/systemd-root"
mkdir -p "$VERIFY_ROOT/etc/systemd/system/kvm-dispatcher.service.d" "$VERIFY_ROOT/opt/kvm-dispatcher/host"
cp "$ROOT_DIR/host/systemd/kvm-dispatcher.service" "$VERIFY_ROOT/etc/systemd/system/kvm-dispatcher.service"
cp "$ROOT_DIR/host/systemd/kvm-dispatcher.service.d/10-isolation.conf" "$VERIFY_ROOT/etc/systemd/system/kvm-dispatcher.service.d/10-isolation.conf"
cp "$ROOT_DIR/host/kvm_dispatcher.sh" "$ROOT_DIR/host/kvm_dispatcher_lib.sh" "$VERIFY_ROOT/opt/kvm-dispatcher/host/"
chmod +x "$VERIFY_ROOT/opt/kvm-dispatcher/host/kvm_dispatcher.sh"
systemd-analyze verify --root="$VERIFY_ROOT" kvm-dispatcher.service

bash -n "$ROOT_DIR/host/kvm_dispatcher.sh" "$ROOT_DIR/host/kvm_dispatcher_lib.sh" "$ROOT_DIR/host/kvm_dispatcher_sweep.sh" "$ROOT_DIR/host/kvm_dispatcher_host_wizard.sh"
shellcheck -x "$ROOT_DIR/host/kvm_dispatcher.sh" "$ROOT_DIR/host/kvm_dispatcher_lib.sh" "$ROOT_DIR/host/kvm_dispatcher_sweep.sh" "$ROOT_DIR/host/kvm_dispatcher_host_wizard.sh" "$ROOT_DIR/host/kvm_dispatcher_host_test.sh"
printf 'PASS: dispatcher host tests\n'
