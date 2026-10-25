#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
CHECKOUT_ROOT=$(dirname -- "$SCRIPT_DIR")
INSTALL_ROOT=/
TEST_MODE=0
MODE=menu
SELECTED_TARGET=
SOURCE_ROOT=
SOURCE_HEAD=
DISPATCHER_HEAD=
CUTOVER_STATE=preflight
STAGE_STARTED_AT=

usage() {
    cat <<'USAGE'
使い方:
  sudo ./host/kvm_dispatcher_cutover_wizard.sh
  sudo ./host/kvm_dispatcher_cutover_wizard.sh --stage qa2|qoral
  sudo ./host/kvm_dispatcher_cutover_wizard.sh --rollback qa2|qoral

最初の実行ではQA2だけを切り替えます。QA2のジョブが配車係経由で成功した後、
別の機会に --stage qoral を実行してください。--rollback は対象リポジトリの
アダプターだけを外し、従来サービスを再開します。各変更の直前に確認します。
USAGE
}

fail() {
    printf '中止しました。%s\n' "$*" >&2
}

confirm_action() {
    local description=$1 answer
    if (( TEST_MODE == 1 )); then
        fail 'テスト用ルートでは状態を変更できません。'
        return 1
    fi
    printf '\n変更内容: %s\n' "$description" >/dev/tty
    printf 'この変更を実行しますか？ [y/N] ' >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
        printf '操作を取り消しました。\n' >/dev/tty
        return 1
    fi
    if [[ $answer != y && $answer != Y ]]; then
        printf '操作を取り消しました。\n' >/dev/tty
        return 1
    fi
}

confirm_idle() {
    local answer
    if (( TEST_MODE == 1 )); then
        fail 'テスト用ルートでは対話確認を省略できません。'
        return 1
    fi
    printf '\nGitHub Actions の QA2 runner が idle であることを画面で確認してください。\n' >/dev/tty
    printf 'idle であることを確認したら「確認済み」と入力してください。busy なら中止します。 ' >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
        printf '操作を取り消しました。\n' >/dev/tty
        return 1
    fi
    if [[ $answer != 確認済み ]]; then
        fail 'QA2 runner の idle を確認できませんでした。何も変更していません。'
        return 1
    fi
}

confirm_legacy_ready() {
    local answer
    if (( TEST_MODE == 1 )); then
        fail 'テスト用ルートでは対話確認を省略できません。'
        return 1
    fi
    printf '\n従来サービスの設定と資格情報が残っているか、または復元済みか確認してください。\n' >/dev/tty
    printf '資格情報の内容は表示しないでください。確認したら「復元済み」と入力してください。 ' >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
        printf '操作を取り消しました。\n' >/dev/tty
        return 1
    fi
    if [[ $answer != 復元済み ]]; then
        fail '従来サービスの準備を確認できませんでした。何も変更していません。'
        return 1
    fi
}

systemctl_cmd() {
    local command_name=${1:-}
    if (( TEST_MODE == 1 )); then
        case $command_name in
            is-active|is-enabled|show|list-units|cat) ;;
            *)
                fail 'テスト用ルートではsystemdを変更できません。'
                return 99
                ;;
        esac
    fi
    command systemctl "$@"
}

journalctl_cmd() {
    command journalctl "$@"
}

path_at_root() {
    local path=$1
    if [[ $INSTALL_ROOT == / ]]; then
        printf '%s' "$path"
    else
        printf '%s%s' "${INSTALL_ROOT%/}" "$path"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        fail "必要なコマンドがありません: $1"
        return 1
    }
}

check_dispatcher_checkout() {
    local checkout status
    if [[ $(pwd -P) != "$CHECKOUT_ROOT" ]]; then
        fail "kvm-dispatcher checkoutのrootから実行してください: $CHECKOUT_ROOT"
        return 1
    fi
    checkout=$(git -C "$CHECKOUT_ROOT" rev-parse --show-toplevel 2>/dev/null) || {
        fail 'kvm-dispatcherのGit checkoutを確認できません。'
        return 1
    }
    status=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 git -c "safe.directory=$CHECKOUT_ROOT" -c core.fsmonitor=false -C "$CHECKOUT_ROOT" status --porcelain --untracked-files=all 2>/dev/null) || {
        fail 'kvm-dispatcher checkoutの状態を確認できません。'
        return 1
    }
    if (( TEST_MODE == 1 )); then status=; fi
    if [[ $(readlink -f -- "$checkout") != "$CHECKOUT_ROOT" || -n $status ]]; then
        fail 'kvm-dispatcher checkoutがcleanではありません。変更をcommitしてから実行してください。'
        return 1
    fi
    DISPATCHER_HEAD=$(git -c "safe.directory=$CHECKOUT_ROOT" -C "$CHECKOUT_ROOT" rev-parse HEAD 2>/dev/null) || {
        fail 'kvm-dispatcher checkoutのHEADを確認できません。'
        return 1
    }
    printf 'kvm-dispatcher checkout: %s\nHEAD: %s\n' "$CHECKOUT_ROOT" "$DISPATCHER_HEAD"
}

load_target() {
    local target=$1
    case $target in
        qa2)
            REPO=qniapp/qa2
            DISPLAY_NAME=QA2
            ADAPTER=qa2
            UNIT_PREFIX=qa2-runner-job@
            LEGACY_UNIT=qa2-runner.service
            JOB_GROUP=qa2-runner-host
            TEMPLATE_REL=Tools/KvmRunner/host/systemd/qa2-runner-job@.service
            ISOLATION_REL=Tools/KvmRunner/host/systemd/qa2-runner-isolation.conf
            RUNNER_SCRIPT_REL=Tools/KvmRunner/host/qa2_runner_job.sh
            RUNNER_LIBRARY_REL=Tools/KvmRunner/host/qa2_runner_lib.sh
            RUNNER_ISOLATION_REL=Tools/KvmRunner/host/qa2_runner_isolation_check.sh
            RUNNER_SCRIPT=/opt/qa2-runner/qa2_runner_job.sh
            RUNNER_LIBRARY=/opt/qa2-runner/qa2_runner_lib.sh
            RUNNER_ISOLATION_SCRIPT=/opt/qa2-runner/qa2_runner_isolation_check.sh
            ;;
        qoral)
            REPO=qorraq/qoral
            DISPLAY_NAME=Qoral
            ADAPTER=qoral
            UNIT_PREFIX=qoral-runner-job@
            LEGACY_UNIT=qoral-runner.service
            JOB_GROUP=qoral-runner-host
            TEMPLATE_REL=tools/kvm-runner/host/systemd/qoral-runner-job@.service
            ISOLATION_REL=tools/kvm-runner/host/systemd/qoral-runner-job-isolation.conf
            RUNNER_SCRIPT_REL=tools/kvm-runner/host/qoral_runner_job.sh
            RUNNER_LIBRARY_REL=tools/kvm-runner/host/qoral_runner_lib.sh
            RUNNER_ISOLATION_REL=tools/kvm-runner/host/qoral_runner_isolation_check.sh
            RUNNER_SCRIPT=/opt/qoral-runner/qoral_runner_job.sh
            RUNNER_LIBRARY=/opt/qoral-runner/qoral_runner_lib.sh
            RUNNER_ISOLATION_SCRIPT=/opt/qoral-runner/qoral_runner_isolation_check.sh
            ;;
        *)
            fail "対象を判別できません: $target"
            return 2
            ;;
    esac
    TARGET=$target
    TEMPLATE_UNIT="$UNIT_PREFIX.service"
    TEMPLATE_SOURCE="$SOURCE_ROOT/$TEMPLATE_REL"
    ISOLATION_SOURCE="$SOURCE_ROOT/$ISOLATION_REL"
    RUNNER_SCRIPT_SOURCE="$SOURCE_ROOT/$RUNNER_SCRIPT_REL"
    RUNNER_LIBRARY_SOURCE="$SOURCE_ROOT/$RUNNER_LIBRARY_REL"
    RUNNER_ISOLATION_SOURCE="$SOURCE_ROOT/$RUNNER_ISOLATION_REL"
    TEMPLATE_DEST=$(path_at_root "/etc/systemd/system/$TEMPLATE_UNIT")
    DROPIN_DIR=$(path_at_root "/etc/systemd/system/$TEMPLATE_UNIT.d")
    ISOLATION_DEST="$DROPIN_DIR/10-isolation.conf"
    RUNTIME_SOURCE="$CHECKOUT_ROOT/host/systemd/examples/$TEMPLATE_UNIT.d/20-job-runtime.conf"
    RUNTIME_DEST="$DROPIN_DIR/20-job-runtime.conf"
    ADAPTER_SOURCE="$CHECKOUT_ROOT/host/repos.d/$ADAPTER.conf.example"
    ADAPTER_DEST=$(path_at_root "/etc/kvm-dispatcher/repos.d/$ADAPTER.conf")
    LEGACY_DEST=$(path_at_root "/etc/systemd/system/$LEGACY_UNIT")
}

resolve_source_root() {
    local target=$1 variable answer
    load_target "$target"
    case $target in
        qa2) variable=KVM_DISPATCHER_CUTOVER_QA2_SOURCE ;;
        qoral) variable=KVM_DISPATCHER_CUTOVER_QORAL_SOURCE ;;
    esac
    SOURCE_ROOT=${!variable:-}
    if [[ -z $SOURCE_ROOT ]]; then
        if (( TEST_MODE == 1 )); then
            fail "テスト用の $target source checkout が指定されていません。"
            return 1
        fi
        printf '\n%s のGit作業ツリーの絶対パスを入力してください。\n' "$REPO" >/dev/tty
        printf '作業ツリーのpath: ' >/dev/tty
        if ! IFS= read -r answer </dev/tty; then
            fail '作業ツリーのpathを読み取れませんでした。'
            return 1
        fi
        SOURCE_ROOT=$answer
    fi
    if [[ $SOURCE_ROOT != /* || ! -d $SOURCE_ROOT ]]; then
        fail "$REPO のcheckout directoryを確認できません: $SOURCE_ROOT"
        return 1
    fi
    SOURCE_ROOT=$(readlink -f -- "$SOURCE_ROOT") || {
        fail "$REPO のcheckout pathを解決できません。"
        return 1
    }
    SOURCE_ROOT=$(readlink -f -- "$SOURCE_ROOT")
    load_target "$target"
    local checkout
    checkout=$(git_read rev-parse --show-toplevel 2>/dev/null) || {
        fail "$REPO のcheckoutではありません。"
        return 1
    }
    if [[ $(readlink -f -- "$checkout") != "$SOURCE_ROOT" ]]; then
        fail 'Git checkoutのrootと入力したpathが一致しません。'
        return 1
    fi
    local status
    status=$(git_read status --porcelain --untracked-files=all 2>/dev/null) || {
        fail 'Git checkoutの状態を確認できません。'
        return 1
    }
    if [[ -n $status ]]; then
        fail "$REPO のcheckoutに未コミットの変更があります。"
        return 1
    fi
    SOURCE_HEAD=$(git_read rev-parse HEAD 2>/dev/null) || {
        fail 'source checkoutのHEADを確認できません。'
        return 1
    }
    printf '%s のcheckout: %s\nHEAD: %s\n' "$REPO" "$SOURCE_ROOT" "$SOURCE_HEAD"
}

git_read() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
        git -c "safe.directory=$SOURCE_ROOT" -c core.fsmonitor=false -C "$SOURCE_ROOT" "$@"
}

check_file() {
    local path=$1 description=$2
    if [[ ! -f $path || -L $path ]]; then
        fail "$description が見つかりません: $path"
        return 1
    fi
}

check_source_artifacts() {
    local adapter_name=$ADAPTER
    check_file "$TEMPLATE_SOURCE" "$DISPLAY_NAME の runner template" || return 1
    check_file "$ISOLATION_SOURCE" "$DISPLAY_NAME の 10-isolation.conf" || return 1
    check_file "$RUNNER_SCRIPT_SOURCE" "$DISPLAY_NAME の runner script" || return 1
    check_file "$RUNNER_LIBRARY_SOURCE" "$DISPLAY_NAME の runner library" || return 1
    check_file "$RUNNER_ISOLATION_SOURCE" "$DISPLAY_NAME の runner isolation check" || return 1
    check_file "$RUNTIME_SOURCE" '配車係の20-job-runtime.conf' || return 1
    check_file "$ADAPTER_SOURCE" "$adapter_name adapter example" || return 1
    if [[ ! -f $(path_at_root "$RUNNER_SCRIPT") || -L $(path_at_root "$RUNNER_SCRIPT") || ! -x $(path_at_root "$RUNNER_SCRIPT") ]]; then
        fail "hostにrunner scriptがありません。先に $REPO のrunnerを設置してください: $RUNNER_SCRIPT"
        return 1
    fi
    if [[ ! -f $(path_at_root "$RUNNER_LIBRARY") || -L $(path_at_root "$RUNNER_LIBRARY") ]]; then
        fail "hostにrunner libraryがありません。先に$REPOのrunnerを設置してください: $RUNNER_LIBRARY"
        return 1
    fi
    if [[ ! -f $(path_at_root "$RUNNER_ISOLATION_SCRIPT") || -L $(path_at_root "$RUNNER_ISOLATION_SCRIPT") || ! -x $(path_at_root "$RUNNER_ISOLATION_SCRIPT") ]]; then
        fail "hostにrunner isolation checkがありません。先に$REPOのrunnerを設置してください: $RUNNER_ISOLATION_SCRIPT"
        return 1
    fi
    if ! cmp -s -- "$RUNNER_SCRIPT_SOURCE" "$(path_at_root "$RUNNER_SCRIPT")" ||
        ! cmp -s -- "$RUNNER_LIBRARY_SOURCE" "$(path_at_root "$RUNNER_LIBRARY")" ||
        ! cmp -s -- "$RUNNER_ISOLATION_SOURCE" "$(path_at_root "$RUNNER_ISOLATION_SCRIPT")"; then
        fail "hostのrunner scriptまたはlibraryが選択した$REPO checkoutと一致しません。先に同じrevisionのrunnerを設置してください。"
        return 1
    fi
    if ! grep -Fq 'LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token' "$TEMPLATE_SOURCE"; then
        fail "$REPO のrunner templateに配車係のLoadCredential設定がありません。別のunitを作らず、対応するcheckoutを用意してください。"
        return 1
    fi
    if ! grep -Fq "$RUNNER_SCRIPT" "$TEMPLATE_SOURCE"; then
        fail "$REPO のrunner templateがhostに設置済みのrunner scriptを参照していません。"
        return 1
    fi
    if ! grep -Fxq "User=$JOB_GROUP" "$ISOLATION_SOURCE" || ! grep -Fxq "Group=$JOB_GROUP" "$ISOLATION_SOURCE"; then
        fail "$REPO の10-isolation.confに想定したjob userとgroupがありません。"
        return 1
    fi
    if ! grep -Fxq 'Restart=no' "$RUNTIME_SOURCE" || ! grep -Fxq 'MemoryAccounting=yes' "$RUNTIME_SOURCE"; then
        fail '20-job-runtime.confにRestart=noまたはMemoryAccounting=yesがありません。'
        return 1
    fi
    if [[ $TARGET == qoral ]]; then
        if ! grep -Fxq 'Environment=QORAL_RUNNER_GITHUB_TOKEN_FILE=/run/kvm-dispatcher/jobs/%i/github-token' "$TEMPLATE_SOURCE"; then
            fail 'Qoralのrunner templateにQORAL_RUNNER_GITHUB_TOKEN_FILEの配車係用設定がありません。対応するcheckoutを用意してください。'
            return 1
        fi
        if ! grep -Fq 'QORAL_RUNNER_GITHUB_TOKEN_FILE:-' "$RUNNER_LIBRARY_SOURCE" ||
            ! grep -Fq 'QORAL_RUNNER_GITHUB_TOKEN_FILE:-' "$(path_at_root "$RUNNER_LIBRARY")"; then
            fail 'Qoralのrunner libraryがQORAL_RUNNER_GITHUB_TOKEN_FILEのoverrideを扱いません。PATを作らず、対応するQoral checkoutを用意してください。'
            return 1
        fi
    fi
    if ! grep -Fxq "KVM_DISPATCHER_REPO=$REPO" "$ADAPTER_SOURCE" ||
        ! grep -Fxq "KVM_DISPATCHER_UNIT=$UNIT_PREFIX" "$ADAPTER_SOURCE" ||
        ! grep -Fxq "KVM_DISPATCHER_JOB_GROUP=$JOB_GROUP" "$ADAPTER_SOURCE"; then
        fail "$adapter_name.conf.exampleに必要なrepository、unit、job groupの設定がありません。"
        return 1
    fi
    printf '必要なtemplate、isolation/runtime drop-in、runner script/library/isolation check、adapter exampleを確認しました。\n'
}

metadata_matches() {
    local path=$1 mode=$2 owner_group=$3 actual_mode actual_owner_group
    actual_mode=$(stat -c '%a' -- "$path") || return 1
    (( 8#$actual_mode == 8#$mode )) || return 1
    if (( TEST_MODE == 0 )); then
        actual_owner_group=$(stat -c '%U:%G' -- "$path") || return 1
        [[ $actual_owner_group == "$owner_group" ]] || return 1
    fi
}

check_destination() {
    local source=$1 destination=$2 mode=$3 owner_group=$4 description=$5
    if [[ ! -e $destination && ! -L $destination ]]; then
        printf '配置先を確認しました: %s\n' "$description"
        return 0
    fi
    if [[ -L $destination || ! -f $destination ]]; then
        fail "配置先の種類が想定と異なります: $destination"
        return 1
    fi
    if ! cmp -s -- "$source" "$destination"; then
        fail "配置先に異なるfileがあります。上書きしません: $destination"
        return 1
    fi
    if ! metadata_matches "$destination" "$mode" "$owner_group"; then
        fail "配置済みfileのownerまたはmodeが想定と異なります。上書きしません: $destination"
        return 1
    fi
    printf '同じfileを確認しました: %s\n' "$destination"
}

check_host_core() {
    local dispatcher_unit dispatcher_script dispatcher_library policy_file repos_dir status_file credential_path
    dispatcher_unit=$(path_at_root /etc/systemd/system/kvm-dispatcher.service)
    dispatcher_script=$(path_at_root /opt/kvm-dispatcher/host/kvm_dispatcher.sh)
    dispatcher_library=$(path_at_root /opt/kvm-dispatcher/host/kvm_dispatcher_lib.sh)
    policy_file=$(path_at_root /etc/polkit-1/rules.d/50-kvm-dispatcher.rules)
    repos_dir=$(path_at_root /etc/kvm-dispatcher/repos.d)
    status_file=$(path_at_root /var/lib/kvm-dispatcher/status.json)
    credential_path=$(path_at_root /etc/kvm-dispatcher/app-key.cred)
    check_file "$dispatcher_unit" 'kvm-dispatcher.service' || return 1
    check_file "$dispatcher_script" '配車係のdispatcher script' || return 1
    check_file "$dispatcher_library" '配車係のdispatcher library' || return 1
    check_file "$policy_file" '配車係のpolkit rule' || return 1
    check_file "$(path_at_root /etc/kvm-dispatcher/dispatcher.conf)" '配車係の設定file' || return 1
    if [[ ! -f $credential_path || -L $credential_path ]]; then
        fail '暗号化済みApp credentialが見つかりません。credentialの内容は読みません。'
        return 1
    fi
    if [[ -L $dispatcher_script || ! -x $dispatcher_script || -L $dispatcher_library ]] ||
        ! cmp -s -- "$CHECKOUT_ROOT/host/kvm_dispatcher.sh" "$dispatcher_script" ||
        ! cmp -s -- "$CHECKOUT_ROOT/host/kvm_dispatcher_lib.sh" "$dispatcher_library"; then
        fail '設置済みdispatcher scriptまたはlibraryがこのcheckoutと一致しません。'
        return 1
    fi
    if ! cmp -s -- "$CHECKOUT_ROOT/host/systemd/kvm-dispatcher.service" "$dispatcher_unit"; then
        fail '設置済みkvm-dispatcher.serviceがこのcheckoutと一致しません。'
        return 1
    fi
    if ! cmp -s -- "$CHECKOUT_ROOT/host/polkit/50-kvm-dispatcher.rules" "$policy_file"; then
        fail '設置済みpolkit ruleがこのcheckoutと一致しません。'
        return 1
    fi
    if [[ ! -d $repos_dir || -L $repos_dir ]]; then
        fail 'repos.d directoryを確認できません。'
        return 1
    fi
    if [[ ! -e $status_file && $TARGET == qoral ]]; then
        fail 'status.jsonがありません。QA2の配車実績を確認できません。'
        return 1
    fi
    if [[ $MODE == stage ]]; then
        if ! getent group kvm-dispatcher >/dev/null 2>&1; then
            fail '配車係のsystem groupがありません。先にinstall wizardを完了してください。'
            return 1
        fi
        if ! getent group "$JOB_GROUP" >/dev/null 2>&1; then
            fail "job groupがありません。先に$REPOのhost setupを完了してください: $JOB_GROUP"
            return 1
        fi
        local groups
        groups=$(id -nG kvm-dispatcher 2>/dev/null) || {
            fail 'kvm-dispatcherのgroup membershipを確認できません。'
            return 1
        }
        if [[ " $groups " != *" $JOB_GROUP "* ]]; then
            fail "kvm-dispatcherがjob groupに属していません。先にcore identityを更新してください: $JOB_GROUP"
            return 1
        fi
    fi
    printf '配車係のservice、polkit、group、credential pathを確認しました。credentialの内容は読みません。\n'
}

systemctl_state() {
    local command_name=$1 unit=$2 result
    result=$(systemctl_cmd "$command_name" "$unit" 2>/dev/null) || true
    [[ -n $result ]] || result=unknown
    printf '%s\n' "$result"
}

require_service_state() {
    local command_name=$1 unit=$2 expected=$3 actual
    actual=$(systemctl_state "$command_name" "$unit")
    if [[ $actual != "$expected" ]]; then
        fail "$unit の状態が想定と異なります。$command_name=$expected が必要ですが、$actual でした。"
        return 1
    fi
    printf '%s: %s=%s\n' "$unit" "$command_name" "$actual"
}

check_other_adapters() {
    local file base allowed
    for file in "$REPOS_DIR"/*.conf; do
        [[ -e $file || -L $file ]] || continue
        base=${file##*/}
        allowed=0
        case $TARGET:$base in
            qa2:qa2.conf|qoral:qa2.conf|qoral:qoral.conf) allowed=1 ;;
            *)
                if [[ $MODE == rollback && ( $base == qa2.conf || $base == qoral.conf ) ]]; then
                    allowed=1
                fi
                ;;
        esac
        if (( allowed == 0 )); then
            fail "想定外のadapter fileがあります。変更しません: $file"
            return 1
        fi
    done
}

check_repos_dir() {
    REPOS_DIR=$(path_at_root /etc/kvm-dispatcher/repos.d)
    [[ -d $REPOS_DIR && ! -L $REPOS_DIR ]] || {
        fail 'repos.d directoryを確認できません。'
        return 1
    }
    check_other_adapters "$ADAPTER"
    if [[ -e $ADAPTER_DEST || -L $ADAPTER_DEST ]]; then
        check_destination "$ADAPTER_SOURCE" "$ADAPTER_DEST" 0640 root:kvm-dispatcher "$ADAPTER.conf"
    fi
}

check_qa2_idle() {
    local since events
    if [[ $(systemctl_state is-active qa2-runner.service) != active ]]; then
        fail 'qa2-runner.serviceがactiveではありません。QA2の状態を個別に確認してください。'
        return 1
    fi
    since=$(systemctl_cmd show --property=ActiveEnterTimestamp --value qa2-runner.service 2>/dev/null) || {
        fail 'QA2 runnerの起動時刻を確認できません。busy状態を判定できないため停止します。'
        return 1
    }
    if [[ -z $since || $since == n/a || $since == 0 ]]; then
        fail 'QA2 runnerの起動時刻を確認できません。busy状態を判定できないため停止します。'
        return 1
    fi
    events=$(journalctl_cmd --unit=qa2-runner.service --since="$since" --no-pager --output=cat 2>/dev/null) || {
        fail 'QA2 runnerのjournalを読めません。busy状態を判定できないため停止します。'
        return 1
    }
    if [[ $events == *'event=runner-busy'* ]]; then
        fail 'QA2 runnerの現在の起動後にbusy eventがあります。jobとcleanupが終わるまで切り替えません。'
        return 1
    fi
    if [[ $events == *'event=runner-state-unavailable'* ]]; then
        fail 'QA2 runnerのbusy状態を取得できませんでした。状態が分かるまで切り替えません。'
        return 1
    fi
    if [[ $events != *'event=runner-online'* ]]; then
        fail '現在のQA2 runner invocationからonline eventを確認できません。busy状態を確認できるまで切り替えません。'
        return 1
    fi
    printf 'QA2 runnerのjournalを確認しました。現在の起動後に実行中eventはありません。\n'
}

status_file_path() {
    path_at_root /var/lib/kvm-dispatcher/status.json
}

status_has_fresh_poll() {
    local repo=$1 since=$2 status_file
    status_file=$(status_file_path)
    [[ -r $status_file ]] || return 1
    jq -e --arg repo "$repo" --arg since "$since" '
        .last_poll[$repo].http == "200" and .last_poll[$repo].at >= $since
    ' "$status_file" >/dev/null 2>&1
}

read_job_counts() {
    local repo=$1 status_file=$2
    jq -er --arg repo "$repo" '
        [
            ([.queued[]? | select(.repo == $repo)] | length),
            ([.in_flight[]? | select(.repo == $repo)] | length),
            ([.recent[]? | select(.repo == $repo and .outcome == "done")] | length)
        ] | @tsv
    ' "$status_file"
}

active_job_units() {
    local unit_prefix=$1 output
    output=$(systemctl_cmd list-units --type=service --state=active --no-legend "$unit_prefix*.service" 2>/dev/null) || {
        fail "active $unit_prefix unitsを確認できません。"
        return 1
    }
    awk 'NF { print $1 }' <<< "$output"
}

check_qa2_dispatch_proof() {
    local status_file events unit found=0
    status_file=$(status_file_path)
    if [[ $(systemctl_state is-active kvm-dispatcher.service) != active ||
        $(systemctl_state is-enabled kvm-dispatcher.service) != enabled ]]; then
        fail 'Qoralを追加するには、kvm-dispatcher.serviceがactiveかつenabledである必要があります。'
        return 1
    fi
    if [[ $(systemctl_state is-active qa2-runner.service) != inactive ||
        $(systemctl_state is-enabled qa2-runner.service) != disabled ]]; then
        fail 'QA2のlegacy serviceがinactiveかつdisabledではありません。Qoralを追加しません。'
        return 1
    fi
    if ! status_has_fresh_poll qniapp/qa2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '5 minutes ago')"; then
        fail 'QA2のstatus.jsonに直近のHTTP 200がありません。Qoralを追加しません。'
        return 1
    fi
    jq -e '
        any(.recent[]?;
            .repo == "qniapp/qa2" and .outcome == "done" and
            (.unit | test("^qa2-runner-job@[0-9a-z-]+\\.service$"))
        )
    ' "$status_file" >/dev/null 2>&1 || {
        fail 'QA2 の成功実績がありません。配車係経由のQA2 jobが1件成功してからQoralを追加してください。'
        return 1
    }
    events=$(journalctl_cmd --unit=kvm-dispatcher.service --no-pager --output=cat 2>/dev/null) || {
        fail '配車係のjournalを読めません。QA2の成功実績を検証できません。'
        return 1
    }
    while IFS= read -r unit; do
        [[ $unit =~ ^qa2-runner-job@[0-9a-z-]+\.service$ ]] || continue
        if [[ $events == *"job-finished unit=$unit "* && $events == *"outcome=done"* ]]; then
            found=1
            break
        fi
    done < <(jq -r '
        .recent[]? | select(.repo == "qniapp/qa2" and .outcome == "done") | .unit
    ' "$status_file")
    if (( found == 0 )); then
        fail 'status.jsonと配車係のjournalに一致するQA2成功eventがありません。Qoralを追加しません。'
        return 1
    fi
    printf 'QA2の成功job、fresh poll、legacy serviceの停止状態を確認しました。\n'
}

source_conflict_check() {
    local source=$1 destination=$2 mode=$3 owner_group=$4 description=$5
    check_destination "$source" "$destination" "$mode" "$owner_group" "$description"
}

place_file() {
    local source=$1 destination=$2 mode=$3 owner_group=$4 description=$5 owner group
    if [[ -e $destination || -L $destination ]]; then
        check_destination "$source" "$destination" "$mode" "$owner_group" "$description"
        printf '同じfileがあるため配置を省略します: %s\n' "$destination"
        return 0
    fi
    confirm_action "$source を $destination に配置します。owner:group=$owner_group、mode=$mode" || return 1
    CUTOVER_STATE=placing-files
    if (( TEST_MODE == 1 )); then
        fail 'テスト用ルートではfileを配置できません。'
        return 1
    fi
    owner=${owner_group%%:*}
    group=${owner_group#*:}
    install -D --owner="$owner" --group="$group" --mode="$mode" -- "$source" "$destination" || {
        fail "fileを配置できませんでした: $destination"
        return 1
    }
    if ! cmp -s -- "$source" "$destination" || ! metadata_matches "$destination" "$mode" "$owner_group"; then
        fail "配置後のfileを検証できませんでした: $destination"
        return 1
    fi
}

run_confirmed_command() {
    local description=$1 next_state=$2
    shift 2
    confirm_action "$description" || return 1
    CUTOVER_STATE=$next_state
    if ! "$@"; then
        fail "コマンドが失敗しました: $description"
        return 1
    fi
}

run_systemctl_action() {
    local description=$1 next_state=$2
    shift 2
    run_confirmed_command "$description" "$next_state" systemctl_cmd "$@"
}

verify_template_properties() {
    local output template instance restart memory
    instance="${UNIT_PREFIX}cutover-check.service"
    output=$(systemctl_cmd show --property=Restart --property=MemoryAccounting "$instance" 2>/dev/null) || {
        fail "systemdがtemplateの設定を読み込めません: $TEMPLATE_UNIT"
        return 1
    }
    template=$(systemctl_cmd cat "$TEMPLATE_UNIT" 2>/dev/null) || {
        fail "systemdがtemplateの設定を読み込めません: $TEMPLATE_UNIT"
        return 1
    }
    restart=$(awk -F= '$1 == "Restart" { print $2 }' <<< "$output")
    memory=$(awk -F= '$1 == "MemoryAccounting" { print $2 }' <<< "$output")
    if [[ $restart != no || $memory != yes ]] ||
        ! grep -Fxq -- 'LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token' <<< "$template"; then
        fail "$TEMPLATE_UNIT のRestart、MemoryAccounting、LoadCredentialが想定と異なります。"
        return 1
    fi
    printf '%s: Restart=no、MemoryAccounting=yes、dispatcher credentialを確認しました。\n' "$TEMPLATE_UNIT"
}

verify_dispatcher_service() {
    local expected=$1 actual
    actual=$(systemctl_state is-active kvm-dispatcher.service)
    if [[ $actual != "$expected" ]]; then
        fail "kvm-dispatcher.serviceのactive状態が想定と異なります。$expectedが必要ですが、$actualでした。"
        return 1
    fi
    actual=$(systemctl_state is-enabled kvm-dispatcher.service)
    if [[ $actual != "$expected" && ! ($expected == active && $actual == enabled) ]]; then
        fail "kvm-dispatcher.serviceのenabled状態が想定と異なります。$expectedが必要ですが、$actualでした。"
        return 1
    fi
    printf 'kvm-dispatcher.service: active=%s、enabled=%s\n' \
        "$(systemctl_state is-active kvm-dispatcher.service)" \
        "$(systemctl_state is-enabled kvm-dispatcher.service)"
}

verify_legacy_disabled() {
    require_service_state is-active "$LEGACY_UNIT" inactive || return 1
    require_service_state is-enabled "$LEGACY_UNIT" disabled
}

stop_qa2_legacy() {
    confirm_action 'qa2-runner.serviceを停止します。' || return 1
    check_qa2_idle || return 1
    CUTOVER_STATE=legacy-stopped
    if ! systemctl_cmd stop qa2-runner.service; then
        fail 'qa2-runner.serviceを停止できませんでした。'
        return 1
    fi
}

wait_for_fresh_poll() {
    local repo=$1 since=$2 attempt
    for ((attempt = 0; attempt < 120; attempt++)); do
        if [[ $(systemctl_state is-active kvm-dispatcher.service) != active ]]; then
            fail 'status.jsonを待つ間にkvm-dispatcher.serviceが停止しました。'
            return 1
        fi
        if status_has_fresh_poll "$repo" "$since"; then
            return 0
        fi
        sleep 1
    done
    fail "$repo のfresh HTTP 200を120秒以内にstatus.jsonで確認できませんでした。"
    return 1
}

verify_poll_and_queue() {
    local repo=$1 since=$2 status_file=$3 counts queued in_flight completed events
    status_has_fresh_poll "$repo" "$since" || {
        fail "$repo のfresh HTTP 200がstatus.jsonにありません。"
        return 1
    }
    counts=$(read_job_counts "$repo" "$status_file") || {
        fail 'status.jsonのjob状態を読み取れません。'
        return 1
    }
    IFS=$'\t' read -r queued in_flight completed <<< "$counts"
    printf '%s: fresh HTTP 200、queued=%s、in_flight=%s、recent_success=%s\n' \
        "$repo" "$queued" "$in_flight" "$completed"
    if (( queued == 0 )); then
        printf '%s にqueued jobはありません。dispatcherのpollを確認しました。\n' "$repo"
        return 0
    fi
    if (( in_flight == 0 && completed == 0 )); then
        fail "$repo にqueued jobが残っていますが、配車係がclaimした状態を確認できません。"
        return 1
    fi
    events=$(journalctl_cmd --unit=kvm-dispatcher.service --since="$since" --no-pager --output=cat 2>/dev/null) || {
        fail '配車係のjournalを読めません。job claimを検証できません。'
        return 1
    }
    if [[ $events != *"job-started unit=$UNIT_PREFIX"* && $events != *"job-finished unit=$UNIT_PREFIX"* ]]; then
        fail "$repo のjob claim eventをjournalで確認できません。"
        return 1
    fi
    printf '%s のjob claim eventをjournalで確認しました。\n' "$repo"
}

preflight_common() {
    local command_name expected_legacy
    for command_name in cmp date find getent git grep id install journalctl jq readlink rm stat systemctl awk; do
        require_command "$command_name" || return 1
    done
    if (( EUID != 0 && TEST_MODE == 0 )); then
        fail 'sudoでwizardを実行してください。'
        return 1
    fi
    if (( TEST_MODE == 0 )) && [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        fail '確認用terminalが必要です。'
        return 1
    fi
    if [[ $(pwd -P) != "$CHECKOUT_ROOT" ]]; then
        fail "kvm-dispatcher checkoutのrootから実行してください: $CHECKOUT_ROOT"
        return 1
    fi
    local checkout status
    checkout=$(git -C "$CHECKOUT_ROOT" rev-parse --show-toplevel 2>/dev/null) || {
        fail 'kvm-dispatcherのGit checkoutを確認できません。'
        return 1
    }
    status=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
        git -c "safe.directory=$CHECKOUT_ROOT" -c core.fsmonitor=false -C "$CHECKOUT_ROOT" \
        status --porcelain --untracked-files=all 2>/dev/null) || {
        fail 'kvm-dispatcher checkoutの状態を確認できません。'
        return 1
    }
    if (( TEST_MODE == 1 )); then status=; fi
    if [[ $(readlink -f -- "$checkout") != "$CHECKOUT_ROOT" || -n $status ]]; then
        fail 'kvm-dispatcher checkoutがcleanではありません。変更をcommitしてから実行してください。'
        return 1
    fi
    DISPATCHER_HEAD=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
        git -c "safe.directory=$CHECKOUT_ROOT" -c core.fsmonitor=false -C "$CHECKOUT_ROOT" rev-parse HEAD) || {
        fail 'kvm-dispatcher checkoutのHEADを確認できません。'
        return 1
    }
    printf 'kvm-dispatcher checkout: %s\nHEAD: %s\n' "$CHECKOUT_ROOT" "$DISPATCHER_HEAD"
    check_host_core || return 1
    check_source_artifacts || return 1
    check_repos_dir || return 1
    if ! systemctl_cmd cat kvm-dispatcher.service >/dev/null 2>&1; then
        fail 'kvm-dispatcher.serviceをsystemdから読み込めません。'
        return 1
    fi
    [[ -f $LEGACY_DEST && ! -L $LEGACY_DEST ]] || {
        fail "従来service unitがありません: $LEGACY_DEST"
        return 1
    }
    expected_legacy=$(systemctl_state is-active "$LEGACY_UNIT")
    printf '%s: active=%s、enabled=%s\n' "$LEGACY_UNIT" "$expected_legacy" \
        "$(systemctl_state is-enabled "$LEGACY_UNIT")"
}

check_qoral_legacy_off() {
    local active enabled
    active=$(systemctl_state is-active qoral-runner.service)
    enabled=$(systemctl_state is-enabled qoral-runner.service)
    if [[ $active == active || $enabled == enabled ]]; then
        fail "qoral-runner.serviceはinactiveかつdisabledである必要があります。active=$active enabled=$enabled"
        return 1
    fi
    printf 'qoral-runner.service: active=%s、enabled=%s\n' "$active" "$enabled"
}

check_stage_preconditions() {
    local dispatcher_active dispatcher_enabled legacy_active legacy_enabled
    dispatcher_active=$(systemctl_state is-active kvm-dispatcher.service)
    dispatcher_enabled=$(systemctl_state is-enabled kvm-dispatcher.service)
    legacy_active=$(systemctl_state is-active "$LEGACY_UNIT")
    legacy_enabled=$(systemctl_state is-enabled "$LEGACY_UNIT")
    if [[ $TARGET == qa2 ]]; then
        if [[ $dispatcher_active == active || $dispatcher_enabled == enabled ]]; then
            fail 'kvm-dispatcher.serviceがすでに有効です。部分切替状態を調査してから再実行してください。'
            return 1
        fi
        if [[ $dispatcher_active != inactive || $dispatcher_enabled != disabled ]]; then
            fail "kvm-dispatcher.serviceはinactiveかつdisabledである必要があります。active=$dispatcher_active enabled=$dispatcher_enabled"
            return 1
        fi
        if [[ $legacy_active != active || $legacy_enabled != enabled ]]; then
            fail "QA2切替前のqa2-runner.serviceはactiveかつenabledである必要があります。active=$legacy_active enabled=$legacy_enabled"
            return 1
        fi
        if ! check_qa2_idle; then return 1; fi
        check_qoral_legacy_off || return 1
    else
        if [[ $dispatcher_active != active || $dispatcher_enabled != enabled ]]; then
            fail 'Qoralを追加する前にkvm-dispatcher.serviceがactiveかつenabledである必要があります。'
            return 1
        fi
        if [[ $legacy_active != inactive || $legacy_enabled != disabled ]]; then
            fail 'qoral-runner.serviceはinactiveかつdisabledである必要があります。Qoral legacy unitは変更しません。'
            return 1
        fi
        if ! check_qa2_dispatch_proof; then return 1; fi
        local qa2_adapter
        qa2_adapter=$(path_at_root /etc/kvm-dispatcher/repos.d/qa2.conf)
        if [[ ! -f $qa2_adapter || -L $qa2_adapter ]] || ! cmp -s -- "$CHECKOUT_ROOT/host/repos.d/qa2.conf.example" "$qa2_adapter"; then
            fail 'QA2 adapterがこのcheckoutのexampleと一致しません。Qoralを追加しません。'
            return 1
        fi
        local other_adapter
        other_adapter=$(path_at_root /etc/kvm-dispatcher/repos.d/qoral.conf)
        if [[ -e $other_adapter || -L $other_adapter ]]; then
            check_destination "$ADAPTER_SOURCE" "$other_adapter" 0640 root:kvm-dispatcher 'qoral.conf' || return 1
        fi
    fi
}

qa2_stage() {
    local status_file active_units qoral_units
    printf '\nQA2 stageではtemplate、2つのdrop-in、adapterを配置します。\n'
    printf 'その後、idleを再確認してqa2-runner.serviceを停止・無効化し、配車係を有効化・起動します。\n'
    resolve_source_root qa2 || return 1
    preflight_common || return 1
    if already_complete qa2; then return 0; fi
    check_stage_preconditions || return 1
    active_units=$(active_job_units qa2-runner-job@) || return 1
    if [[ -n $active_units ]]; then
        fail "QA2の配車job unitがすでにactiveです。部分切替の状態を調査してください: $active_units"
        return 1
    fi
    qoral_units=$(active_job_units qoral-runner-job@) || return 1
    if [[ -n $qoral_units ]]; then
        fail "Qoralの配車job unitがすでにactiveです。部分切替の状態を調査してください: $qoral_units"
        return 1
    fi
    if ! source_conflict_check "$TEMPLATE_SOURCE" "$TEMPLATE_DEST" 0644 root:root "$TEMPLATE_UNIT" ||
        ! source_conflict_check "$ISOLATION_SOURCE" "$ISOLATION_DEST" 0644 root:root '10-isolation.conf' ||
        ! source_conflict_check "$RUNTIME_SOURCE" "$RUNTIME_DEST" 0644 root:root '20-job-runtime.conf' ||
        ! source_conflict_check "$ADAPTER_SOURCE" "$ADAPTER_DEST" 0640 root:kvm-dispatcher 'qa2.conf'; then
        return 1
    fi
    confirm_idle || return 1
    if ! place_file "$TEMPLATE_SOURCE" "$TEMPLATE_DEST" 0644 root:root "$TEMPLATE_UNIT" ||
        ! place_file "$ISOLATION_SOURCE" "$ISOLATION_DEST" 0644 root:root '10-isolation.conf' ||
        ! place_file "$RUNTIME_SOURCE" "$RUNTIME_DEST" 0644 root:root '20-job-runtime.conf' ||
        ! place_file "$ADAPTER_SOURCE" "$ADAPTER_DEST" 0640 root:kvm-dispatcher 'qa2.conf'; then
        offer_rollback qa2
        return 1
    fi
    CUTOVER_STATE=files-placed
    run_systemctl_action 'systemctl daemon-reloadを実行します。' systemd-reloaded daemon-reload || {
        offer_rollback qa2
        return 1
    }
    verify_template_properties || { offer_rollback qa2; return 1; }
    check_qa2_idle || { offer_rollback qa2; return 1; }
    stop_qa2_legacy || {
        offer_rollback qa2
        return 1
    }
    require_service_state is-active qa2-runner.service inactive || { offer_rollback qa2; return 1; }
    run_systemctl_action 'qa2-runner.serviceをdisableします。unit fileは削除しません。' legacy-disabled disable qa2-runner.service || {
        offer_rollback qa2
        return 1
    }
    require_service_state is-enabled qa2-runner.service disabled || { offer_rollback qa2; return 1; }
    check_qoral_legacy_off || { offer_rollback qa2; return 1; }
    run_systemctl_action 'kvm-dispatcher.serviceをenableします。' dispatcher-enabled enable kvm-dispatcher.service || {
        offer_rollback qa2
        return 1
    }
    require_service_state is-enabled kvm-dispatcher.service enabled || { offer_rollback qa2; return 1; }
    require_service_state is-active qa2-runner.service inactive || { offer_rollback qa2; return 1; }
    require_service_state is-enabled qa2-runner.service disabled || { offer_rollback qa2; return 1; }
    check_qoral_legacy_off || { offer_rollback qa2; return 1; }
    STAGE_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    run_systemctl_action 'kvm-dispatcher.serviceをstartします。' dispatcher-started start kvm-dispatcher.service || {
        offer_rollback qa2
        return 1
    }
    verify_dispatcher_service active || { offer_rollback qa2; return 1; }
    if ! wait_for_fresh_poll qniapp/qa2 "$STAGE_STARTED_AT"; then
        offer_rollback qa2
        return 1
    fi
    status_file=$(status_file_path)
    if ! verify_poll_and_queue qniapp/qa2 "$STAGE_STARTED_AT" "$status_file"; then
        offer_rollback qa2
        return 1
    fi
    verify_legacy_disabled || { offer_rollback qa2; return 1; }
    CUTOVER_STATE=verified
    printf '\nQA2 stageが完了しました。legacy unitは残したままdisabledです。\n'
    printf 'Qoral stageは、配車係経由のQA2 jobが1件成功してから別途実行してください。\n'
}

qoral_stage() {
    local status_file active_units
    printf '\nQoral stageではQoral template、2つのdrop-in、adapterを追加します。\n'
    printf 'QA2の成功実績を確認してから配車係を再起動し、Qoralのpollを検証します。\n'
    printf 'Qoral PATは作成しません。\n'
    resolve_source_root qoral || return 1
    preflight_common || return 1
    if already_complete qoral; then return 0; fi
    check_stage_preconditions || return 1
    active_units=$(active_job_units qoral-runner-job@) || return 1
    if [[ -n $active_units ]]; then
        fail "Qoralの配車job unitがすでにactiveです。部分切替の状態を調査してください: $active_units"
        return 1
    fi
    if ! source_conflict_check "$TEMPLATE_SOURCE" "$TEMPLATE_DEST" 0644 root:root "$TEMPLATE_UNIT" ||
        ! source_conflict_check "$ISOLATION_SOURCE" "$ISOLATION_DEST" 0644 root:root '10-isolation.conf' ||
        ! source_conflict_check "$RUNTIME_SOURCE" "$RUNTIME_DEST" 0644 root:root '20-job-runtime.conf' ||
        ! source_conflict_check "$ADAPTER_SOURCE" "$ADAPTER_DEST" 0640 root:kvm-dispatcher 'qoral.conf'; then
        return 1
    fi
    if ! place_file "$TEMPLATE_SOURCE" "$TEMPLATE_DEST" 0644 root:root "$TEMPLATE_UNIT" ||
        ! place_file "$ISOLATION_SOURCE" "$ISOLATION_DEST" 0644 root:root '10-isolation.conf' ||
        ! place_file "$RUNTIME_SOURCE" "$RUNTIME_DEST" 0644 root:root '20-job-runtime.conf' ||
        ! place_file "$ADAPTER_SOURCE" "$ADAPTER_DEST" 0640 root:kvm-dispatcher 'qoral.conf'; then
        offer_rollback qoral
        return 1
    fi
    CUTOVER_STATE=files-placed
    run_systemctl_action 'systemctl daemon-reloadを実行します。' systemd-reloaded daemon-reload || {
        offer_rollback qoral
        return 1
    }
    verify_template_properties || { offer_rollback qoral; return 1; }
    check_stage_preconditions || { offer_rollback qoral; return 1; }
    active_units=$(active_job_units qoral-runner-job@) || { offer_rollback qoral; return 1; }
    if [[ -n $active_units ]]; then
        fail "Qoralの配車job unitがすでにactiveです。部分切替の状態を調査してください: $active_units"
        offer_rollback qoral
        return 1
    fi
    STAGE_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    run_systemctl_action 'kvm-dispatcher.serviceをrestartしてQoral adapterを読み込みます。' dispatcher-restarted restart kvm-dispatcher.service || {
        offer_rollback qoral
        return 1
    }
    verify_dispatcher_service active || { offer_rollback qoral; return 1; }
    if ! wait_for_fresh_poll qorraq/qoral "$STAGE_STARTED_AT"; then
        offer_rollback qoral
        return 1
    fi
    status_file=$(status_file_path)
    if ! verify_poll_and_queue qorraq/qoral "$STAGE_STARTED_AT" "$status_file"; then
        offer_rollback qoral
        return 1
    fi
    verify_legacy_disabled || { offer_rollback qoral; return 1; }
    check_qa2_dispatch_proof || { offer_rollback qoral; return 1; }
    CUTOVER_STATE=verified
    printf '\nQoral stageが完了しました。qoral-runner.serviceはdisabledのままです。\n'
    printf 'QA2とQoralのlegacy unit fileは残っています。Qoral PATは作成していません。\n'
}

rollback_preflight() {
    local active enabled adapter_path
    check_host_core || return 1
    check_file "$LEGACY_DEST" '従来service unit' || return 1
    check_repos_dir || return 1
    adapter_path=$(path_at_root "/etc/kvm-dispatcher/repos.d/$ADAPTER.conf")
    if [[ -e $adapter_path || -L $adapter_path ]]; then
        if [[ -L $adapter_path || ! -f $adapter_path ]] || ! cmp -s -- "$ADAPTER_SOURCE" "$adapter_path"; then
            fail "対象adapterがこのcheckoutのexampleと一致しません。削除しません: $adapter_path"
            return 1
        fi
    fi
    active=$(systemctl_state is-active kvm-dispatcher.service)
    enabled=$(systemctl_state is-enabled kvm-dispatcher.service)
    printf 'kvm-dispatcher.service: active=%s、enabled=%s\n' "$active" "$enabled"
    printf '%s: active=%s、enabled=%s\n' "$LEGACY_UNIT" \
        "$(systemctl_state is-active "$LEGACY_UNIT")" \
        "$(systemctl_state is-enabled "$LEGACY_UNIT")"
}

check_rollback_topology() {
    local adapter_path other_adapter active enabled legacy_active
    adapter_path=$(path_at_root "/etc/kvm-dispatcher/repos.d/$ADAPTER.conf")
    active=$(systemctl_state is-active kvm-dispatcher.service)
    enabled=$(systemctl_state is-enabled kvm-dispatcher.service)
    legacy_active=$(systemctl_state is-active "$LEGACY_UNIT")
    if [[ $active != active && $active != inactive ]] ||
        [[ $enabled != enabled && $enabled != disabled ]]; then
        fail "配車係のservice状態を確認できません。active=$active enabled=$enabled"
        return 1
    fi
    if [[ -e $adapter_path && $legacy_active == active &&
        ( $active != inactive || $enabled != disabled ) ]]; then
        fail "$LEGACY_UNITと対象adapterが同時に有効です。状態を調査するまでrollbackしません。"
        return 1
    fi
    if [[ $TARGET == qa2 ]]; then
        other_adapter=$(path_at_root /etc/kvm-dispatcher/repos.d/qoral.conf)
        if [[ -e $other_adapter || -L $other_adapter ]]; then
            fail 'Qoral adapterが残っています。先にQoral rollbackを完了してください。'
            return 1
        fi
    else
        other_adapter=$(path_at_root /etc/kvm-dispatcher/repos.d/qa2.conf)
        if [[ -e $other_adapter || -L $other_adapter ]]; then
            check_destination "$CHECKOUT_ROOT/host/repos.d/qa2.conf.example" "$other_adapter" 0640 root:kvm-dispatcher 'qa2.conf' || return 1
            printf 'QA2 adapterを残してQoralだけをrollbackします。dispatcherを再起動してQA2を維持します。\n'
        fi
    fi
}

rollback_action() {
    local unit units qa2_units qoral_units adapter_path other_adapter active enabled
    local keep_dispatcher=0 adapter_removed=0
    if [[ $TARGET == qoral ]]; then
        other_adapter=$(path_at_root /etc/kvm-dispatcher/repos.d/qa2.conf)
        if [[ -e $other_adapter && ! -L $other_adapter ]]; then keep_dispatcher=1; fi
    fi
    active=$(systemctl_state is-active kvm-dispatcher.service)
    if [[ $active == active ]]; then
        run_systemctl_action 'kvm-dispatcher.serviceをstopします。' rollback-dispatcher-stopped stop kvm-dispatcher.service || return 1
        require_service_state is-active kvm-dispatcher.service inactive || return 1
    fi
    enabled=$(systemctl_state is-enabled kvm-dispatcher.service)
    if (( keep_dispatcher == 0 )) && [[ $enabled == enabled ]]; then
        run_systemctl_action 'kvm-dispatcher.serviceをdisableします。' rollback-dispatcher-disabled disable kvm-dispatcher.service || return 1
        require_service_state is-enabled kvm-dispatcher.service disabled || return 1
    fi
    qa2_units=$(active_job_units qa2-runner-job@) || return 1
    qoral_units=$(active_job_units qoral-runner-job@) || return 1
    units=$(printf '%s\n%s\n' "$qa2_units" "$qoral_units" | awk 'NF && !seen[$0]++')
    if [[ -n $units ]]; then
        printf '\n停止するactive job unit:\n%s\n' "$units"
        while IFS= read -r unit; do
            [[ -n $unit ]] || continue
            [[ $unit =~ ^(qa2|qoral)-runner-job@[0-9a-z-]+\.service$ ]] || {
                fail "想定外のjob unit名です。停止しません: $unit"
                return 1
            }
            run_systemctl_action "$unitをstopします。" rollback-job-stopped stop "$unit" || return 1
            require_service_state is-active "$unit" inactive || return 1
        done <<< "$units"
    fi
    adapter_path=$(path_at_root "/etc/kvm-dispatcher/repos.d/$ADAPTER.conf")
    if [[ -e $adapter_path || -L $adapter_path ]]; then
        confirm_action "$adapter_pathだけを削除します。legacy unit fileとjob templateは残します。" || return 1
        CUTOVER_STATE=rollback-adapter-removed
        rm -f -- "$adapter_path" || {
            fail "adapterを削除できませんでした: $adapter_path"
            return 1
        }
        [[ ! -e $adapter_path && ! -L $adapter_path ]] || {
            fail "adapterの削除を確認できません: $adapter_path"
            return 1
        }
        adapter_removed=1
    fi
    if (( keep_dispatcher == 1 )); then
        enabled=$(systemctl_state is-enabled kvm-dispatcher.service)
        if [[ $enabled != enabled ]]; then
            run_systemctl_action 'QA2 adapterを維持するためkvm-dispatcher.serviceをenableします。' rollback-dispatcher-enabled enable kvm-dispatcher.service || return 1
            require_service_state is-enabled kvm-dispatcher.service enabled || return 1
        fi
        active=$(systemctl_state is-active kvm-dispatcher.service)
        if [[ $active != active ]]; then
            run_systemctl_action 'QA2 adapterを維持するためkvm-dispatcher.serviceをstartします。' rollback-dispatcher-started start kvm-dispatcher.service || return 1
        elif (( adapter_removed == 1 )); then
            run_systemctl_action 'Qoral adapterを外した設定を読み込むためdispatcherをrestartします。' rollback-dispatcher-restarted restart kvm-dispatcher.service || return 1
        fi
        verify_dispatcher_service active || return 1
    fi
    enabled=$(systemctl_state is-enabled "$LEGACY_UNIT")
    if [[ $enabled != enabled ]]; then
        run_systemctl_action "$LEGACY_UNITをenableします。unit fileは残します。" rollback-legacy-enabled enable "$LEGACY_UNIT" || return 1
        require_service_state is-enabled "$LEGACY_UNIT" enabled || return 1
    fi
    active=$(systemctl_state is-active "$LEGACY_UNIT")
    if [[ $active != active ]]; then
        run_systemctl_action "$LEGACY_UNITをstartします。" rollback-legacy-started start "$LEGACY_UNIT" || return 1
        require_service_state is-active "$LEGACY_UNIT" active || return 1
    fi
    require_service_state is-enabled "$LEGACY_UNIT" enabled || return 1
    require_service_state is-active "$LEGACY_UNIT" active || return 1
    if (( keep_dispatcher == 1 )); then
        verify_dispatcher_service active || return 1
    else
        require_service_state is-active kvm-dispatcher.service inactive || return 1
        require_service_state is-enabled kvm-dispatcher.service disabled || return 1
    fi
    printf '\n%sへのrollbackが完了しました。legacy unit fileとjob templateは残しています。\n' "$REPO"
    if [[ $TARGET == qoral ]]; then
        printf 'このwizardはQoral PATを作成しません。\n'
    fi
}

rollback_stage() {
    printf '\n%sのrollbackでは、dispatcherを停止してからactive job unitを停止します。\n' "$REPO"
    printf 'QA2 adapterが残る場合はdispatcherを再起動してQA2を維持し、Qoral adapterを外します。\n'
    printf 'QA2 adapterが残らない場合はdispatcherをdisableし、対象adapterだけを削除します。\n'
    printf 'legacy unit fileとjob templateは削除しません。\n'
    for command_name in cmp git readlink rm stat systemctl awk; do
        require_command "$command_name" || return 1
    done
    if (( EUID != 0 && TEST_MODE == 0 )); then
        fail 'sudoでwizardを実行してください。'
        return 1
    fi
    if (( TEST_MODE == 0 )) && [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        fail '確認用terminalが必要です。'
        return 1
    fi
    check_dispatcher_checkout || return 1
    rollback_preflight || return 1
    check_rollback_topology || return 1
    confirm_legacy_ready || return 1
    rollback_action
}

offer_rollback() {
    local target=$1 answer
    if [[ $CUTOVER_STATE == preflight || $CUTOVER_STATE == verified ]]; then
        return 0
    fi
    if (( TEST_MODE == 1 )); then
        return 0
    fi
    printf '\n検証に失敗しました。%sのrollbackを開始できます。\n' "$target" >/dev/tty
    printf '%s.confだけを削除します。QA2 adapterが残る場合はdispatcherを維持します。\n' "$target" >/dev/tty
    printf 'rollbackを開始しますか？ [y/N] ' >/dev/tty
    if ! IFS= read -r answer </dev/tty || [[ $answer != y && $answer != Y ]]; then
        printf '状態を保持しました。journalとstatus.jsonを確認してください。\n' >/dev/tty
        return 0
    fi
    load_target "$target"
    check_dispatcher_checkout || return 1
    rollback_preflight || return 1
    check_rollback_topology || return 1
    confirm_legacy_ready || return 1
    rollback_action
}

already_complete() {
    local target=$1
    [[ -f $TEMPLATE_DEST && ! -L $TEMPLATE_DEST &&
        -f $ISOLATION_DEST && ! -L $ISOLATION_DEST &&
        -f $RUNTIME_DEST && ! -L $RUNTIME_DEST &&
        -f $ADAPTER_DEST && ! -L $ADAPTER_DEST ]] || return 1
    check_destination "$TEMPLATE_SOURCE" "$TEMPLATE_DEST" 0644 root:root "$TEMPLATE_UNIT" || return 1
    check_destination "$ISOLATION_SOURCE" "$ISOLATION_DEST" 0644 root:root '10-isolation.conf' || return 1
    check_destination "$RUNTIME_SOURCE" "$RUNTIME_DEST" 0644 root:root '20-job-runtime.conf' || return 1
    verify_template_properties || return 1
    if [[ $target == qa2 ]]; then
        [[ -f $ADAPTER_DEST && ! -L $ADAPTER_DEST ]] || return 1
        cmp -s -- "$ADAPTER_SOURCE" "$ADAPTER_DEST" || return 1
        [[ $(systemctl_state is-active kvm-dispatcher.service) == active &&
            $(systemctl_state is-enabled kvm-dispatcher.service) == enabled &&
            $(systemctl_state is-active qa2-runner.service) == inactive &&
            $(systemctl_state is-enabled qa2-runner.service) == disabled ]] || return 1
        status_has_fresh_poll qniapp/qa2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '5 minutes ago')" || return 1
    else
        [[ -f $ADAPTER_DEST && ! -L $ADAPTER_DEST ]] || return 1
        cmp -s -- "$ADAPTER_SOURCE" "$ADAPTER_DEST" || return 1
        [[ $(systemctl_state is-active kvm-dispatcher.service) == active &&
            $(systemctl_state is-enabled kvm-dispatcher.service) == enabled &&
            $(systemctl_state is-active qoral-runner.service) == inactive &&
            $(systemctl_state is-enabled qoral-runner.service) == disabled ]] || return 1
        status_has_fresh_poll qorraq/qoral "$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '5 minutes ago')" || return 1
        check_qa2_dispatch_proof || return 1
    fi
    printf '%s stageはすでに完了しています。現在のservice状態とfresh pollを確認しました。\n' "$target"
}

select_menu() {
    local answer
    if (( TEST_MODE == 1 )); then
        fail 'テストではstageを明示してください。'
        return 1
    fi
    printf '%s\n' \
        '実行するstageを選んでください。' \
        '1. QA2を配車係へ切り替える' \
        '2. QA2の成功後にQoralを追加する' \
        '3. QA2をlegacyへ戻す' \
        '4. Qoralをlegacyへ戻す' \
        '0. 終了' >/dev/tty
    printf '番号: ' >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    case $answer in
        1) MODE=stage; SELECTED_TARGET=qa2 ;;
        2) MODE=stage; SELECTED_TARGET=qoral ;;
        3) MODE=rollback; SELECTED_TARGET=qa2 ;;
        4) MODE=rollback; SELECTED_TARGET=qoral ;;
        0) printf '変更せず終了します。\n' >/dev/tty; exit 0 ;;
        *) fail '選択肢が正しくありません。何も変更していません。'; return 2 ;;
    esac
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

if [[ -n ${KVM_DISPATCHER_CUTOVER_TEST_ROOT:-} ]]; then
    if [[ ${KVM_DISPATCHER_CUTOVER_TESTING:-} != 1 || $KVM_DISPATCHER_CUTOVER_TEST_ROOT != /* ]]; then
        fail 'テスト用rootはテストscriptからのみ指定できます。'
        exit 2
    fi
    INSTALL_ROOT=$(readlink -m -- "$KVM_DISPATCHER_CUTOVER_TEST_ROOT")
    if [[ $INSTALL_ROOT == / ]]; then
        fail 'テスト用rootに / は指定できません。'
        exit 2
    fi
    TEST_MODE=1
fi

case $# in
    0) ;;
    1)
        if [[ $1 == --help ]]; then
            usage
            exit 0
        fi
        usage >&2
        exit 2
        ;;
    2)
        case $1 in
            --stage)
                MODE=stage
                SELECTED_TARGET=$2
                ;;
            --rollback)
                MODE=rollback
                SELECTED_TARGET=$2
                ;;
            *) usage >&2; exit 2 ;;
        esac
        [[ $SELECTED_TARGET == qa2 || $SELECTED_TARGET == qoral ]] || { usage >&2; exit 2; }
        ;;
    *) usage >&2; exit 2 ;;
esac

if [[ $MODE == menu ]]; then
    select_menu || exit $?
fi

if [[ $MODE == stage ]]; then
    case $SELECTED_TARGET in
        qa2) qa2_stage ;;
        qoral) qoral_stage ;;
    esac
else
    load_target "$SELECTED_TARGET"
    rollback_stage
fi
