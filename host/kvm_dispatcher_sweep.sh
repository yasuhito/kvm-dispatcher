#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=host/kvm_dispatcher_lib.sh
source "$SCRIPT_DIR/kvm_dispatcher_lib.sh"

kvd_load_config
kvd_sweep_startup
kvd_write_status
