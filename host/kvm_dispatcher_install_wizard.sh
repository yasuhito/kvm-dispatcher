#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
CHECKOUT_ROOT=$(dirname -- "$SCRIPT_DIR")
INSTALL_ROOT=${KVM_DISPATCHER_INSTALL_ROOT:-/}
MODE=all
SELECTED_STAGE=

usage() {
    cat <<'USAGE'
Usage: host/kvm_dispatcher_install_wizard.sh [--stage STAGE | --rollback]

With no arguments, run preflight, install, identity/configuration, PEM, and
verification stages in order. Each stage asks for confirmation. A stage can
also be run on its own with --stage preflight|install|identity|pem|verify.
Use --rollback only before adding any files under repos.d.

KVM_DISPATCHER_INSTALL_ROOT is a test-only destination prefix. When set to a
path other than /, only --stage install is permitted; system changes are not
simulated or run.
USAGE
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
}

case $# in
    0) ;;
    1)
        if [[ $1 == --rollback ]]; then
            MODE=rollback
        elif [[ $1 == --help ]]; then
            usage
            exit 0
        else
            usage >&2
            exit 2
        fi
        ;;
    2)
        if [[ $1 != --stage ]]; then
            usage >&2
            exit 2
        fi
        MODE=stage
        SELECTED_STAGE=$2
        case $SELECTED_STAGE in
            preflight|install|identity|pem|verify) ;;
            *) usage >&2; exit 2 ;;
        esac
        ;;
    *) usage >&2; exit 2 ;;
esac

if [[ $INSTALL_ROOT != / ]]; then
    if [[ $INSTALL_ROOT != /* || $MODE != stage || $SELECTED_STAGE != install ]]; then
        fail 'KVM_DISPATCHER_INSTALL_ROOT is test-only and permits only --stage install with an absolute path.'
        exit 2
    fi
    INSTALL_ROOT=$(readlink -m -- "$INSTALL_ROOT")
    if [[ $INSTALL_ROOT == / ]]; then
        fail 'KVM_DISPATCHER_INSTALL_ROOT must resolve to a path other than /.'
        exit 2
    fi
    TEST_ROOT=1
else
    TEST_ROOT=0
fi

if [[ ! -d $CHECKOUT_ROOT ]]; then
    fail "Cannot locate the source checkout at $CHECKOUT_ROOT."
    exit 1
fi

canonical_checkout=$(readlink -f -- "$CHECKOUT_ROOT")
current_directory=$(pwd -P)
if [[ $current_directory != "$canonical_checkout" ]]; then
    fail "Run this wizard from the checkout root: $canonical_checkout"
    exit 1
fi

# The checkout may be user-owned while this script runs via sudo. Limit Git to
# read-only status/revision queries and explicitly trust only this checkout.
git_read() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
        git -c "safe.directory=$canonical_checkout" -c core.fsmonitor=false \
        -C "$canonical_checkout" "$@"
}

if ! SOURCE_HEAD=$(git_read rev-parse HEAD 2>/dev/null); then
    fail 'Could not read the checkout HEAD commit.'
    exit 1
fi

CORE_SOURCES=(
    host/kvm_dispatcher.sh
    host/kvm_dispatcher_lib.sh
    host/kvm_dispatcher_host_wizard.sh
    host/systemd/kvm-dispatcher.service
    host/systemd/kvm-dispatcher.service.d/10-isolation.conf
    host/polkit/50-kvm-dispatcher.rules
    host/systemd/kvm-dispatcher.sysusers.conf
    host/systemd/kvm-dispatcher.tmpfiles.conf
)
CORE_DESTINATIONS=(
    /opt/kvm-dispatcher/host/kvm_dispatcher.sh
    /opt/kvm-dispatcher/host/kvm_dispatcher_lib.sh
    /opt/kvm-dispatcher/host/kvm_dispatcher_host_wizard.sh
    /etc/systemd/system/kvm-dispatcher.service
    /etc/systemd/system/kvm-dispatcher.service.d/10-isolation.conf
    /etc/polkit-1/rules.d/50-kvm-dispatcher.rules
    /etc/sysusers.d/kvm-dispatcher.conf
    /etc/tmpfiles.d/kvm-dispatcher.conf
)
CORE_MODES=(0755 0644 0755 0644 0644 0644 0644 0644)
CORE_OWNERS=(root:root root:root root:root root:root root:root root:root root:root root:root)

CONFIG_SOURCE=host/dispatcher.conf.example
CONFIG_DESTINATION=/etc/kvm-dispatcher/dispatcher.conf
CREDENTIAL_DESTINATION=/etc/kvm-dispatcher/app-key.cred

DIRECTORY_PATHS=(
    /opt/kvm-dispatcher
    /opt/kvm-dispatcher/host
    /etc/systemd/system/kvm-dispatcher.service.d
    /etc/kvm-dispatcher
    /etc/kvm-dispatcher/repos.d
    /run/kvm-dispatcher
    /var/lib/kvm-dispatcher
)
DIRECTORY_MODES=(0755 0755 0755 0750 0750 0711 0755)
DIRECTORY_OWNERS=(root:root root:root root:root root:kvm-dispatcher root:kvm-dispatcher kvm-dispatcher:kvm-dispatcher kvm-dispatcher:kvm-dispatcher)

path_at_root() {
    local path=$1
    if [[ $INSTALL_ROOT == / ]]; then
        printf '%s' "$path"
    else
        printf '%s%s' "$INSTALL_ROOT" "$path"
    fi
}

metadata_matches() {
    local path=$1 mode=$2 owner_group=$3 actual_mode actual_owner_group
    local actual_mode_value expected_mode_value
    actual_mode=$(stat -c '%a' -- "$path") || return 1
    actual_mode_value=$((8#$actual_mode))
    expected_mode_value=$((8#$mode))
    if (( actual_mode_value != expected_mode_value )); then
        return 1
    fi
    if (( TEST_ROOT == 0 )); then
        actual_owner_group=$(stat -c '%U:%G' -- "$path") || return 1
        [[ $actual_owner_group == "$owner_group" ]] || return 1
    fi
    return 0
}

check_directory_destination() {
    local path=$1 mode=$2 owner_group=$3 dest
    dest=$(path_at_root "$path")
    if [[ ! -e $dest && ! -L $dest ]]; then
        printf '  available: %s\n' "$path"
        return 0
    fi
    if [[ -L $dest || ! -d $dest ]]; then
        fail "Destination type collision at $path."
        return 1
    fi
    if ! metadata_matches "$dest" "$mode" "$owner_group"; then
        fail "Existing directory differs from expected owner/mode at $path."
        return 1
    fi
    printf '  identical directory: %s\n' "$path"
}

check_file_destination() {
    local source_rel=$1 path=$2 mode=$3 owner_group=$4 kind=${5:-source}
    local dest source
    dest=$(path_at_root "$path")
    source="$canonical_checkout/$source_rel"
    if [[ ! -e $dest && ! -L $dest ]]; then
        printf '  available: %s\n' "$path"
        return 0
    fi
    if [[ -L $dest || ! -f $dest ]]; then
        fail "Destination type collision at $path."
        return 1
    fi
    if [[ $kind == credential ]]; then
        if [[ ! -s $dest ]] || ! metadata_matches "$dest" "$mode" "$owner_group"; then
            fail "Existing encrypted credential has unexpected type, owner, mode, or size at $path. It will not be overwritten."
            return 1
        fi
        printf '  encrypted credential already present: %s (contents not read)\n' "$path"
        return 0
    fi
    if ! cmp -s -- "$source" "$dest"; then
        fail "Existing file differs from checkout source at $path. It will not be overwritten."
        return 1
    fi
    if ! metadata_matches "$dest" "$mode" "$owner_group"; then
        fail "Existing file has unexpected owner or mode at $path. It will not be overwritten."
        return 1
    fi
    printf '  identical file: %s\n' "$path"
}

print_config_ids() {
    local config="$canonical_checkout/$CONFIG_SOURCE"
    awk -F= '
        $1 == "KVM_DISPATCHER_APP_ID" ||
        $1 == "KVM_DISPATCHER_INSTALLATION_QNIAPP" ||
        $1 == "KVM_DISPATCHER_INSTALLATION_QORRAQ" { printf "  %s=%s\n", $1, $2 }
    ' "$config"
}

confirm_action() {
    local answer
    if (( TEST_ROOT == 1 )); then
        printf 'TEST ROOT: automatically confirming file-placement test only.\n'
        return 0
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        fail 'A controlling terminal is required to confirm each stage.'
        return 1
    fi
    printf 'Continue with this exact action? [y/N] ' >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
        printf 'Cancelled.\n' >/dev/tty
        return 1
    fi
    if [[ $answer != y && $answer != Y ]]; then
        printf 'Cancelled.\n' >/dev/tty
        return 1
    fi
}

audit_event() {
    local stage=$1 result=$2
    local message="event=stage-completed stage=$stage result=$result head=$SOURCE_HEAD"
    if (( TEST_ROOT == 1 )); then
        local audit_file
        audit_file=$(path_at_root /var/log/kvm-dispatcher-install-wizard.audit)
        mkdir -p -- "$(dirname -- "$audit_file")" || return 1
        printf '%s\n' "$message" >> "$audit_file" || return 1
    else
        logger --tag kvm-dispatcher-install-wizard -- "$message" || return 1
    fi
}

check_checkout_clean() {
    local checkout_root status
    checkout_root=$(git_read rev-parse --show-toplevel 2>/dev/null) || {
        fail 'The source is not a Git checkout.'
        return 1
    }
    if [[ $(readlink -f -- "$checkout_root") != "$canonical_checkout" ]]; then
        fail 'The wizard source and Git checkout root do not match.'
        return 1
    fi
    if (( TEST_ROOT == 1 )); then
        printf '  test checkout root verified; clean-tree check skipped for this fake-root test.\n'
        return 0
    fi
    status=$(git_read status --porcelain --untracked-files=all 2>/dev/null) || {
        fail 'Could not inspect Git checkout status.'
        return 1
    }
    if [[ -n $status ]]; then
        fail 'The source checkout is not clean. Commit or remove local changes before installing.'
        return 1
    fi
    printf '  clean checkout: %s\n' "$canonical_checkout"
}

preflight_checks() {
    local failures=0 command_name i group passwd_entry group_entry uid gid home shell
    printf 'Checking host prerequisites, checkout, groups, and every managed destination...\n'
    if (( EUID != 0 && TEST_ROOT == 0 )); then
        fail 'Run the install wizard as root.'
        failures=1
    fi
    for command_name in git install systemctl systemd-run systemd-creds systemd-sysusers systemd-tmpfiles pkaction getent usermod jq curl openssl logger stat cmp find awk date readlink cp chmod mkdir; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            fail "Required command is missing: $command_name"
            failures=1
        fi
    done
    if ! check_checkout_clean; then
        failures=1
    fi
    printf '  Git HEAD: %s\n' "$SOURCE_HEAD"
    if (( TEST_ROOT == 0 )); then
        local parent_path parent_dest
        for parent_path in /opt /etc/systemd/system /etc/polkit-1/rules.d /etc/sysusers.d /etc/tmpfiles.d; do
            parent_dest=$(path_at_root "$parent_path")
            if [[ -L $parent_dest || ! -d $parent_dest ]]; then
                fail "Required destination parent is missing or not a directory: $parent_path"
                failures=1
            fi
        done
    fi

    for group in qa2-runner-host qoral-runner-host; do
        if getent group "$group" >/dev/null 2>&1; then
            printf '  required job group %s: present\n' "$group"
        else
            printf '  required job group %s: MISSING (will not be created)\n' "$group"
        fi
    done

    passwd_entry=$(getent passwd kvm-dispatcher 2>/dev/null || true)
    group_entry=$(getent group kvm-dispatcher 2>/dev/null || true)
    if [[ -n $passwd_entry || -n $group_entry ]]; then
        if [[ -z $passwd_entry || -z $group_entry ]]; then
            fail 'Only one of the kvm-dispatcher user/group exists; inspect this partial identity before continuing.'
            failures=1
        else
            IFS=: read -r _ _ uid gid _ home shell <<< "$passwd_entry"
            if [[ $home != /var/lib/kvm-dispatcher || $shell != /usr/bin/nologin ]]; then
                fail 'Existing kvm-dispatcher account has unexpected home or shell.'
                failures=1
            else
                printf '  kvm-dispatcher identity: existing expected account (uid=%s gid=%s)\n' "$uid" "$gid"
            fi
        fi
    else
        printf '  kvm-dispatcher identity: not yet created\n'
    fi

    for i in "${!DIRECTORY_PATHS[@]}"; do
        if ! check_directory_destination "${DIRECTORY_PATHS[$i]}" "${DIRECTORY_MODES[$i]}" "${DIRECTORY_OWNERS[$i]}"; then
            failures=1
        fi
    done
    for i in "${!CORE_SOURCES[@]}"; do
        if ! check_file_destination "${CORE_SOURCES[$i]}" "${CORE_DESTINATIONS[$i]}" "${CORE_MODES[$i]}" "${CORE_OWNERS[$i]}"; then
            failures=1
        fi
    done
    if ! check_file_destination "$CONFIG_SOURCE" "$CONFIG_DESTINATION" 0640 root:kvm-dispatcher; then
        failures=1
    fi
    if ! check_file_destination '' "$CREDENTIAL_DESTINATION" 0600 root:root credential; then
        failures=1
    fi

    if (( failures != 0 )); then
        fail 'Preflight found one or more problems. No destination was changed.'
        return 1
    fi
    printf 'Preflight checks passed.\n'
}

print_core_file_plan() {
    local i source destination
    for i in "${!CORE_SOURCES[@]}"; do
        source=${CORE_SOURCES[$i]}
        destination=${CORE_DESTINATIONS[$i]}
        printf '  %s -> %s (root:%s, %s)\n' "$source" "$destination" "${CORE_OWNERS[$i]#*:}" "${CORE_MODES[$i]}"
    done
}

create_managed_directory() {
    local path=$1 mode=$2 owner_group=$3 dest owner group
    dest=$(path_at_root "$path")
    if [[ -e $dest || -L $dest ]]; then
        check_directory_destination "$path" "$mode" "$owner_group" || return 1
        return 0
    fi
    owner=${owner_group%%:*}
    group=${owner_group#*:}
    if (( TEST_ROOT == 1 )); then
        mkdir -p -- "$dest" || return 1
        chmod "$mode" -- "$dest" || return 1
    else
        install -d -o "$owner" -g "$group" -m "$mode" -- "$dest" || return 1
    fi
}

place_file() {
    local source_rel=$1 path=$2 mode=$3 owner_group=$4 dest source owner group
    source="$canonical_checkout/$source_rel"
    dest=$(path_at_root "$path")
    if [[ -e $dest || -L $dest ]]; then
        check_file_destination "$source_rel" "$path" "$mode" "$owner_group" || return 1
        printf '  skipped identical file: %s\n' "$path"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")" || return 1
    owner=${owner_group%%:*}
    group=${owner_group#*:}
    if (( TEST_ROOT == 1 )); then
        cp -- "$source" "$dest" || return 1
        chmod "$mode" -- "$dest" || return 1
    else
        install -o "$owner" -g "$group" -m "$mode" -- "$source" "$dest" || return 1
    fi
    printf '  installed: %s\n' "$path"
}

stage_preflight() {
    preflight_checks
}

stage_install() {
    local i
    for i in "${!DIRECTORY_PATHS[@]}"; do
        case ${DIRECTORY_PATHS[$i]} in
            /opt/kvm-dispatcher|/opt/kvm-dispatcher/host|/etc/systemd/system/kvm-dispatcher.service.d)
                create_managed_directory "${DIRECTORY_PATHS[$i]}" "${DIRECTORY_MODES[$i]}" "${DIRECTORY_OWNERS[$i]}" || return 1
                ;;
        esac
    done
    for i in "${!CORE_SOURCES[@]}"; do
        place_file "${CORE_SOURCES[$i]}" "${CORE_DESTINATIONS[$i]}" "${CORE_MODES[$i]}" "${CORE_OWNERS[$i]}" || return 1
    done
}

ensure_config_file() {
    place_file "$CONFIG_SOURCE" "$CONFIG_DESTINATION" 0640 root:kvm-dispatcher
}

stage_identity() {
    local group
    local sysusers="$canonical_checkout/host/systemd/kvm-dispatcher.sysusers.conf"
    local tmpfiles="$canonical_checkout/host/systemd/kvm-dispatcher.tmpfiles.conf"
    local installed_sysusers installed_tmpfiles
    installed_sysusers=$(path_at_root /etc/sysusers.d/kvm-dispatcher.conf)
    installed_tmpfiles=$(path_at_root /etc/tmpfiles.d/kvm-dispatcher.conf)
    if ! cmp -s -- "$sysusers" "$installed_sysusers" || ! cmp -s -- "$tmpfiles" "$installed_tmpfiles"; then
        fail 'Install the core files before creating the dispatcher identity and directories.'
        return 1
    fi
    systemd-sysusers || { fail 'systemd-sysusers failed.'; return 1; }
    systemd-tmpfiles --create || { fail 'systemd-tmpfiles --create failed.'; return 1; }
    for group in qa2-runner-host qoral-runner-host; do
        if getent group "$group" >/dev/null 2>&1; then
            usermod -aG "$group" kvm-dispatcher || { fail "usermod failed for existing group $group."; return 1; }
            printf '  added kvm-dispatcher to %s\n' "$group"
        else
            printf '  skipped missing group %s (it will not be created)\n' "$group"
        fi
    done
    ensure_config_file || return 1
    systemctl daemon-reload || { fail 'systemctl daemon-reload failed.'; return 1; }
}

credential_is_ready() {
    local path owner_group
    path=$(path_at_root "$CREDENTIAL_DESTINATION")
    [[ -e $path || -L $path ]] || return 1
    if [[ -L $path || ! -f $path || ! -s $path ]]; then
        fail 'The existing encrypted credential is not a non-empty regular file; refusing to replace it.'
        return 2
    fi
    if ! metadata_matches "$path" 0600 root:root; then
        fail 'The existing encrypted credential has unexpected owner or mode; refusing to replace it.'
        return 2
    fi
    owner_group=$(stat -c '%U:%G' -- "$path" 2>/dev/null || true)
    printf 'Encrypted credential is already installed (%s, contents not read).\n' "$owner_group"
    return 0
}

stage_pem() {
    local credential_status
    if credential_is_ready; then
        printf 'Skipping PEM input; the encrypted credential will remain unchanged.\n'
        return 0
    else
        credential_status=$?
        if (( credential_status == 2 )); then
            return 1
        fi
    fi
    local config_path wizard_path
    config_path=$(path_at_root "$CONFIG_DESTINATION")
    wizard_path=$(path_at_root /opt/kvm-dispatcher/host/kvm_dispatcher_host_wizard.sh)
    if [[ ! -f $config_path || ! -x $wizard_path ]]; then
        fail 'Install the core files and dispatcher.conf before entering the PEM.'
        return 1
    fi
    "$wizard_path"
}

service_is_inactive_disabled() {
    local output active state
    if ! output=$(systemctl show -p ActiveState -p UnitFileState kvm-dispatcher.service 2>&1); then
        fail "Could not inspect kvm-dispatcher.service: $output"
        return 1
    fi
    active=$(awk -F= '$1 == "ActiveState" { print $2 }' <<< "$output")
    state=$(awk -F= '$1 == "UnitFileState" { print $2 }' <<< "$output")
    if [[ $active != inactive || $state != disabled ]]; then
        fail "kvm-dispatcher.service must remain inactive/disabled (found ActiveState=${active:-unknown}, UnitFileState=${state:-unknown}); the wizard will not change it."
        return 1
    fi
    printf '  kvm-dispatcher.service: ActiveState=inactive UnitFileState=disabled\n'
}

verification_fail_summary() {
    printf '\nVerification summary: FAIL\n'
    printf 'Do not enable the service. Inspect the transient unit journal and status.json.\n'
}

stage_verify() {
    local repos_dir status_file found_configs probe_started status_mtime_before status_mtime_after
    local failed=0
    repos_dir=$(path_at_root /etc/kvm-dispatcher/repos.d)
    status_file=$(path_at_root /var/lib/kvm-dispatcher/status.json)
    if [[ ! -d $repos_dir ]]; then
        fail "Adapter directory is missing: $repos_dir"
        verification_fail_summary
        return 1
    fi
    found_configs=$(find "$repos_dir" -maxdepth 1 -type f -name '*.conf' -print -quit) || {
        fail "Could not inspect $repos_dir."
        verification_fail_summary
        return 1
    }
    if [[ -n $found_configs ]]; then
        fail "Adapter config exists at $found_configs; the no-adapter probe will not run."
        verification_fail_summary
        return 1
    fi
    printf '  repos.d contains zero *.conf adapter files.\n'
    if ! service_is_inactive_disabled; then
        verification_fail_summary
        return 1
    fi

    if [[ -e $status_file ]]; then
        status_mtime_before=$(stat -c '%y' -- "$status_file") || {
            fail 'Could not read the current status.json timestamp.'
            verification_fail_summary
            return 1
        }
    else
        status_mtime_before=missing
    fi
    probe_started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! systemd-run \
        --unit=kvm-dispatcher-token-probe \
        --wait --pipe --collect \
        --property=User=kvm-dispatcher \
        --property=Group=kvm-dispatcher \
        --property=SupplementaryGroups=systemd-journal \
        --property=EnvironmentFile=/etc/kvm-dispatcher/dispatcher.conf \
        --property=Environment=KVM_DISPATCHER_CONFIG=/etc/kvm-dispatcher/dispatcher.conf \
        --property=Environment=KVM_DISPATCHER_ONCE=1 \
        --property=LoadCredentialEncrypted=app-key:/etc/kvm-dispatcher/app-key.cred \
        /opt/kvm-dispatcher/host/kvm_dispatcher.sh; then
        fail 'The transient token-probe unit failed. Check its journal; the persistent service was not started.'
        failed=1
    fi

    if [[ -r $status_file ]]; then
        status_mtime_after=$(stat -c '%y' -- "$status_file") || status_mtime_after=missing
        if [[ $status_mtime_before == "$status_mtime_after" ]]; then
            fail 'status.json was not refreshed by this probe; refusing to accept stale HTTP results.'
            failed=1
        fi
        if jq -e --arg started "$probe_started" '
            .last_poll["qniapp/qa2"].http == "200" and
            .last_poll["qorraq/qoral"].http == "200" and
            .last_poll["qniapp/qa2"].at >= $started and
            .last_poll["qorraq/qoral"].at >= $started
        ' "$status_file" >/dev/null 2>&1; then
            printf '  qniapp/qa2: HTTP 200\n  qorraq/qoral: HTTP 200\n'
        else
            printf '  observed HTTP status: qniapp/qa2=%s qorraq/qoral=%s\n' \
                "$(jq -r '.last_poll["qniapp/qa2"].http // "missing"' "$status_file" 2>/dev/null || printf missing)" \
                "$(jq -r '.last_poll["qorraq/qoral"].http // "missing"' "$status_file" 2>/dev/null || printf missing)"
            fail 'status.json does not show fresh HTTP 200 results for both repositories.'
            failed=1
        fi
    else
        fail 'status.json was not created by the probe.'
        failed=1
    fi

    if ! service_is_inactive_disabled; then
        failed=1
    fi
    if (( failed != 0 )); then
        verification_fail_summary
        return 1
    fi
    printf '\nVerification summary: PASS\n'
}

stage_action_text() {
    case $1 in
        preflight)
            printf '%s\n' \
                'Read-only preflight: verify root access, Git checkout cleanliness, required systemd/systemd-creds/polkit commands, all managed destinations, and the two job groups.' \
                "Checkout: $canonical_checkout" \
                "HEAD: $SOURCE_HEAD" \
                'Missing job groups will be reported, never created. No files or services will be changed.'
            ;;
        install)
            printf '%s\n' \
                'Install the dispatcher core files from this checkout. Identical files are skipped; differing files are refused.'
            print_core_file_plan
            ;;
        identity)
            printf '%s\n' \
                'Run systemd-sysusers and systemd-tmpfiles --create; append kvm-dispatcher to each existing job group; install dispatcher.conf from the example; run systemctl daemon-reload.' \
                'Commands:' \
                '  systemd-sysusers' \
                '  systemd-tmpfiles --create' \
                '  usermod -aG qa2-runner-host kvm-dispatcher (if the group exists)' \
                '  usermod -aG qoral-runner-host kvm-dispatcher (if the group exists)' \
                '  install -o root -g kvm-dispatcher -m 0640 host/dispatcher.conf.example /etc/kvm-dispatcher/dispatcher.conf' \
                '  systemctl daemon-reload' \
                'This will not create either job group and will not enable or start any service.' \
                'App and installation IDs from dispatcher.conf.example:'
            print_config_ids
            ;;
        pem)
            printf '%s\n' \
                'Run the installed host PEM wizard. It reads the PEM with terminal echo disabled, sends it only to systemd-creds via stdin, and installs only app-key.cred as root:root 0600.' \
                'The installed host wizard will ask for its own confirmation. No service will be enabled or started.'
            ;;
        verify)
            printf '%s\n' \
                'Assert repos.d has no *.conf files; run this one-shot transient probe; require fresh HTTP 200 for qniapp/qa2 and qorraq/qoral; assert kvm-dispatcher.service remains inactive/disabled.' \
                'Persistent kvm-dispatcher.service is never enabled or started.' \
                'Exact transient command:' \
                'systemd-run --unit=kvm-dispatcher-token-probe --wait --pipe --collect --property=User=kvm-dispatcher --property=Group=kvm-dispatcher --property=SupplementaryGroups=systemd-journal --property=EnvironmentFile=/etc/kvm-dispatcher/dispatcher.conf --property=Environment=KVM_DISPATCHER_CONFIG=/etc/kvm-dispatcher/dispatcher.conf --property=Environment=KVM_DISPATCHER_ONCE=1 --property=LoadCredentialEncrypted=app-key:/etc/kvm-dispatcher/app-key.cred /opt/kvm-dispatcher/host/kvm_dispatcher.sh'
            ;;
        rollback)
            printf '%s\n' \
                'Stop only kvm-dispatcher-token-probe.service; remove the dispatcher unit/drop-in, polkit/sysusers/tmpfiles files, /opt/kvm-dispatcher, /etc/kvm-dispatcher, and /run/kvm-dispatcher; remove the kvm-dispatcher user/home and group if present; daemon-reload.' \
                'If /var/lib/kvm-dispatcher remains after userdel --remove, remove that runbook-created state directory as specified in the rollback.' \
                'qa2-runner-host, qoral-runner-host, qa2-runner.service, and qoral-runner.service are not rollback targets.'
            ;;
    esac
}

run_confirmed_stage() {
    local name=$1 action=$2 result
    printf '\n=== Stage: %s ===\n' "$name"
    stage_action_text "$name"
    if ! confirm_action; then
        audit_event "$name" cancelled || true
        return 1
    fi
    if "$action"; then
        audit_event "$name" passed || { fail "Could not write the $name audit event to the journal."; return 1; }
        return 0
    else
        result=$?
        audit_event "$name" failed || fail "Could not write the failed $name audit event to the journal."
        return "$result"
    fi
}

rollback_precheck() {
    local repos_dir entry
    if (( EUID != 0 )); then
        fail 'Rollback must be run as root.'
        return 1
    fi
    for entry in systemctl getent userdel groupdel rm rmdir logger find; do
        if ! command -v "$entry" >/dev/null 2>&1; then
            fail "Required rollback command is missing: $entry"
            return 1
        fi
    done
    repos_dir=$(path_at_root /etc/kvm-dispatcher/repos.d)
    if [[ -L $repos_dir ]]; then
        fail 'repos.d is a symlink; refusing rollback.'
        return 1
    fi
    if [[ -d $repos_dir ]]; then
        entry=$(find "$repos_dir" -mindepth 1 -maxdepth 1 -print -quit) || {
            fail 'Could not inspect repos.d; refusing rollback.'
            return 1
        }
        if [[ -n $entry ]]; then
            fail "repos.d is non-empty ($entry); refusing rollback. Inspect it and remove adapters manually before retrying."
            return 1
        fi
    elif [[ -e $repos_dir ]]; then
        fail 'repos.d exists but is not a directory; refusing rollback.'
        return 1
    fi
    if ! service_is_inactive_disabled; then
        fail 'Stop and disable the persistent dispatcher manually before rollback; this wizard will not do so.'
        return 1
    fi
    return 0
}

rollback_action() {
    local path
    systemctl stop kvm-dispatcher-token-probe.service 2>/dev/null || true
    rm -f -- "$(path_at_root /etc/systemd/system/kvm-dispatcher.service)" || return 1
    rm -f -- "$(path_at_root /etc/systemd/system/kvm-dispatcher.service.d/10-isolation.conf)" || return 1
    rmdir "$(path_at_root /etc/systemd/system/kvm-dispatcher.service.d)" 2>/dev/null || true
    rm -f -- "$(path_at_root /etc/polkit-1/rules.d/50-kvm-dispatcher.rules)" || return 1
    rm -f -- "$(path_at_root /etc/sysusers.d/kvm-dispatcher.conf)" || return 1
    rm -f -- "$(path_at_root /etc/tmpfiles.d/kvm-dispatcher.conf)" || return 1
    rm -rf -- "$(path_at_root /opt/kvm-dispatcher)" "$(path_at_root /etc/kvm-dispatcher)" "$(path_at_root /run/kvm-dispatcher)" || return 1
    if getent passwd kvm-dispatcher >/dev/null 2>&1; then
        userdel --remove kvm-dispatcher || return 1
    fi
    if getent group kvm-dispatcher >/dev/null 2>&1; then
        groupdel kvm-dispatcher || return 1
    fi
    path=$(path_at_root /var/lib/kvm-dispatcher)
    if [[ -e $path || -L $path ]]; then
        rm -rf -- "$path" || return 1
    fi
    systemctl daemon-reload || return 1
}

run_rollback() {
    printf '\n=== Rollback precheck ===\n'
    if ! rollback_precheck; then
        audit_event rollback refused || true
        return 1
    fi
    printf 'Rollback prechecks passed.\n'
    printf '\n=== Stage: rollback ===\n'
    stage_action_text rollback
    if ! confirm_action; then
        audit_event rollback cancelled || true
        return 1
    fi
    if rollback_action; then
        audit_event rollback passed || { fail 'Could not write the rollback audit event to the journal.'; return 1; }
        printf 'Rollback completed. qa2-runner.service and qoral-runner.service were not changed.\n'
    else
        local result=$?
        audit_event rollback failed || fail 'Could not write the failed rollback audit event to the journal.'
        return "$result"
    fi
}

if (( TEST_ROOT == 0 )); then
    if (( EUID != 0 )); then
        fail 'Run this wizard as root.'
        exit 1
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        fail 'A controlling terminal is required.'
        exit 1
    fi
fi

if [[ $MODE == rollback ]]; then
    run_rollback
    exit $?
fi

if [[ $MODE == all ]]; then
    run_confirmed_stage preflight stage_preflight || exit $?
    run_confirmed_stage install stage_install || exit $?
    run_confirmed_stage identity stage_identity || exit $?
    run_confirmed_stage pem stage_pem || exit $?
    run_confirmed_stage verify stage_verify || exit $?
    exit 0
fi

if [[ $SELECTED_STAGE != preflight ]]; then
    run_confirmed_stage preflight stage_preflight || exit $?
fi
case $SELECTED_STAGE in
    preflight) run_confirmed_stage preflight stage_preflight ;;
    install) run_confirmed_stage install stage_install ;;
    identity) run_confirmed_stage identity stage_identity ;;
    pem) run_confirmed_stage pem stage_pem ;;
    verify) run_confirmed_stage verify stage_verify ;;
esac
