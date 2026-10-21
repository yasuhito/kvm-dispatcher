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

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/config/repos.d" "$TMP_DIR/state" "$TMP_DIR/status" "$TMP_DIR/github" "$TMP_DIR/journal" "$TMP_DIR/creds"
export PATH="$TMP_DIR/bin:$PATH"
export KVD_API_URL=https://api.github.test
export FAKE_GITHUB_DIR="$TMP_DIR/github"
export FAKE_JOURNAL_DIR="$TMP_DIR/journal"
export FAKE_ARGV_LOG="$TMP_DIR/argv.log"
export FAKE_SYSTEMCTL_ACTIVE="$TMP_DIR/active-units"
export FAKE_START_FAILURES="$TMP_DIR/start-failures"
export FAKE_START_LOG="$TMP_DIR/start.log"
export FAKE_STOP_LOG="$TMP_DIR/stop.log"
export FAKE_TOKEN_COUNT="$TMP_DIR/token-count"
export FAKE_CHGRP_LOG="$TMP_DIR/chgrp.log"
export FAKE_DISPATCHER_GROUPS='kvm-dispatcher systemd-journal qa2-runner-host qoral-runner-host'
export CREDENTIALS_DIRECTORY="$TMP_DIR/creds"
printf '%s\n' 'PRIVATE_KEY_DO_NOT_LEAK' > "$CREDENTIALS_DIRECTORY/app-key"
printf '0\n' > "$FAKE_START_FAILURES"
printf '0\n' > "$FAKE_TOKEN_COUNT"
: > "$FAKE_ARGV_LOG"
: > "$FAKE_SYSTEMCTL_ACTIVE"
: > "$FAKE_START_LOG"
: > "$FAKE_STOP_LOG"
: > "$FAKE_CHGRP_LOG"

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
elif [[ $method == GET && $path == */actions/jobs/* ]]; then
    repo=${path#/repos/}
    repo=${repo%%/actions/jobs/*}
    repo_key=${repo//\//_}
    fixture="$FAKE_GITHUB_DIR/$repo_key.job.${path##*/}.json"
    if [[ -r $fixture ]]; then
        body=$(<"$fixture")
    else
        status=404
        body='{"message":"fake job not found"}'
    fi
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
cat > "$TMP_DIR/bin/journalctl" <<'FAKE_JOURNALCTL'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
unit=
for arg in "$@"; do
    case $arg in
        --unit=*) unit=${arg#--unit=} ;;
    esac
done
[[ -n $unit ]] || { printf 'fake journalctl requires --unit\n' >&2; exit 2; }
fixture="$FAKE_JOURNAL_DIR/$unit.log"
[[ -r $fixture ]] && cat "$fixture"
exit 0
FAKE_JOURNALCTL
# The test user cannot join the adapter job groups, so group changes are recorded by
# inode (a rename keeps it), and the dispatcher's groups come from FAKE_DISPATCHER_GROUPS.
cat > "$TMP_DIR/bin/chgrp" <<'FAKE_CHGRP'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
group=$1
shift
for path in "$@"; do
    [[ -e $path ]] || { printf 'chgrp: missing %s\n' "$path" >&2; exit 1; }
    printf '%s %s %s\n' "$(stat -c %i "$path")" "$group" "$path" >> "$FAKE_CHGRP_LOG"
done
FAKE_CHGRP
cat > "$TMP_DIR/bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
[[ $# -eq 1 && $1 == -nG ]] || { printf 'unexpected fake id invocation\n' >&2; exit 2; }
printf '%s\n' "$FAKE_DISPATCHER_GROUPS"
FAKE_ID
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/openssl" "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/journalctl" "$TMP_DIR/bin/chgrp" "$TMP_DIR/bin/id"

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
    rm -f "$FAKE_GITHUB_DIR"/* "$FAKE_JOURNAL_DIR"/*
    : > "$FAKE_SYSTEMCTL_ACTIVE"
    : > "$FAKE_START_LOG"
    : > "$FAKE_STOP_LOG"
    : > "$FAKE_ARGV_LOG"
    : > "$FAKE_CHGRP_LOG"
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
# Journal lines in the format the QA2 and Qoral job scripts write to their unit.
journal_minted() {
    local unit=$1 runner_id=$2 runner_name=$3
    printf '2026-01-01T00:00:01Z qa2-runner: job=%s event=jitconfig-minted runner_id=%s runner_name=%s\n' \
        "${runner_name#*-kvm-}" "$runner_id" "$runner_name" >> "$FAKE_JOURNAL_DIR/$unit.log"
}
journal_deleted() {
    local unit=$1 runner_id=$2
    printf '2026-01-01T00:01:00Z qa2-runner: job=x event=runner-deleted runner_id=%s http=204\n' "$runner_id" >> "$FAKE_JOURNAL_DIR/$unit.log"
}
fake_group_of() {
    local inode
    inode=$(stat -c %i "$1")
    awk -v inode="$inode" '$1 == inode { group = $2 } END { print (group == "" ? "kvm-dispatcher" : group) }' "$FAKE_CHGRP_LOG"
}
# Whether a job user whose group is $1, and who is not the kvm-dispatcher owner, can
# traverse every directory below the state root and read $2.
job_group_can_read() {
    local group=$1 path=$2 current="$TMP_DIR/state" mode digit part
    local -a parts=()
    IFS=/ read -r -a parts <<< "${path#"$TMP_DIR/state/"}"
    for part in "${parts[@]}" ''; do
        mode=$(stat -c %a "$current")
        if [[ $(fake_group_of "$current") == "$group" ]]; then
            digit=${mode: -2:1}
        else
            digit=${mode: -1}
        fi
        if [[ -n $part ]]; then
            (( digit & 1 )) || return 1
            current="$current/$part"
        else
            (( digit & 4 )) || return 1
        fi
    done
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

# Each job token is readable only through its own adapter's job group: a QA2 job user
# cannot read a Qoral token, and a Qoral job user cannot read a QA2 token.
clear_fixtures
write_config 24576
set_runs qniapp_qa2 queued '[{"id":101}]'
set_jobs qniapp_qa2 101 '[{"id":1001,"status":"queued","created_at":"2026-01-01T00:00:10Z","labels":["qa2-kvm"]}]'
set_runs qorraq_qoral queued '[{"id":201}]'
set_jobs qorraq_qoral 201 '[{"id":2001,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qoral-kvm"]}]'
run_dispatcher
[[ $(wc -l < "$FAKE_START_LOG") -eq 2 ]] || fail 'two-slot capacity did not start both adapters'
[[ $(stat -c %a "$TMP_DIR/state") == 711 && $(stat -c %a "$TMP_DIR/state/jobs") == 711 ]] || fail 'runtime directories are not traversal-only 0711'
[[ $(stat -c %a "$TMP_DIR/state/tokens") == 700 ]] || fail 'installation token cache is not private'
for job_id in 1001 2001; do
    [[ $(stat -c %a "$TMP_DIR/state/jobs/$job_id") == 750 ]] || fail "job directory $job_id is not 0750"
    [[ $(stat -c %a "$TMP_DIR/state/jobs/$job_id/github-token") == 640 ]] || fail "job token $job_id is not 0640"
    [[ $(stat -c %a "$TMP_DIR/state/jobs/$job_id/state.json") == 600 ]] || fail "job state $job_id is not private"
done
qa2_token="$TMP_DIR/state/jobs/1001/github-token"
qoral_token="$TMP_DIR/state/jobs/2001/github-token"
[[ $(fake_group_of "$qa2_token") == qa2-runner-host && $(fake_group_of "$qoral_token") == qoral-runner-host ]] || fail 'job tokens do not carry their adapter job group'
job_group_can_read qa2-runner-host "$qa2_token" || fail 'QA2 job user cannot read its own token'
job_group_can_read qoral-runner-host "$qoral_token" || fail 'Qoral job user cannot read its own token'
! job_group_can_read qa2-runner-host "$qoral_token" || fail 'QA2 job user can read a Qoral token'
! job_group_can_read qoral-runner-host "$qa2_token" || fail 'Qoral job user can read a QA2 token'

# Startup refuses an adapter whose job group the dispatcher does not belong to.
clear_fixtures
if FAKE_DISPATCHER_GROUPS='kvm-dispatcher systemd-journal qa2-runner-host' "$ROOT_DIR/host/kvm_dispatcher.sh" > "$TMP_DIR/output.log" 2>&1; then
    fail 'dispatcher started although it is not in the qoral-runner-host group'
fi
assert_contains "$(<"$TMP_DIR/output.log")" 'usermod -aG qoral-runner-host kvm-dispatcher'

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

# A failing installation does not hold back scheduling for another repository.
clear_fixtures
export FAKE_HTTP_FAIL_MATCH='/repos/qorraq/qoral/actions/runs'
set_runs qniapp_qa2 queued '[{"id":106}]'
set_jobs qniapp_qa2 106 '[{"id":1014,"status":"queued","created_at":"2026-01-01T00:00:10Z","labels":["qa2-kvm"]}]'
run_dispatcher
unset FAKE_HTTP_FAIL_MATCH
assert_contains "$(<"$FAKE_START_LOG")" 'qa2-runner-job@1014.service'
assert_contains "$(<"$TMP_DIR/output.log")" 'event=poll-error http=500 repo=qorraq/qoral'

# A vanished, non-busy job stops its unit and deletes the registration named in its journal,
# because the script did not log its own successful DELETE.
clear_fixtures
add_job_state qa2 qniapp/qa2 1006 qa2-runner-job@1006.service "$BASE_NOW" 5400
journal_minted qa2-runner-job@1006.service 77 qa2-kvm-20260101T000001Z-4242
printf '{"runners":[{"id":77,"name":"qa2-kvm-20260101T000001Z-4242","status":"online","busy":false}]}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.runners.json"
run_dispatcher
assert_contains "$(<"$FAKE_STOP_LOG")" 'qa2-runner-job@1006.service'
assert_contains "$(<"$FAKE_ARGV_LOG")" '--request DELETE'
assert_contains "$(<"$FAKE_ARGV_LOG")" '/repos/qniapp/qa2/actions/runners/77'
[[ ! -e $TMP_DIR/state/jobs/1006 ]] || fail 'cancelled job state was not swept'

# Per-job SWEPT leaves the registration alone when the script logged its own DELETE.
clear_fixtures
add_job_state qa2 qniapp/qa2 1015 qa2-runner-job@1015.service "$((BASE_NOW - 60))" 5400
: > "$FAKE_SYSTEMCTL_ACTIVE"
journal_minted qa2-runner-job@1015.service 78 qa2-kvm-20260101T000002Z-4243
journal_deleted qa2-runner-job@1015.service 78
printf '{"runners":[{"id":78,"name":"qa2-kvm-20260101T000002Z-4243","status":"offline","busy":false}]}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.runners.json"
source "$ROOT_DIR/host/kvm_dispatcher_lib.sh"
kvd_load_config
kvd_handle_inactive_job 1015 > "$TMP_DIR/output.log"
! grep -Fq -- '--request DELETE' "$FAKE_ARGV_LOG" || fail 'SWEPT deleted a registration the job script had already deleted'
assert_contains "$(<"$TMP_DIR/output.log")" 'event=job-swept repo=qniapp/qa2 job=1015'

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
assert_contains "$(<"$TMP_DIR/output.log")" 'event=job-attribution-unknown repo=qniapp/qa2 job=1010'

# The runner started for job X took the newer job Y. X was not run, so it is not consumed:
# it counts as a start failure, returns after 300 seconds, and a worker that never runs
# it is blocked on the third strike instead of relaunching guests without limit.
clear_fixtures
add_job_state qa2 qniapp/qa2 1017 qa2-runner-job@1017.service "$((BASE_NOW - 90))" 5400
: > "$FAKE_SYSTEMCTL_ACTIVE"
journal_minted qa2-runner-job@1017.service 81 qa2-kvm-20260101T000003Z-4244
journal_deleted qa2-runner-job@1017.service 81
set_runs qniapp_qa2 queued '[{"id":108}]'
set_jobs qniapp_qa2 108 '[{"id":1017,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]}]'
printf '{"id":1017,"status":"queued","runner_name":null}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.job.1017.json"
printf '{"id":1018,"status":"completed","runner_name":"qa2-kvm-20260101T000003Z-4244"}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.job.1018.json"
run_dispatcher
assert_contains "$(<"$TMP_DIR/output.log")" 'event=job-not-run repo=qniapp/qa2 job=1017 runner=qa2-kvm-20260101T000003Z-4244 reason=runner-idle'
[[ ! -s $FAKE_START_LOG ]] || fail 'a job the runner did not run was relaunched before its retry delay'
jq -e '.attempts == 1 and .blocked == false and (.consumed // false) == false' "$TMP_DIR/status/attempts/1017.json" >/dev/null || fail 'job-not-run was not recorded as the first strike'
for strike in 2 3; do
    export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + (strike - 1) * 301))
    run_dispatcher
    [[ $(grep -c '^qa2-runner-job@1017.service$' "$FAKE_START_LOG") -eq $((strike - 1)) ]] || fail "job-not-run job was not retried after 300 seconds (strike $strike)"
    : > "$FAKE_SYSTEMCTL_ACTIVE"
    export FAKE_EXEC_MAIN_STATUS=1
    export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + (strike - 1) * 301 + 1))
    run_dispatcher
    unset FAKE_EXEC_MAIN_STATUS
    assert_contains "$(<"$TMP_DIR/output.log")" 'event=job-not-run repo=qniapp/qa2 job=1017 runner=qa2-kvm-20260101T000003Z-4244 reason=exit-nonzero'
done
assert_contains "$(<"$TMP_DIR/output.log")" 'event=job-blocked repo=qniapp/qa2 job=1017 attempts=3'
export KVM_DISPATCHER_TEST_NOW=$((BASE_NOW + 1200))
run_dispatcher
[[ $(grep -c '^qa2-runner-job@1017.service$' "$FAKE_START_LOG") -eq 2 ]] || fail 'a blocked job-not-run job was relaunched'
jq -e '.blocked | any(.[]; .job_id == "1017" and .attempts == 3 and .reason == "start-failures")' "$TMP_DIR/status/status.json" >/dev/null || fail 'third job-not-run strike did not block the job'
export KVM_DISPATCHER_TEST_NOW=$BASE_NOW

# When the unit's own runner ran X, X is consumed and not relaunched.
clear_fixtures
add_job_state qa2 qniapp/qa2 1017 qa2-runner-job@1017.service "$((BASE_NOW - 90))" 5400
: > "$FAKE_SYSTEMCTL_ACTIVE"
journal_minted qa2-runner-job@1017.service 81 qa2-kvm-20260101T000003Z-4244
journal_deleted qa2-runner-job@1017.service 81
set_runs qniapp_qa2 queued '[{"id":108}]'
set_jobs qniapp_qa2 108 '[{"id":1017,"status":"queued","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]}]'
printf '{"id":1017,"status":"queued","runner_name":"qa2-kvm-20260101T000003Z-4244"}\n' > "$FAKE_GITHUB_DIR/qniapp_qa2.job.1017.json"
run_dispatcher
[[ ! -s $FAKE_START_LOG ]] || fail 'dispatcher relaunched a job its own runner had run'
jq -e '.blocked | any(.[]; .job_id == "1017" and .reason == "unit-already-ran")' "$TMP_DIR/status/status.json" >/dev/null || fail 'job run by the unit runner was not consumed'

# A unit over its adapter limit is stopped, independent of GitHub visibility.
clear_fixtures
add_job_state qa2 qniapp/qa2 1007 qa2-runner-job@1007.service "$((BASE_NOW - 5401))" 5400
run_dispatcher
assert_contains "$(<"$FAKE_STOP_LOG")" 'qa2-runner-job@1007.service'

# Startup resync adopts an active configured unit whose state file was lost.
clear_fixtures
printf '%s\n' 'qoral-runner-job@1011.service' > "$FAKE_SYSTEMCTL_ACTIVE"
journal_minted qoral-runner-job@1011.service 66 qoral-kvm-20260101T000000Z-77
printf '{"runners":[{"id":66,"name":"qoral-kvm-20260101T000000Z-77","status":"online","busy":true}]}\n' > "$FAKE_GITHUB_DIR/qorraq_qoral.runners.json"
run_dispatcher
jq -e '.in_flight | any(.[]; .job_id == "1011" and .unit == "qoral-runner-job@1011.service")' "$TMP_DIR/status/status.json" >/dev/null || fail 'startup resync did not adopt the active unit'
[[ $(jq -r '.phase' "$TMP_DIR/state/jobs/1011/state.json") == RUNNING ]] || fail 'adopted unit has the wrong phase'

# Startup resync removes only offline, idle, prefix-matching registrations that no
# active job unit journal references.
clear_fixtures
set_runs qniapp_qa2 in_progress '[{"id":107}]'
set_jobs qniapp_qa2 107 '[{"id":1013,"status":"in_progress","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]}]'
printf '%s\n' 'qa2-runner-job@1013.service' > "$FAKE_SYSTEMCTL_ACTIVE"
journal_minted qa2-runner-job@1013.service 90 qa2-kvm-20260101T000000Z-7
orphan_runners='{"runners":[
  {"id":88,"name":"qa2-kvm-20251231T230000Z-1","status":"offline","busy":false},
  {"id":89,"name":"unrelated-1008","status":"offline","busy":false},
  {"id":90,"name":"qa2-kvm-20260101T000000Z-7","status":"offline","busy":false},
  {"id":91,"name":"qa2-kvm-20251231T230000Z-2","status":"online","busy":false},
  {"id":92,"name":"qa2-kvm-20251231T230000Z-3","status":"offline","busy":true}]}'
printf '%s\n' "$orphan_runners" > "$FAKE_GITHUB_DIR/qniapp_qa2.runners.json"
run_dispatcher
assert_contains "$(<"$FAKE_ARGV_LOG")" '/repos/qniapp/qa2/actions/runners/88'
[[ $(grep -c -- '--request DELETE' "$FAKE_ARGV_LOG") -eq 1 ]] || fail 'resync deleted a referenced, live, or non-matching runner or missed its orphan'

# An active unit whose registration cannot be identified yet suspends orphan cleanup.
clear_fixtures
set_runs qniapp_qa2 in_progress '[{"id":107}]'
set_jobs qniapp_qa2 107 '[{"id":1013,"status":"in_progress","created_at":"2026-01-01T00:00:01Z","labels":["qa2-kvm"]}]'
printf '%s\n' 'qa2-runner-job@1013.service' > "$FAKE_SYSTEMCTL_ACTIVE"
printf '%s\n' "$orphan_runners" > "$FAKE_GITHUB_DIR/qniapp_qa2.runners.json"
run_dispatcher
! grep -Fq -- '--request DELETE' "$FAKE_ARGV_LOG" || fail 'orphan cleanup ran while an active unit had an unidentified registration'
assert_contains "$(<"$TMP_DIR/output.log")" 'event=orphan-sweep-skipped unit=qa2-runner-job@1013.service reason=runner-unidentified'

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
[[ $(stat -c %a "$TMP_DIR/state/jobs/1009/github-token") == 640 ]] || fail 'refreshed job token lost its 0640 mode'
[[ $(fake_group_of "$TMP_DIR/state/jobs/1009/github-token") == qa2-runner-host ]] || fail 'refreshed job token lost its adapter job group'
[[ -z $(find "$TMP_DIR/state/jobs/1009" -name '.github-token.*') ]] || fail 'token refresh left a temporary file'

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
kvd_poll_all > "$TMP_DIR/output.log"
[[ ${KVD_POLL_FAILURES[qa2]} -eq 1 ]] || fail 'adapter was polled before its first backoff expired'
assert_contains "$(<"$TMP_DIR/output.log")" 'event=poll-error repo=qniapp/qa2 skipped=true retry_in=1s'
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
for unit in qa2-runner-job@123.service qoral-runner-job@a-1.service; do
    [[ $unit =~ $pattern ]] || fail "polkit regex rejected $unit"
done
for unit in qa2-runner@123.service qoral-runner-job@ABC.service qa2-runner-job@123.service.service qa2-agent-loop-runner-job@0.service; do
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

# Each job template keeps the repository's isolation drop-in, whose shared
# RuntimeDirectory the shipped 20-job-runtime.conf must replace, not extend.
effective_service_values() {
    local key=$1 unit_file=$2 dropin_dir=$3 instance=$4 file line value
    local -a values=()
    for file in "$unit_file" "$dropin_dir"/*.conf; do
        while IFS= read -r line; do
            [[ $line == "$key="* ]] || continue
            value=${line#"$key="}
            if [[ -z $value ]]; then
                values=()
            else
                read -r -a parts <<< "$value"
                values+=("${parts[@]}")
            fi
        done < "$file"
    done
    printf '%s\n' "${values[@]//%i/$instance}"
}
for template in qa2 qoral; do
    unit_dir="$VERIFY_ROOT/etc/systemd/system"
    dropin_dir="$unit_dir/$template-runner-job@.service.d"
    mkdir -p "$dropin_dir"
    printf '#!/bin/sh\n' > "$VERIFY_ROOT/opt/$template-job.sh"
    chmod +x "$VERIFY_ROOT/opt/$template-job.sh"
    printf '[Service]\nType=exec\nRestart=no\nExecStart=/opt/%s-job.sh\n' "$template" > "$unit_dir/$template-runner-job@.service"
    printf '[Service]\nRuntimeDirectory=%s-runner\nRuntimeDirectoryMode=0700\n' "$template" > "$dropin_dir/10-isolation.conf"
    cp "$ROOT_DIR/host/systemd/examples/$template-runner-job@.service.d/20-job-runtime.conf" "$dropin_dir/20-job-runtime.conf"
    systemd-analyze verify --root="$VERIFY_ROOT" "$template-runner-job@1001.service"
    [[ $(effective_service_values RuntimeDirectory "$unit_dir/$template-runner-job@.service" "$dropin_dir" 1001) == "$template-runner-job-1001" ]] ||
        fail "$template job template does not get exactly one per-job RuntimeDirectory"
    [[ $(effective_service_values RuntimeDirectoryMode "$unit_dir/$template-runner-job@.service" "$dropin_dir" 1001 | tail -n 1) == 0700 ]] ||
        fail "$template job RuntimeDirectoryMode is not 0700"
done

bash -n "$ROOT_DIR/host/kvm_dispatcher.sh" "$ROOT_DIR/host/kvm_dispatcher_lib.sh" "$ROOT_DIR/host/kvm_dispatcher_host_wizard.sh"
shellcheck -x "$ROOT_DIR/host/kvm_dispatcher.sh" "$ROOT_DIR/host/kvm_dispatcher_lib.sh" "$ROOT_DIR/host/kvm_dispatcher_host_wizard.sh" "$ROOT_DIR/host/kvm_dispatcher_host_test.sh"
printf 'PASS: dispatcher host tests\n'
