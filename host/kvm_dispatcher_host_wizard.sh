#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

CREDENTIAL_DIR=${KVM_DISPATCHER_CREDENTIAL_DIR:-/etc/kvm-dispatcher}
CREDENTIAL_FILE="$CREDENTIAL_DIR/app-key.cred"
tmp_dir=
terminal_echo_disabled=0

restore_terminal() {
    if (( terminal_echo_disabled == 1 )); then
        stty echo </dev/tty 2>/dev/null || true
        terminal_echo_disabled=0
        printf '\n' >/dev/tty 2>/dev/null || true
    fi
}
cleanup() {
    restore_terminal
    if [[ -n $tmp_dir ]]; then
        rm -rf -- "$tmp_dir"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if (( EUID != 0 )); then
    printf 'Run this wizard as root.\n' >&2
    exit 1
fi
if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'A controlling terminal is required.\n' >&2
    exit 1
fi
command -v systemd-creds >/dev/null || { printf 'systemd-creds is required.\n' >&2; exit 1; }
command -v logger >/dev/null || { printf 'logger is required for the audit record.\n' >&2; exit 1; }

printf '%s\n' \
    'KVM dispatcher GitHub App key setup' \
    "Encrypted credential: $CREDENTIAL_FILE" \
    'The PEM is entered with terminal echo disabled and passed only on stdin to systemd-creds.' \
    'No service is enabled or started by this wizard.' \
    '' \
    'This PEM stage installs only the encrypted credential. Return to the install wizard' \
    'to verify both installations before adding adapters or enabling the dispatcher.' >/dev/tty
printf 'Continue? [y/N] ' >/dev/tty
IFS= read -r answer </dev/tty
[[ $answer == y || $answer == Y ]] || { printf 'Cancelled.\n' >/dev/tty; exit 1; }

getent group kvm-dispatcher >/dev/null || { printf 'Install kvm-dispatcher.sysusers.conf before running this wizard.\n' >&2; exit 1; }
if [[ -e $CREDENTIAL_FILE || -L $CREDENTIAL_FILE ]]; then
    printf 'Refusing to overwrite an existing encrypted credential: %s\n' "$CREDENTIAL_FILE" >&2
    exit 1
fi
install -d -o root -g kvm-dispatcher -m 0750 "$CREDENTIAL_DIR"
tmp_dir=$(mktemp -d "$CREDENTIAL_DIR/.app-key-wizard.XXXXXX")
chmod 0700 "$tmp_dir"
printf '%s\n' \
    'Paste the GitHub App PEM now. Input is hidden. Press Ctrl-D after the final line.' \
    'The key is not written as plaintext to disk.' >/dev/tty
stty -echo </dev/tty
terminal_echo_disabled=1
if systemd-creds encrypt --name=app-key - "$tmp_dir/app-key.cred" </dev/tty; then
    restore_terminal
else
    restore_terminal
    printf 'systemd-creds could not encrypt the key. No credential was installed.\n' >&2
    exit 1
fi

install -o root -g root -m 0600 "$tmp_dir/app-key.cred" "$CREDENTIAL_FILE"
logger --tag kvm-dispatcher-host-wizard "event=app-key-encrypted path=$CREDENTIAL_FILE"
printf 'Encrypted App key installed. Continue with no-adapter verification before adding adapters.\n' >/dev/tty
