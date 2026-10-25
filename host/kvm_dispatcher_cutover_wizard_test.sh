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
assert_contains() {
    local haystack=$1 needle=$2
    [[ $haystack == *"$needle"* ]] || fail "expected output to contain: $needle"
}

TEST_BIN="$TMP_DIR/bin"
TEST_ROOT="$TMP_DIR/host"
QA2_SOURCE="$TMP_DIR/qa2"
QORAL_SOURCE="$TMP_DIR/qoral"
mkdir -p "$TEST_BIN" "$TEST_ROOT/etc/kvm-dispatcher/repos.d" \
    "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/etc/polkit-1/rules.d" \
    "$TEST_ROOT/var/lib/kvm-dispatcher" "$QA2_SOURCE/Tools/KvmRunner/host/systemd" \
    "$QA2_SOURCE/Tools/KvmRunner/host/dispatcher" "$QORAL_SOURCE/tools/kvm-runner/host/systemd" \
    "$QORAL_SOURCE/tools/kvm-runner/host/dispatcher"

cat > "$TEST_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
command_name=${1:-}
shift || true
update_state() {
    local state_file=$1 unit=$2 operation=$3 temporary
    if [[ $operation == add ]]; then
        grep -Fxq -- "$unit" "$state_file" || printf '%s\n' "$unit" >> "$state_file"
    else
        temporary="$state_file.tmp"
        grep -Fxv -- "$unit" "$state_file" > "$temporary" || true
        mv -- "$temporary" "$state_file"
    fi
}
case $command_name in
    is-active|is-enabled)
        [[ ${1:-} == --quiet ]] && shift
        case $command_name in
            is-active) state_file=$FAKE_ACTIVE_UNITS; expected=active; fallback=inactive ;;
            is-enabled) state_file=$FAKE_ENABLED_UNITS; expected=enabled; fallback=disabled ;;
        esac
        if grep -Fxq -- "${1:-}" "$state_file"; then
            printf '%s\n' "$expected"
        elif [[ $command_name == is-active ]] && grep -Fxq -- "${1:-}" "$FAKE_FAILED_UNITS"; then
            printf 'failed\n'
            exit 1
        else
            case ${1:-} in
                kvm-dispatcher.service|qa2-runner.service|qoral-runner.service) printf '%s\n' "$fallback" ;;
                *) printf '%s\n' not-found; exit 1 ;;
            esac
            exit 1
        fi
        ;;
    show)
        unit=${!#}
        properties=()
        value_only=0
        for arg in "$@"; do
            case $arg in
                --property=*) properties+=("${arg#--property=}") ;;
                --value) value_only=1 ;;
            esac
        done
        printf '%s\n' "$unit" >> "$FAKE_SYSTEMCTL_SHOW_LOG"
        if [[ $unit == *@.service ]]; then
            printf 'Unit name %s is neither a valid invocation ID nor unit name.\n' "$unit" >&2
            exit 1
        fi
        for property in "${properties[@]}"; do
            case $property in
                ActiveEnterTimestamp)
                    [[ $unit == qa2-runner.service ]] || continue
                    value='Sun 2026-10-25 04:00:00 UTC'
                    ;;
                Restart)
                    [[ $unit == *@*.service ]] || continue
                    value=no
                    ;;
                MemoryAccounting)
                    [[ $unit == *@*.service ]] || continue
                    value=yes
                    ;;
                LoadCredential)
                    [[ $unit == *@*.service ]] || continue
                    value='[unprintable]'
                    ;;
                Result)
                    if grep -Fxq -- "$unit" "$FAKE_FAILED_UNITS"; then value=exit-code; else value=success; fi
                    ;;
                ExecMainStatus)
                    if grep -Fxq -- "$unit" "$FAKE_FAILED_UNITS"; then value=143; else value=0; fi
                    ;;
                *) continue ;;
            esac
            if (( value_only == 1 )); then
                printf '%s\n' "$value"
            else
                printf '%s=%s\n' "$property" "$value"
            fi
        done
        ;;
    daemon-reload)
        printf '%s\n' "$command_name" >> "$FAKE_MUTATION_LOG"
        ;;
    reset-failed)
        unit=${1:-}
        printf '%s %s\n' "$command_name" "$unit" >> "$FAKE_MUTATION_LOG"
        update_state "$FAKE_FAILED_UNITS" "$unit" remove
        ;;
    stop|disable|enable|start|restart)
        unit=${1:-}
        printf '%s %s\n' "$command_name" "$unit" >> "$FAKE_MUTATION_LOG"
        case $command_name in
            stop)
                update_state "$FAKE_ACTIVE_UNITS" "$unit" remove
                if grep -Fxq -- "$unit" "$FAKE_STOP_FAILED_UNITS"; then
                    update_state "$FAKE_FAILED_UNITS" "$unit" add
                else
                    update_state "$FAKE_FAILED_UNITS" "$unit" remove
                fi
                ;;
            start|restart)
                update_state "$FAKE_ACTIVE_UNITS" "$unit" add
                update_state "$FAKE_FAILED_UNITS" "$unit" remove
                ;;
        esac
        case $command_name in
            disable) update_state "$FAKE_ENABLED_UNITS" "$unit" remove ;;
            enable) update_state "$FAKE_ENABLED_UNITS" "$unit" add ;;
        esac
        if [[ $command_name == start && $unit == kvm-dispatcher.service ]]; then
            now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            printf '{"updated_at":"%s","in_flight":[],"queued":[],"last_poll":{"qniapp/qa2":{"http":"200","at":"%s"}},"recent":[]}\n' "$now" "$now" > "$FAKE_STATUS_FILE"
        fi
        ;;
    list-units)
        pattern=${!#}
        while IFS= read -r unit; do
            if [[ -n $unit && $unit == $pattern ]]; then
                printf '%s loaded active running test\n' "$unit"
            fi
        done < "$FAKE_ACTIVE_UNITS"
        ;;
    cat)
        case ${1:-} in
            qa2-runner-job@.service)
                /usr/bin/cat "$FAKE_TEST_ROOT/etc/systemd/system/qa2-runner-job@.service"
                ;;
            qoral-runner-job@.service)
                /usr/bin/cat "$FAKE_TEST_ROOT/etc/systemd/system/qoral-runner-job@.service"
                ;;
            *) printf '%s\n' '[Unit]' 'Description=Fake unit' ;;
        esac
        ;;
    *)
        printf '%s %s\n' "$command_name" "$*" >> "$FAKE_MUTATION_LOG"
        printf 'unexpected state-changing systemctl command in refusal test\n' >&2
        exit 99
        ;;
esac
FAKE_SYSTEMCTL

cat > "$TEST_BIN/journalctl" <<'FAKE_JOURNALCTL'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
unit=
previous=
for arg in "$@"; do
    if [[ $previous == --unit || $previous == -u ]]; then unit=$arg; fi
    case $arg in
        --unit=*) unit=${arg#--unit=} ;;
    esac
    previous=$arg
done
case $unit in
    qa2-runner.service) fixture=$FAKE_QA2_JOURNAL ;;
    kvm-dispatcher.service) fixture=$FAKE_DISPATCHER_JOURNAL ;;
    *) printf 'unexpected journal unit: %s\n' "$unit" >&2; exit 2 ;;
esac
[[ -r $fixture ]] && /usr/bin/cat "$fixture"
FAKE_JOURNALCTL

cat > "$TEST_BIN/getent" <<'FAKE_GETENT'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
if [[ ${1:-} == group ]]; then
    case ${2:-} in
        kvm-dispatcher) printf 'kvm-dispatcher:x:948:\n'; exit 0 ;;
        qa2-runner-host) printf 'qa2-runner-host:x:943:kvm-dispatcher\n'; exit 0 ;;
        qoral-runner-host) printf 'qoral-runner-host:x:939:kvm-dispatcher\n'; exit 0 ;;
    esac
fi
exit 2
FAKE_GETENT

cat > "$TEST_BIN/id" <<'FAKE_ID'
#!/usr/bin/env bash
[[ $# -eq 2 && $1 == -nG && $2 == kvm-dispatcher ]] || exit 2
printf '%s\n' 'kvm-dispatcher qa2-runner-host qoral-runner-host'
FAKE_ID
chmod +x "$TEST_BIN/systemctl" "$TEST_BIN/journalctl" "$TEST_BIN/getent" "$TEST_BIN/id"

cat > "$QA2_SOURCE/Tools/KvmRunner/host/systemd/qa2-runner-job@.service" <<'QA2_UNIT'
[Service]
Type=exec
Restart=no
MemoryAccounting=yes
LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token
ExecStart=/opt/qa2-runner/qa2_runner_job.sh
QA2_UNIT
cat > "$QA2_SOURCE/Tools/KvmRunner/host/systemd/qa2-runner-isolation.conf" <<'QA2_ISOLATION'
[Service]
User=qa2-runner-host
Group=qa2-runner-host
QA2_ISOLATION
printf '#!/usr/bin/env bash\n' > "$QA2_SOURCE/Tools/KvmRunner/host/qa2_runner_job.sh"
printf '# QA2 runner library\n' > "$QA2_SOURCE/Tools/KvmRunner/host/qa2_runner_lib.sh"
printf '#!/usr/bin/env bash\n' > "$QA2_SOURCE/Tools/KvmRunner/host/qa2_runner_isolation_check.sh"

cat > "$QORAL_SOURCE/tools/kvm-runner/host/systemd/qoral-runner-job@.service" <<'QORAL_UNIT'
[Service]
Type=exec
LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token
Environment=QORAL_RUNNER_GITHUB_TOKEN_FILE=/run/kvm-dispatcher/jobs/%i/github-token
ExecStart=/usr/bin/flock --exclusive /run/lock/qoral-qa2-kvm.lock /opt/qoral-runner/qoral_runner_job.sh
QORAL_UNIT
cat > "$QORAL_SOURCE/tools/kvm-runner/host/systemd/qoral-runner-job-isolation.conf" <<'QORAL_ISOLATION'
[Service]
User=qoral-runner-host
Group=qoral-runner-host
QORAL_ISOLATION
printf '#!/usr/bin/env bash\n' > "$QORAL_SOURCE/tools/kvm-runner/host/qoral_runner_job.sh"
printf '#!/usr/bin/env bash\n' > "$QORAL_SOURCE/tools/kvm-runner/host/qoral_runner_isolation_check.sh"
cat > "$QORAL_SOURCE/tools/kvm-runner/host/qoral_runner_lib.sh" <<'QORAL_LIBRARY'
local f="${QORAL_RUNNER_GITHUB_TOKEN_FILE:-}"
QORAL_LIBRARY

for source_root in "$QA2_SOURCE" "$QORAL_SOURCE"; do
    git -C "$source_root" init -q
    git -C "$source_root" add .
    git -C "$source_root" -c user.name='Cutover test' -c user.email='cutover@example.invalid' commit -qm 'Add test source files'
done

mkdir -p "$TEST_ROOT/opt/qa2-runner" "$TEST_ROOT/opt/qoral-runner" "$TEST_ROOT/opt/kvm-dispatcher/host"
cp "$QA2_SOURCE/Tools/KvmRunner/host/qa2_runner_job.sh" "$TEST_ROOT/opt/qa2-runner/qa2_runner_job.sh"
cp "$QA2_SOURCE/Tools/KvmRunner/host/qa2_runner_lib.sh" "$TEST_ROOT/opt/qa2-runner/qa2_runner_lib.sh"
cp "$QA2_SOURCE/Tools/KvmRunner/host/qa2_runner_isolation_check.sh" "$TEST_ROOT/opt/qa2-runner/qa2_runner_isolation_check.sh"
cp "$QORAL_SOURCE/tools/kvm-runner/host/qoral_runner_job.sh" "$TEST_ROOT/opt/qoral-runner/qoral_runner_job.sh"
cp "$QORAL_SOURCE/tools/kvm-runner/host/qoral_runner_lib.sh" "$TEST_ROOT/opt/qoral-runner/qoral_runner_lib.sh"
cp "$QORAL_SOURCE/tools/kvm-runner/host/qoral_runner_isolation_check.sh" "$TEST_ROOT/opt/qoral-runner/qoral_runner_isolation_check.sh"
chmod +x "$TEST_ROOT/opt/qa2-runner/qa2_runner_job.sh" "$TEST_ROOT/opt/qa2-runner/qa2_runner_isolation_check.sh" \
    "$TEST_ROOT/opt/qoral-runner/qoral_runner_job.sh" "$TEST_ROOT/opt/qoral-runner/qoral_runner_isolation_check.sh"
cp "$ROOT_DIR/host/kvm_dispatcher.sh" "$TEST_ROOT/opt/kvm-dispatcher/host/kvm_dispatcher.sh"
cp "$ROOT_DIR/host/kvm_dispatcher_lib.sh" "$TEST_ROOT/opt/kvm-dispatcher/host/kvm_dispatcher_lib.sh"
chmod 755 "$TEST_ROOT/opt/kvm-dispatcher/host/kvm_dispatcher.sh"
cp "$ROOT_DIR/host/systemd/kvm-dispatcher.service" "$TEST_ROOT/etc/systemd/system/kvm-dispatcher.service"
cp "$ROOT_DIR/host/polkit/50-kvm-dispatcher.rules" "$TEST_ROOT/etc/polkit-1/rules.d/50-kvm-dispatcher.rules"
printf '%s\n' 'test dispatcher config' > "$TEST_ROOT/etc/kvm-dispatcher/dispatcher.conf"
touch "$TEST_ROOT/etc/kvm-dispatcher/app-key.cred"
printf '%s\n' 'test legacy unit' > "$TEST_ROOT/etc/systemd/system/qa2-runner.service"
printf '%s\n' 'test legacy unit' > "$TEST_ROOT/etc/systemd/system/qoral-runner.service"
printf '%s\n' '{"updated_at":"2026-10-25T04:00:00Z","in_flight":[],"queued":[],"last_poll":{},"recent":[]}' > "$TEST_ROOT/var/lib/kvm-dispatcher/status.json"

export PATH="$TEST_BIN:$PATH"
export KVM_DISPATCHER_CUTOVER_TEST_ROOT="$TEST_ROOT"
export KVM_DISPATCHER_CUTOVER_TESTING=1
export KVM_DISPATCHER_CUTOVER_QA2_SOURCE="$QA2_SOURCE"
export KVM_DISPATCHER_CUTOVER_QORAL_SOURCE="$QORAL_SOURCE"
export FAKE_ACTIVE_UNITS="$TMP_DIR/active-units"
export FAKE_ENABLED_UNITS="$TMP_DIR/enabled-units"
export FAKE_FAILED_UNITS="$TMP_DIR/failed-units"
export FAKE_STOP_FAILED_UNITS="$TMP_DIR/stop-failed-units"
export FAKE_CONFIRMATION_LOG="$TMP_DIR/confirmations.log"
export FAKE_QA2_JOURNAL="$TMP_DIR/qa2-journal.log"
export FAKE_DISPATCHER_JOURNAL="$TMP_DIR/dispatcher-journal.log"
export FAKE_MUTATION_LOG="$TMP_DIR/mutations.log"
export FAKE_STATUS_FILE="$TEST_ROOT/var/lib/kvm-dispatcher/status.json"
export FAKE_SYSTEMCTL_SHOW_LOG="$TMP_DIR/systemctl-show.log"
export FAKE_TEST_ROOT="$TEST_ROOT"
: > "$FAKE_ACTIVE_UNITS"
: > "$FAKE_ENABLED_UNITS"
: > "$FAKE_FAILED_UNITS"
: > "$FAKE_STOP_FAILED_UNITS"
: > "$FAKE_CONFIRMATION_LOG"
: > "$FAKE_DISPATCHER_JOURNAL"
: > "$FAKE_MUTATION_LOG"
: > "$FAKE_SYSTEMCTL_SHOW_LOG"

WIZARD="$ROOT_DIR/host/kvm_dispatcher_cutover_wizard.sh"
[[ $(command -v systemctl) == "$TEST_BIN/systemctl" ]] || fail 'the cutover test must use its fake systemctl'
run_wizard() {
    (cd "$ROOT_DIR" && "$WIZARD" "$@") > "$TMP_DIR/wizard.out" 2>&1
}
run_sourced_wizard() {
    local action=$1 target=$2
    (
        # shellcheck source=host/kvm_dispatcher_cutover_wizard.sh
        source "$ROOT_DIR/host/kvm_dispatcher_cutover_wizard.sh"
        export TEST_MODE=1
        export INSTALL_ROOT=$TEST_ROOT
        # shellcheck disable=SC2329
        confirm_action() { printf '%s\n' "$1" >> "$FAKE_CONFIRMATION_LOG"; return 0; }
        # shellcheck disable=SC2329
        confirm_idle() { return 0; }
        # shellcheck disable=SC2329
        confirm_legacy_ready() { return 0; }
        # shellcheck disable=SC2329
        place_file() {
            local source=$1 destination=$2 mode=$3
            install -D --mode="$mode" -- "$source" "$destination"
        }
        # shellcheck disable=SC2329
        systemctl_cmd() { command systemctl "$@"; }
        case $action in
            template) load_target "$target"; verify_template_properties ;;
            stage) qa2_stage ;;
            rollback) load_target "$target"; rollback_stage ;;
            *) exit 2 ;;
        esac
    )
}

printf '%s\n' qa2-runner.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_ENABLED_UNITS"
printf '%s\n' \
    'job=1001 event=runner-online after=12s' \
    'job=1001 event=runner-busy after=35s' > "$FAKE_QA2_JOURNAL"
if run_wizard --stage qa2; then
    fail 'QA2 cutover accepted a runner journal with event=runner-busy'
fi
assert_contains "$(<"$TMP_DIR/wizard.out")" 'QA2 runnerの現在の起動後にbusy eventがあります'
[[ ! -s $FAKE_MUTATION_LOG ]] || fail 'QA2 busy refusal issued a state-changing command'
[[ ! -e $TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf ]] || fail 'QA2 busy refusal installed an adapter'
[[ ! -e $TEST_ROOT/etc/systemd/system/qa2-runner-job@.service ]] || fail 'QA2 busy refusal installed a template'
[[ ! -e $TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d/10-isolation.conf ]] || fail 'QA2 busy refusal installed an isolation drop-in'
[[ ! -e $TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d/20-job-runtime.conf ]] || fail 'QA2 busy refusal installed a runtime drop-in'

printf '%s\n' kvm-dispatcher.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' kvm-dispatcher.service > "$FAKE_ENABLED_UNITS"
: > "$FAKE_QA2_JOURNAL"
: > "$FAKE_DISPATCHER_JOURNAL"
cp "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
chmod 640 "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"updated_at":"%s","in_flight":[],"queued":[],"last_poll":{"qniapp/qa2":{"http":"200","at":"%s"}},"recent":[]}\n' \
    "$NOW" "$NOW" > "$TEST_ROOT/var/lib/kvm-dispatcher/status.json"
if run_wizard --stage qoral; then
    fail 'Qoral stage accepted a QA2 poll without a successful dispatched QA2 job'
fi
assert_contains "$(<"$TMP_DIR/wizard.out")" 'QA2 の成功実績がありません'
[[ ! -s $FAKE_MUTATION_LOG ]] || fail 'Qoral prerequisite refusal issued a state-changing command'
[[ ! -e $TEST_ROOT/etc/kvm-dispatcher/repos.d/qoral.conf ]] || fail 'Qoral refusal installed an adapter'
[[ ! -e $TEST_ROOT/etc/systemd/system/qoral-runner-job@.service ]] || fail 'Qoral refusal installed a template'
[[ ! -e $TEST_ROOT/etc/systemd/system/qoral-runner-job@.service.d/10-isolation.conf ]] || fail 'Qoral refusal installed an isolation drop-in'
[[ ! -e $TEST_ROOT/etc/systemd/system/qoral-runner-job@.service.d/20-job-runtime.conf ]] || fail 'Qoral refusal installed a runtime drop-in'

cp "$ROOT_DIR/host/repos.d/qoral.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qoral.conf"
chmod 640 "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qoral.conf"
if run_wizard --rollback qa2; then
    fail 'QA2 rollback accepted an installed Qoral adapter'
fi
assert_contains "$(<"$TMP_DIR/wizard.out")" '先にQoral rollbackを完了してください'
[[ ! -s $FAKE_MUTATION_LOG ]] || fail 'QA2 rollback refusal issued a state-changing command'
rm -f "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qoral.conf"

cp "$QORAL_SOURCE/tools/kvm-runner/host/systemd/qoral-runner-job@.service" "$TMP_DIR/qoral-template"
rm -f "$QORAL_SOURCE/tools/kvm-runner/host/systemd/qoral-runner-job@.service"
git -C "$QORAL_SOURCE" add -A
git -C "$QORAL_SOURCE" -c user.name='Cutover test' -c user.email='cutover@example.invalid' commit --amend -qm 'Remove test Qoral template'
if run_wizard --stage qoral; then
    fail 'Qoral stage accepted a source checkout without its runner template'
fi
assert_contains "$(<"$TMP_DIR/wizard.out")" 'Qoral の runner template が見つかりません'
[[ ! -s $FAKE_MUTATION_LOG ]] || fail 'Missing-template refusal issued a state-changing command'
[[ ! -e $TEST_ROOT/etc/kvm-dispatcher/repos.d/qoral.conf ]] || fail 'Missing-template refusal installed an adapter'
[[ ! -e $TEST_ROOT/etc/systemd/system/qoral-runner-job@.service.d/10-isolation.conf ]] || fail 'Missing-template refusal installed an isolation drop-in'
[[ ! -e $TEST_ROOT/etc/systemd/system/qoral-runner-job@.service.d/20-job-runtime.conf ]] || fail 'Missing-template refusal installed a runtime drop-in'

REGRESSION_FAILURES=0
record_regression_failure() {
    printf 'FAIL: %s\n' "$*" >&2
    REGRESSION_FAILURES=$((REGRESSION_FAILURES + 1))
}
mkdir -p "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d"
cp "$QA2_SOURCE/Tools/KvmRunner/host/systemd/qa2-runner-job@.service" \
    "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service"
cp "$QA2_SOURCE/Tools/KvmRunner/host/systemd/qa2-runner-isolation.conf" \
    "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d/10-isolation.conf"
cp "$ROOT_DIR/host/systemd/examples/qa2-runner-job@.service.d/20-job-runtime.conf" \
    "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d/20-job-runtime.conf"
cp "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
chmod 644 "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service" \
    "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d/10-isolation.conf" \
    "$TEST_ROOT/etc/systemd/system/qa2-runner-job@.service.d/20-job-runtime.conf"
chmod 640 "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
mkdir -p "$TEST_ROOT/etc/systemd/system"
cp "$TMP_DIR/qoral-template" "$TEST_ROOT/etc/systemd/system/qoral-runner-job@.service"
chmod 644 "$TEST_ROOT/etc/systemd/system/qoral-runner-job@.service"
for target in qa2 qoral; do
    if output=$(run_sourced_wizard template "$target" 2>&1); then
        printf 'PASS: %s template properties use a valid instance\n' "$target"
    else
        record_regression_failure "$target template properties query failed: $output"
    fi
done
rm -f -- "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
printf '%s\n' qa2-runner.service > "$FAKE_FAILED_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_ENABLED_UNITS"
: > "$FAKE_ACTIVE_UNITS"
: > "$FAKE_MUTATION_LOG"
: > "$FAKE_CONFIRMATION_LOG"
if output=$(run_sourced_wizard stage qa2 2>&1); then
    record_regression_failure 'QA2 stage accepted a legacy service that was already failed before stop'
else
    assert_contains "$output" 'active=failed'
    grep -Fxq qa2-runner.service "$FAKE_FAILED_UNITS" || record_regression_failure 'pre-stop failed QA2 unit was cleared'
    grep -Fq 'reset-failed qa2-runner.service' "$FAKE_MUTATION_LOG" && record_regression_failure 'pre-stop failed QA2 unit was reset'
    [[ ! -s $FAKE_MUTATION_LOG ]] || record_regression_failure 'pre-stop failed QA2 refusal changed systemd state'
fi

: > "$FAKE_FAILED_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_STOP_FAILED_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_ENABLED_UNITS"
printf '%s\n' 'job=1001 event=runner-online after=12s' > "$FAKE_QA2_JOURNAL"
: > "$FAKE_MUTATION_LOG"
: > "$FAKE_CONFIRMATION_LOG"
if output=$(run_sourced_wizard stage qa2 2>&1); then
    assert_contains "$output" '同じfileがあるため配置を省略します'
    assert_contains "$output" 'Result=exit-code'
    assert_contains "$output" 'ExecMainStatus=143'
    assert_contains "$output" '停止後にsystemdがfailedを報告しました'
    assert_contains "$output" 'QA2 stageが完了しました'
    grep -Fq 'reset-failed qa2-runner.service' "$FAKE_CONFIRMATION_LOG" || record_regression_failure 'QA2 reset-failed was not confirmed'
    grep -Fxq 'reset-failed qa2-runner.service' "$FAKE_MUTATION_LOG" || record_regression_failure 'QA2 failed state was not reset'
    grep -Fxq kvm-dispatcher.service "$FAKE_ACTIVE_UNITS" || record_regression_failure 'QA2 rerun did not start the dispatcher'
    grep -Fxq kvm-dispatcher.service "$FAKE_ENABLED_UNITS" || record_regression_failure 'QA2 rerun did not enable the dispatcher'
    grep -Fxq qa2-runner.service "$FAKE_ACTIVE_UNITS" && record_regression_failure 'QA2 rerun left the legacy service active'
    grep -Fxq qa2-runner.service "$FAKE_ENABLED_UNITS" && record_regression_failure 'QA2 rerun left the legacy service enabled'
    grep -Fxq qa2-runner.service "$FAKE_FAILED_UNITS" && record_regression_failure 'QA2 rerun left the legacy service failed'
    [[ -f $TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf && ! -L $TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf ]] || record_regression_failure 'QA2 rerun did not reinstall the missing adapter'
    cmp -s "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf" || record_regression_failure 'QA2 rerun installed the wrong adapter contents'
else
    record_regression_failure "QA2 stage did not resume from installed templates and a missing adapter: $output"
fi

cp "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
chmod 640 "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
printf '%s\n' qa2-runner.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_ENABLED_UNITS"
: > "$FAKE_MUTATION_LOG"
if output=$(run_sourced_wizard rollback qa2 2>&1); then
    assert_contains "$output" 'rollbackが完了しました'
    [[ ! -e $TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf ]] || record_regression_failure 'safe QA2 rollback kept the adapter'
    grep -Fxq qa2-runner.service "$FAKE_ACTIVE_UNITS" || record_regression_failure 'safe QA2 rollback stopped the legacy service'
    grep -Fxq qa2-runner.service "$FAKE_ENABLED_UNITS" || record_regression_failure 'safe QA2 rollback disabled the legacy service'
    [[ ! -s $FAKE_MUTATION_LOG ]] || record_regression_failure 'safe QA2 rollback changed systemd state'
else
    record_regression_failure "safe QA2 rollback refused the installed-adapter state: $output"
fi

cp "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
chmod 640 "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
printf '%s\n' kvm-dispatcher.service qa2-runner.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' kvm-dispatcher.service qa2-runner.service > "$FAKE_ENABLED_UNITS"
: > "$FAKE_MUTATION_LOG"
if output=$(run_sourced_wizard rollback qa2 2>&1); then
    record_regression_failure 'ambiguous rollback accepted active dispatcher and legacy services'
else
    assert_contains "$output" '状態を調査するまでrollbackしません'
    [[ -e $TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf ]] || record_regression_failure 'ambiguous rollback removed the adapter'
    grep -Fxq kvm-dispatcher.service "$FAKE_ACTIVE_UNITS" || record_regression_failure 'ambiguous rollback stopped the dispatcher'
    grep -Fxq qa2-runner.service "$FAKE_ACTIVE_UNITS" || record_regression_failure 'ambiguous rollback stopped the legacy service'
    [[ ! -s $FAKE_MUTATION_LOG ]] || record_regression_failure 'ambiguous rollback changed systemd state'
fi

cp "$ROOT_DIR/host/repos.d/qa2.conf.example" "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
chmod 640 "$TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf"
printf '%s\n' qa2-runner.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' qa2-runner.service > "$FAKE_ENABLED_UNITS"
printf '%s\n' kvm-dispatcher.service qa2-runner-job@1001.service qoral-runner-job@2002.service > "$FAKE_ACTIVE_UNITS"
printf '%s\n' kvm-dispatcher.service > "$FAKE_ENABLED_UNITS"
printf '%s\n' kvm-dispatcher.service qa2-runner-job@1001.service qoral-runner-job@2002.service > "$FAKE_STOP_FAILED_UNITS"
: > "$FAKE_FAILED_UNITS"
: > "$FAKE_MUTATION_LOG"
: > "$FAKE_CONFIRMATION_LOG"
if output=$(run_sourced_wizard rollback qa2 2>&1); then
    assert_contains "$output" 'rollbackが完了しました'
    for unit in kvm-dispatcher.service qa2-runner-job@1001.service qoral-runner-job@2002.service; do
        grep -Fq "reset-failed $unit" "$FAKE_CONFIRMATION_LOG" || record_regression_failure "$unit reset-failed was not confirmed during rollback"
        grep -Fxq "reset-failed $unit" "$FAKE_MUTATION_LOG" || record_regression_failure "$unit failed state was not reset during rollback"
    done
    [[ ! -s $FAKE_FAILED_UNITS ]] || record_regression_failure 'rollback left stopped units failed'
    [[ ! -e $TEST_ROOT/etc/kvm-dispatcher/repos.d/qa2.conf ]] || record_regression_failure 'rollback with failed stop results kept the adapter'
    grep -Fxq qa2-runner.service "$FAKE_ACTIVE_UNITS" || record_regression_failure 'rollback with failed stop results did not start the legacy service'
    grep -Fxq qa2-runner.service "$FAKE_ENABLED_UNITS" || record_regression_failure 'rollback with failed stop results did not enable the legacy service'
    grep -Fxq kvm-dispatcher.service "$FAKE_ACTIVE_UNITS" && record_regression_failure 'rollback left the dispatcher active'
    grep -Fxq kvm-dispatcher.service "$FAKE_ENABLED_UNITS" && record_regression_failure 'rollback left the dispatcher enabled'
else
    record_regression_failure "rollback did not recover from failed stop results: $output"
fi

(( REGRESSION_FAILURES == 0 )) || fail "$REGRESSION_FAILURES cutover regressions failed"
printf 'PASS: cutover wizard refusal and recovery guards\n'
