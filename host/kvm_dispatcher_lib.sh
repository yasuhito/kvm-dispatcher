#!/usr/bin/env bash
# Shared configuration, GitHub API, state, and scheduling helpers for kvm-dispatcher.

set -o errexit -o nounset -o pipefail

KVD_API_URL=${KVD_API_URL:-https://api.github.com}
KVD_API_VERSION=2022-11-28
KVD_HTTP=000
KVD_BODY=
KVD_TOKEN=
KVD_QUEUE='[]'
KVD_JOB_MAP='{}'
KVD_LAST_POLL_JSON='{}'
declare -ag KVD_ADAPTER_NAMES=()
declare -Ag KVD_A_REPO=()
declare -Ag KVD_A_INSTALLATION=()
declare -Ag KVD_A_LABELS=()
declare -Ag KVD_A_UNIT=()
declare -Ag KVD_A_PREFIX=()
declare -Ag KVD_A_MAX_SECONDS=()
declare -Ag KVD_A_MEMORY=()
declare -Ag KVD_A_CONCURRENCY=()
declare -Ag KVD_REPO_OK=()
declare -Ag KVD_NEXT_POLL=()
declare -Ag KVD_POLL_FAILURES=()
declare -Ag KVD_PROBE_NEXT_POLL=()
declare -Ag KVD_PROBE_FAILURES=()
declare -ag KVD_INSTALLATIONS=()

kvd_now() {
    if [[ -n ${KVM_DISPATCHER_TEST_NOW:-} ]]; then
        printf '%s\n' "$KVM_DISPATCHER_TEST_NOW"
    else
        date +%s
    fi
}

kvd_iso_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

kvd_log() {
    printf 'event=%s\n' "$*"
}

kvd_die() {
    printf 'kvm-dispatcher: %s\n' "$*" >&2
    return 1
}

kvd_positive_integer() {
    [[ $1 =~ ^[1-9][0-9]*$ ]]
}

kvd_load_config() {
    local config_file=${KVM_DISPATCHER_CONFIG:-/etc/kvm-dispatcher/dispatcher.conf}
    [[ -r $config_file ]] || kvd_die "configuration is not readable: $config_file"

    # Config files are root-owned shell assignments, matching the runner adapters.
    # shellcheck source=/dev/null
    source "$config_file"

    : "${KVM_DISPATCHER_POLL_SECONDS:=20}"
    : "${KVM_DISPATCHER_CAPACITY_MIB:=12288}"
    : "${KVM_DISPATCHER_PRIORITY:=}"
    : "${KVM_DISPATCHER_REPOS_DIR:=/etc/kvm-dispatcher/repos.d}"
    : "${KVM_DISPATCHER_STATE_DIR:=/run/kvm-dispatcher}"
    : "${KVM_DISPATCHER_STATUS_FILE:=/var/lib/kvm-dispatcher/status.json}"
    : "${KVM_DISPATCHER_APP_ID:=}"
    : "${KVM_DISPATCHER_INSTALLATIONS:=}"

    kvd_positive_integer "$KVM_DISPATCHER_POLL_SECONDS" || kvd_die 'KVM_DISPATCHER_POLL_SECONDS must be a positive integer'
    kvd_positive_integer "$KVM_DISPATCHER_CAPACITY_MIB" || kvd_die 'KVM_DISPATCHER_CAPACITY_MIB must be a positive integer'
    [[ $KVM_DISPATCHER_APP_ID =~ ^[0-9]+$ ]] || kvd_die 'KVM_DISPATCHER_APP_ID must be a numeric GitHub App ID'

    KVD_STATE_DIR=$KVM_DISPATCHER_STATE_DIR
    KVD_STATUS_FILE=$KVM_DISPATCHER_STATUS_FILE
    KVD_STATUS_DIR=$(dirname "$KVD_STATUS_FILE")
    KVD_ATTEMPT_DIR="$KVD_STATUS_DIR/attempts"
    KVD_REPOS_DIR=$KVM_DISPATCHER_REPOS_DIR
    KVD_CAPACITY_MIB=$KVM_DISPATCHER_CAPACITY_MIB
    KVD_POLL_SECONDS=$KVM_DISPATCHER_POLL_SECONDS
    KVD_PRIORITY=$KVM_DISPATCHER_PRIORITY
    KVD_APP_ID=$KVM_DISPATCHER_APP_ID
    KVD_INSTALLATIONS=()
    KVD_PROBE_NEXT_POLL=()
    KVD_PROBE_FAILURES=()
    local installation
    read -r -a KVD_INSTALLATIONS <<< "${KVM_DISPATCHER_INSTALLATIONS//,/ }"
    for installation in "${KVD_INSTALLATIONS[@]}"; do
        [[ $installation =~ ^[a-zA-Z0-9_-]+$ ]] || kvd_die "invalid installation alias: $installation"
        KVD_PROBE_NEXT_POLL[$installation]=0
        KVD_PROBE_FAILURES[$installation]=0
    done

    mkdir -p "$KVD_STATE_DIR/jobs" "$KVD_STATE_DIR/tokens" "$KVD_ATTEMPT_DIR"
    chmod 0700 "$KVD_STATE_DIR" "$KVD_STATE_DIR/jobs" "$KVD_STATE_DIR/tokens" "$KVD_ATTEMPT_DIR"
    chmod 0755 "$KVD_STATUS_DIR"

    KVD_ADAPTER_NAMES=()
    KVD_A_REPO=()
    KVD_A_INSTALLATION=()
    KVD_A_LABELS=()
    KVD_A_UNIT=()
    KVD_A_PREFIX=()
    KVD_A_MAX_SECONDS=()
    KVD_A_MEMORY=()
    KVD_A_CONCURRENCY=()

    local conf name
    while IFS= read -r conf; do
        [[ -n $conf ]] || continue
        name=${conf##*/}
        name=${name%.conf}
        [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || kvd_die "invalid adapter filename: $conf"

        local KVM_DISPATCHER_REPO='' KVM_DISPATCHER_INSTALLATION='' KVM_DISPATCHER_LABELS=''
        local KVM_DISPATCHER_UNIT='' KVM_DISPATCHER_RUNNER_NAME_PREFIX=''
        local KVM_DISPATCHER_MAX_UNIT_SECONDS='' KVM_DISPATCHER_MEMORY_MIB='' KVM_DISPATCHER_CONCURRENCY=''
        # shellcheck source=/dev/null
        source "$conf"

        [[ $KVM_DISPATCHER_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || kvd_die "invalid repository in $conf"
        [[ $KVM_DISPATCHER_INSTALLATION =~ ^[a-zA-Z0-9_-]+$ ]] || kvd_die "invalid installation alias in $conf"
        [[ $KVM_DISPATCHER_LABELS =~ ^[A-Za-z0-9_.-]+([,[:space:]]+[A-Za-z0-9_.-]+)*$ ]] || kvd_die "invalid labels in $conf"
        [[ $KVM_DISPATCHER_UNIT =~ ^(qa2|qoral)-runner-job@$ ]] || kvd_die "unit prefix is not permitted in $conf"
        [[ $KVM_DISPATCHER_RUNNER_NAME_PREFIX =~ ^[A-Za-z0-9_.-]+$ ]] || kvd_die "invalid runner name prefix in $conf"
        kvd_positive_integer "$KVM_DISPATCHER_MAX_UNIT_SECONDS" || kvd_die "invalid max unit time in $conf"
        kvd_positive_integer "$KVM_DISPATCHER_MEMORY_MIB" || kvd_die "invalid memory in $conf"
        kvd_positive_integer "$KVM_DISPATCHER_CONCURRENCY" || kvd_die "invalid concurrency in $conf"
        [[ -z ${KVD_A_REPO[$name]+present} ]] || kvd_die "duplicate adapter name: $name"

        KVD_ADAPTER_NAMES+=("$name")
        KVD_A_REPO[$name]=$KVM_DISPATCHER_REPO
        KVD_A_INSTALLATION[$name]=$KVM_DISPATCHER_INSTALLATION
        KVD_A_LABELS[$name]=$KVM_DISPATCHER_LABELS
        KVD_A_UNIT[$name]=$KVM_DISPATCHER_UNIT
        KVD_A_PREFIX[$name]=$KVM_DISPATCHER_RUNNER_NAME_PREFIX
        KVD_A_MAX_SECONDS[$name]=$KVM_DISPATCHER_MAX_UNIT_SECONDS
        KVD_A_MEMORY[$name]=$KVM_DISPATCHER_MEMORY_MIB
        KVD_A_CONCURRENCY[$name]=$KVM_DISPATCHER_CONCURRENCY
        KVD_NEXT_POLL[$name]=0
        KVD_POLL_FAILURES[$name]=0
        KVD_REPO_OK[$name]=0
    done < <(find "$KVD_REPOS_DIR" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | LC_ALL=C sort)

    [[ ${#KVD_ADAPTER_NAMES[@]} -gt 0 ]] || kvd_log 'dispatcher-ready adapters=0'
}

kvd_installation_id() {
    local installation=$1 key
    key=${installation^^}
    key=${key//-/_}
    local variable="KVM_DISPATCHER_INSTALLATION_${key}"
    local value=${!variable:-}
    [[ $value =~ ^[0-9]+$ ]] || kvd_die "missing numeric installation ID for $installation"
    printf '%s\n' "$value"
}

kvd_b64url() {
    printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '=\n'
}

kvd_make_jwt() {
    local now=$1 key_file header payload unsigned signature
    key_file=${CREDENTIALS_DIRECTORY:-}/app-key
    [[ -r $key_file ]] || kvd_die 'GitHub App key credential is unavailable'
    header=$(kvd_b64url '{"alg":"RS256","typ":"JWT"}')
    payload=$(jq -cn --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" --arg iss "$KVD_APP_ID" '{iat:$iat,exp:$exp,iss:$iss}')
    payload=$(kvd_b64url "$payload")
    unsigned="$header.$payload"
    signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key_file" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=\n')
    [[ -n $signature ]] || kvd_die 'openssl produced an empty JWT signature'
    printf '%s.%s\n' "$unsigned" "$signature"
}

# Call curl with credentials in the config stream, never in curl's argv.
kvd_curl_call() {
    local url=$1 method=$2 auth=$3 body=$4 timeout=$5 response curl_status
    local body_config=
    if [[ -n $body ]]; then
        body_config=$(jq -nr --arg value "$body" '$value | @json')
    fi

    if response=$(
        {
            printf 'header = "Accept: application/vnd.github+json"\n'
            printf 'header = "X-GitHub-Api-Version: %s"\n' "$KVD_API_VERSION"
            if [[ -n $auth ]]; then
                printf 'header = "Authorization: Bearer %s"\n' "$auth"
            fi
            if [[ -n $body ]]; then
                printf 'header = "Content-Type: application/json"\n'
                printf 'data = %s\n' "$body_config"
            fi
        } | curl --silent --show-error --max-time "$timeout" --request "$method" --write-out $'\n%{http_code}' --config - "$url" 2>/dev/null
    ); then
        curl_status=0
    else
        curl_status=$?
    fi

    if (( curl_status != 0 )); then
        KVD_HTTP=000
        KVD_BODY=''
        return 1
    fi
    KVD_HTTP=${response##*$'\n'}
    KVD_BODY=${response%$'\n'*}
    [[ $KVD_HTTP =~ ^[0-9]{3}$ ]] || { KVD_HTTP=000; return 1; }
    (( 10#$KVD_HTTP >= 200 && 10#$KVD_HTTP < 300 ))
}

kvd_refresh_job_token_copies() {
    local installation=$1 token=$2 state_file job_id adapter unit token_file tmp current
    for state_file in "$KVD_STATE_DIR"/jobs/*/state.json; do
        [[ -r $state_file ]] || continue
        adapter=$(jq -r '.adapter' "$state_file")
        [[ ${KVD_A_INSTALLATION[$adapter]:-} == "$installation" ]] || continue
        unit=$(jq -r '.unit' "$state_file")
        kvd_systemd_active "$unit" || continue
        job_id=${state_file%/state.json}
        job_id=${job_id##*/}
        token_file="$KVD_STATE_DIR/jobs/$job_id/github-token"
        current=''
        [[ -r $token_file ]] && current=$(<"$token_file")
        [[ $current == "$token" ]] && continue
        tmp="$KVD_STATE_DIR/jobs/$job_id/.github-token.$$.tmp"
        printf '%s' "$token" > "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" "$token_file"
    done
}

kvd_get_installation_token() {
    local installation=$1 force=${2:-0} now cache expires_at token installation_id jwt response_token response_expiry tmp
    now=$(kvd_now)
    cache="$KVD_STATE_DIR/tokens/$installation.json"
    if (( force == 0 )) && [[ -r $cache ]]; then
        expires_at=$(jq -r '.expires_at_epoch // 0' "$cache" 2>/dev/null || printf '0')
        token=$(jq -r '.token // empty' "$cache" 2>/dev/null || true)
        if [[ $expires_at =~ ^[0-9]+$ && -n $token ]] && (( expires_at - now >= 600 )); then
            KVD_TOKEN=$token
            kvd_refresh_job_token_copies "$installation" "$KVD_TOKEN"
            return 0
        fi
    fi

    installation_id=$(kvd_installation_id "$installation") || return 1
    jwt=$(kvd_make_jwt "$now") || return 1
    local token_body='{"permissions":{"administration":"write","actions":"read","metadata":"read"}}'
    if ! kvd_curl_call "$KVD_API_URL/app/installations/$installation_id/access_tokens" POST "$jwt" "$token_body" 30; then
        return 1
    fi
    response_token=$(jq -r '.token // empty' <<< "$KVD_BODY") || return 1
    response_expiry=$(jq -r '.expires_at // empty' <<< "$KVD_BODY") || return 1
    [[ $response_token =~ ^[A-Za-z0-9_.-]+$ ]] || { KVD_HTTP=000; return 1; }
    expires_at=$(date -u -d "$response_expiry" +%s 2>/dev/null) || { KVD_HTTP=000; return 1; }
    [[ $expires_at =~ ^[0-9]+$ ]] || { KVD_HTTP=000; return 1; }

    umask 0077
    tmp=$(mktemp "$KVD_STATE_DIR/tokens/.${installation}.XXXXXX")
    # The token alphabet is constrained above, so it is safe to write as a JSON string.
    printf '{"token":"%s","expires_at":"%s","expires_at_epoch":%s}\n' "$response_token" "$response_expiry" "$expires_at" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$cache"
    KVD_TOKEN=$response_token
    kvd_refresh_job_token_copies "$installation" "$KVD_TOKEN"
    kvd_log "token-refreshed installation=$installation expires_at=$response_expiry"
}

kvd_github_request() {
    local installation=$1 method=$2 path=$3 body=${4:-} timeout=${5:-20} force_token=${6:-0}
    KVD_HTTP=000
    KVD_BODY=''
    kvd_get_installation_token "$installation" "$force_token" || return 1
    kvd_curl_call "$KVD_API_URL$path" "$method" "$KVD_TOKEN" "$body" "$timeout"
}

kvd_list_runners() {
    local installation=$1 repo=$2 force_token=${3:-0} page=1 count response all='[]'
    while :; do
        if ! kvd_github_request "$installation" GET "/repos/$repo/actions/runners?per_page=100&page=$page" '' 20 "$force_token"; then
            return 1
        fi
        response=$KVD_BODY
        if ! jq -e '.runners | type == "array"' <<< "$response" >/dev/null; then
            KVD_HTTP=000
            return 1
        fi
        count=$(jq '.runners | length' <<< "$response")
        all=$(jq -cn --argjson all "$all" --argjson response "$response" '$all + $response.runners')
        (( count < 100 )) && break
        page=$((page + 1))
        force_token=0
    done
    KVD_RUNNERS=$(jq -cn --argjson runners "$all" '{runners:$runners}')
}

kvd_adapter_labels_json() {
    local adapter=$1 labels=${KVD_A_LABELS[$1]}
    local -a items=()
    labels=${labels//,/ }
    read -r -a items <<< "$labels"
    printf '%s\n' "${items[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

kvd_labels_match() {
    local adapter=$1 job_json=$2 required
    required=$(kvd_adapter_labels_json "$adapter")
    jq -e --argjson required "$required" '[.labels[]?] as $available | all($required[]; . as $label | $available | index($label) != null)' <<< "$job_json" >/dev/null
}

kvd_record_poll() {
    local repo=$1 http=$2 at=$3
    KVD_LAST_POLL_JSON=$(jq -c --arg key "$repo" --arg http "$http" --arg at "$at" '.[$key] = {http:$http,at:$at}' <<< "$KVD_LAST_POLL_JSON")
}

kvd_api_failure() {
    local adapter=$1 now delay count http
    now=$(kvd_now)
    count=$(( ${KVD_POLL_FAILURES[$adapter]:-0} + 1 ))
    KVD_POLL_FAILURES[$adapter]=$count
    case $count in
        1) delay=20 ;;
        2) delay=60 ;;
        *) delay=300 ;;
    esac
    KVD_NEXT_POLL[$adapter]=$((now + delay))
    KVD_REPO_OK[$adapter]=0
    http=$KVD_HTTP
    kvd_record_poll "${KVD_A_REPO[$adapter]}" "$http" "$(kvd_iso_now)"
    kvd_log "poll-error http=$http repo=${KVD_A_REPO[$adapter]} retry_in=${delay}s"
}

kvd_poll_adapter() {
    local adapter=$1 runs_status run_page jobs_page run_id run_json jobs_json job_json job_id job_status created_at
    local installation=${KVD_A_INSTALLATION[$adapter]} repo=${KVD_A_REPO[$adapter]}
    local now runs_count jobs_count jobs_url
    now=$(kvd_now)
    if (( now < ${KVD_NEXT_POLL[$adapter]:-0} )); then
        KVD_REPO_OK[$adapter]=0
        return 0
    fi

    for runs_status in queued pending in_progress; do
        run_page=1
        while :; do
            if ! kvd_github_request "$installation" GET "/repos/$repo/actions/runs?status=$runs_status&per_page=100&page=$run_page"; then
                kvd_api_failure "$adapter"
                return 1
            fi
            runs_json=$KVD_BODY
            if ! jq -e '.workflow_runs | type == "array"' <<< "$runs_json" >/dev/null; then
                KVD_HTTP=000
                kvd_api_failure "$adapter"
                return 1
            fi
            runs_count=$(jq '.workflow_runs | length' <<< "$runs_json")
            while IFS= read -r run_json; do
                [[ -n $run_json ]] || continue
                run_id=$(jq -r '.id | tostring' <<< "$run_json")
                [[ $run_id =~ ^[0-9]+$ ]] || continue
                jobs_page=1
                while :; do
                    jobs_url="/repos/$repo/actions/runs/$run_id/jobs?per_page=100&page=$jobs_page"
                    if ! kvd_github_request "$installation" GET "$jobs_url"; then
                        kvd_api_failure "$adapter"
                        return 1
                    fi
                    jobs_json=$KVD_BODY
                    if ! jq -e '.jobs | type == "array"' <<< "$jobs_json" >/dev/null; then
                        KVD_HTTP=000
                        kvd_api_failure "$adapter"
                        return 1
                    fi
                    while IFS= read -r job_json; do
                        [[ -n $job_json ]] || continue
                        job_id=$(jq -r '.id | tostring' <<< "$job_json")
                        [[ $job_id =~ ^[0-9]+$ ]] || continue
                        job_status=$(jq -r '.status // "unknown"' <<< "$job_json")
                        printf '%s\n' "$(jq -cn --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$job_id" --arg status "$job_status" '{adapter:$adapter,repo:$repo,job_id:$job_id,status:$status}')" >> "$KVD_JOB_LINES"
                        if [[ $job_status == queued ]] && kvd_labels_match "$adapter" "$job_json"; then
                            created_at=$(jq -r '.created_at // empty' <<< "$job_json")
                            [[ -n $created_at ]] || created_at=$(jq -r '.run_started_at // empty' <<< "$run_json")
                            printf '%s\n' "$(jq -cn --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$job_id" --arg run_id "$run_id" --arg created_at "$created_at" '{adapter:$adapter,repo:$repo,job_id:$job_id,run_id:$run_id,created_at:$created_at}')" >> "$KVD_QUEUE_LINES"
                        fi
                    done < <(jq -c '.jobs[]' <<< "$jobs_json")
                    jobs_page=$((jobs_page + 1))
                    jobs_count=$(jq '.jobs | length' <<< "$jobs_json")
                    (( jobs_count < 100 )) && break
                done
            done < <(jq -c '.workflow_runs[]' <<< "$runs_json")
            run_page=$((run_page + 1))
            (( runs_count < 100 )) && break
        done
    done

    KVD_POLL_FAILURES[$adapter]=0
    KVD_NEXT_POLL[$adapter]=$((now + KVD_POLL_SECONDS))
    KVD_REPO_OK[$adapter]=1
    kvd_record_poll "$repo" 200 "$(kvd_iso_now)"
}

kvd_probe_installations() {
    local installation key repo_variable repo now delay failures
    now=$(kvd_now)
    for installation in "${KVD_INSTALLATIONS[@]}"; do
        (( now >= ${KVD_PROBE_NEXT_POLL[$installation]:-0} )) || continue
        key=${installation^^}
        key=${key//-/_}
        repo_variable="KVM_DISPATCHER_REPOSITORY_${key}"
        repo=${!repo_variable:-}
        [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || kvd_die "missing repository mapping for installation $installation"
        if kvd_list_runners "$installation" "$repo"; then
            KVD_PROBE_FAILURES[$installation]=0
            KVD_PROBE_NEXT_POLL[$installation]=$((now + KVD_POLL_SECONDS))
            kvd_record_poll "$repo" "$KVD_HTTP" "$(kvd_iso_now)"
        else
            failures=$(( ${KVD_PROBE_FAILURES[$installation]:-0} + 1 ))
            KVD_PROBE_FAILURES[$installation]=$failures
            case $failures in
                1) delay=20 ;;
                2) delay=60 ;;
                *) delay=300 ;;
            esac
            KVD_PROBE_NEXT_POLL[$installation]=$((now + delay))
            kvd_record_poll "$repo" "$KVD_HTTP" "$(kvd_iso_now)"
            kvd_log "poll-error http=$KVD_HTTP repo=$repo retry_in=${delay}s"
        fi
    done
}

kvd_prepare_discovered_job() {
    local item=$1 adapter id run_id repo created_at unit state_dir state_file now now_iso attempt_file blocked consumed retry created_epoch age
    adapter=$(jq -r '.adapter' <<< "$item")
    id=$(jq -r '.job_id' <<< "$item")
    run_id=$(jq -r '.run_id' <<< "$item")
    repo=${KVD_A_REPO[$adapter]}
    created_at=$(jq -r '.created_at' <<< "$item")
    state_dir="$KVD_STATE_DIR/jobs/$id"
    state_file="$state_dir/state.json"
    if [[ -r $state_file ]]; then
        [[ $(jq -r '.phase' "$state_file") == DISCOVERED ]] && return 0
        return 0
    fi

    attempt_file="$KVD_ATTEMPT_DIR/$id.json"
    now=$(kvd_now)
    if [[ -r $attempt_file ]]; then
        blocked=$(jq -r '.blocked // false' "$attempt_file")
        consumed=$(jq -r '.consumed // false' "$attempt_file")
        [[ $blocked == true || $consumed == true ]] && return 0
        retry=$(jq -r '.retry_after // 0' "$attempt_file")
        (( now < retry )) && return 0
    fi

    unit="${KVD_A_UNIT[$adapter]}$id.service"
    mkdir -p "$state_dir"
    chmod 0700 "$state_dir"
    now_iso=$(kvd_iso_now)
    jq -cn \
        --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$id" \
        --arg run_id "$run_id" --arg created_at "$created_at" --arg unit "$unit" \
        --arg phase DISCOVERED --arg since "$now_iso" \
        --argjson discovered_epoch "$now" \
        --argjson memory_mib "${KVD_A_MEMORY[$adapter]}" \
        --argjson max_unit_seconds "${KVD_A_MAX_SECONDS[$adapter]}" \
        '{adapter:$adapter,repo:$repo,job_id:$job_id,run_id:$run_id,created_at:$created_at,unit:$unit,phase:$phase,since:$since,discovered_epoch:$discovered_epoch,memory_mib:$memory_mib,max_unit_seconds:$max_unit_seconds}' > "$state_file"
    chmod 0600 "$state_file"
    created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null || printf '%s' "$now")
    age=$((now - created_epoch))
    (( age < 0 )) && age=0
    kvd_log "job-discovered repo=$repo job=$id age=${age}s"
}

kvd_prune_discovered_jobs() {
    local state_file job_id adapter phase repo unit
    for state_file in "$KVD_STATE_DIR"/jobs/*/state.json; do
        [[ -r $state_file ]] || continue
        phase=$(jq -r '.phase' "$state_file")
        [[ $phase == DISCOVERED ]] || continue
        adapter=$(jq -r '.adapter' "$state_file")
        [[ ${KVD_REPO_OK[$adapter]:-0} == 1 ]] || continue
        job_id=$(jq -r '.job_id' "$state_file")
        unit=$(jq -r '.unit' "$state_file")
        if kvd_systemd_active "$unit"; then
            kvd_mark_job_running "$job_id"
            continue
        fi
        if ! jq -e --arg id "$job_id" --arg adapter "$adapter" 'any(.[]; .job_id == $id and .adapter == $adapter)' <<< "$KVD_QUEUE" >/dev/null; then
            repo=$(jq -r '.repo' "$state_file")
            kvd_set_job_phase "$job_id" SWEPT
            rm -rf -- "$KVD_STATE_DIR/jobs/$job_id"
            kvd_log "job-swept repo=$repo job=$job_id"
        fi
    done
}

kvd_poll_all() {
    local adapter tmp_jobs tmp_queue priority healthy
    KVD_REPO_OK=()
    KVD_JOB_MAP='{}'
    tmp_jobs=$(mktemp "$KVD_STATE_DIR/jobs-map.XXXXXX")
    tmp_queue=$(mktemp "$KVD_STATE_DIR/queue.XXXXXX")
    KVD_JOB_LINES=$tmp_jobs
    KVD_QUEUE_LINES=$tmp_queue
    : > "$tmp_jobs"
    : > "$tmp_queue"
    if (( ${#KVD_ADAPTER_NAMES[@]} == 0 )); then
        KVD_QUEUE='[]'
        kvd_probe_installations
        rm -f "$tmp_jobs" "$tmp_queue"
        return 0
    fi

    for adapter in "${KVD_ADAPTER_NAMES[@]}"; do
        kvd_poll_adapter "$adapter" || true
    done

    # Only adapters with a complete poll this round contribute jobs, so one failing
    # installation does not hold back FIFO scheduling for the others.
    healthy=$(for adapter in "${KVD_ADAPTER_NAMES[@]}"; do
        if [[ ${KVD_REPO_OK[$adapter]:-0} == 1 ]]; then
            printf '%s\n' "$adapter"
        fi
    done | jq -Rsc 'split("\n") | map(select(length > 0))')
    KVD_JOB_MAP=$(jq -cs 'reduce .[] as $item ({}; .[$item.job_id] = $item)' "$tmp_jobs")
    priority=$KVD_PRIORITY
    KVD_QUEUE=$(jq -cs --arg priority "$priority" --argjson healthy "$healthy" '
      map(select(.adapter | IN($healthy[])))
      | unique_by(.job_id)
      | sort_by([if ($priority != "" and (.adapter == $priority or .repo == $priority)) then 0 else 1 end, .created_at, (.job_id | tonumber)])
    ' "$tmp_queue")
    rm -f "$tmp_jobs" "$tmp_queue"

    local item
    kvd_prune_attempt_records
    kvd_prune_discovered_jobs
    while IFS= read -r item; do
        [[ -n $item ]] || continue
        kvd_prepare_discovered_job "$item"
    done < <(jq -c '.[]' <<< "$KVD_QUEUE")
}

kvd_systemd_active() {
    systemctl is-active --quiet "$1" >/dev/null 2>&1
}

kvd_unit_exit_status() {
    local value
    value=$(systemctl show --property=ExecMainStatus --value "$1" 2>/dev/null || true)
    [[ $value =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf 'unknown'
}

kvd_unit_memory_peak_mib() {
    local unit=$1 cgroup bytes
    cgroup=$(systemctl show --property=ControlGroup --value "$unit" 2>/dev/null || true)
    if [[ $cgroup =~ ^(/[A-Za-z0-9_.@:-]+)+$ && -r /sys/fs/cgroup${cgroup}/memory.peak ]]; then
        bytes=$(</sys/fs/cgroup"${cgroup}"/memory.peak)
    else
        bytes=$(systemctl show --property=MemoryPeak --value "$unit" 2>/dev/null || true)
    fi
    if [[ $bytes =~ ^[0-9]+$ ]]; then
        printf '%s' "$(((bytes + 1048575) / 1048576))"
    else
        printf 'unknown'
    fi
}

kvd_set_job_phase() {
    local job_id=$1 phase=$2 state_file tmp
    state_file="$KVD_STATE_DIR/jobs/$job_id/state.json"
    [[ -r $state_file ]] || return 0
    tmp=$(mktemp "$KVD_STATE_DIR/jobs/$job_id/.state.XXXXXX")
    jq -c --arg phase "$phase" '.phase = $phase' "$state_file" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$state_file"
}

kvd_mark_job_running() {
    local job_id=$1 state_file unit started_text started_epoch since tmp
    state_file="$KVD_STATE_DIR/jobs/$job_id/state.json"
    unit=$(jq -r '.unit' "$state_file")
    started_epoch=$(kvd_now)
    started_text=$(systemctl show --property=ActiveEnterTimestamp --value "$unit" 2>/dev/null || true)
    if [[ -n $started_text ]]; then
        started_epoch=$(date -d "$started_text" +%s 2>/dev/null || kvd_now)
    fi
    since=$(date -u -d "@$started_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || kvd_iso_now)
    tmp=$(mktemp "$KVD_STATE_DIR/jobs/$job_id/.state.XXXXXX")
    jq -c --arg since "$since" --argjson started "$started_epoch" '.phase = "RUNNING" | .claimed_epoch = (.claimed_epoch // $started) | .started_epoch = $started | .since = $since' "$state_file" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$state_file"
}

# Job scripts name their own runners and log `event=jitconfig-minted runner_id=N
# runner_name=NAME` and, after their own cleanup, `event=runner-deleted runner_id=N`.
kvd_unit_journal_runner() {
    local unit=$1 journal line minted_id='' deleted_id=''
    KVD_JOURNAL_RUNNER_NAME=''
    KVD_JOURNAL_RUNNER_DELETED=false
    journal=$(journalctl --unit="$unit" --output=cat --no-pager --quiet 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ $line =~ (^|[[:space:]])event=jitconfig-minted[[:space:]]+runner_id=([0-9]+)[[:space:]]+runner_name=([A-Za-z0-9_.-]+)([[:space:]]|$) ]]; then
            minted_id=${BASH_REMATCH[2]}
            KVD_JOURNAL_RUNNER_NAME=${BASH_REMATCH[3]}
            KVD_JOURNAL_RUNNER_DELETED=false
        elif [[ $line =~ (^|[[:space:]])event=runner-deleted[[:space:]]+runner_id=([0-9]+)([[:space:]]|$) ]]; then
            deleted_id=${BASH_REMATCH[2]}
            [[ -n $minted_id && $deleted_id == "$minted_id" ]] && KVD_JOURNAL_RUNNER_DELETED=true
        fi
    done <<< "$journal"
    return 0
}

# Resolve a job's registration from the optional runner-name file, else the unit journal.
# KVD_RUNNER_NAME stays empty when no registration under the adapter prefix is known.
kvd_job_runner_identity() {
    local adapter=$1 job_id=$2 unit=$3 prefix=${KVD_A_PREFIX[$1]} name name_file
    KVD_RUNNER_NAME=''
    KVD_RUNNER_DELETED=false
    kvd_unit_journal_runner "$unit" || return 1
    name=$KVD_JOURNAL_RUNNER_NAME
    name_file="$KVD_STATE_DIR/jobs/$job_id/runner-name"
    [[ -r $name_file ]] && name=$(<"$name_file")
    [[ $name =~ ^[A-Za-z0-9_.-]+$ && $name == "$prefix"* ]] || return 0
    KVD_RUNNER_NAME=$name
    [[ $name == "$KVD_JOURNAL_RUNNER_NAME" ]] && KVD_RUNNER_DELETED=$KVD_JOURNAL_RUNNER_DELETED
    return 0
}

kvd_runner_busy() {
    local adapter=$1 job_id=$2 unit=$3 installation=${KVD_A_INSTALLATION[$1]} repo=${KVD_A_REPO[$1]}
    KVD_RUNNER_BUSY=false
    if ! kvd_job_runner_identity "$adapter" "$job_id" "$unit"; then
        KVD_RUNNER_BUSY=unknown
        return 1
    fi
    [[ -n $KVD_RUNNER_NAME ]] || return 0
    if ! kvd_list_runners "$installation" "$repo"; then
        KVD_RUNNER_BUSY=unknown
        return 1
    fi
    if jq -e --arg name "$KVD_RUNNER_NAME" '.runners[]? | select(.name == $name and .busy == true)' <<< "$KVD_RUNNERS" >/dev/null; then
        KVD_RUNNER_BUSY=true
    fi
}

kvd_sweep_job() {
    local job_id=$1 state_file adapter repo unit installation runner_id busy
    state_file="$KVD_STATE_DIR/jobs/$job_id/state.json"
    [[ -r $state_file ]] || return 0
    adapter=$(jq -r '.adapter' "$state_file")
    repo=$(jq -r '.repo' "$state_file")
    unit=$(jq -r '.unit' "$state_file")
    kvd_systemd_active "$unit" && return 1
    installation=${KVD_A_INSTALLATION[$adapter]}
    kvd_job_runner_identity "$adapter" "$job_id" "$unit" || return 1

    # The job script's own DELETE is authoritative when its journal records success.
    # Otherwise force a newly minted installation token for terminal cleanup, even if
    # a cached token still has time remaining.
    if [[ -n $KVD_RUNNER_NAME && $KVD_RUNNER_DELETED == false ]]; then
        if ! kvd_list_runners "$installation" "$repo" 1; then
            return 1
        fi
        while IFS=$'\t' read -r runner_id busy; do
            [[ $runner_id =~ ^[0-9]+$ ]] || continue
            [[ $busy == true ]] && return 1
            if kvd_github_request "$installation" DELETE "/repos/$repo/actions/runners/$runner_id"; then
                kvd_log "orphan-runner-deleted repo=$repo runner=$KVD_RUNNER_NAME"
            else
                return 1
            fi
        done < <(jq -r --arg name "$KVD_RUNNER_NAME" '.runners[]? | select(.name == $name) | [.id,(.busy|tostring)] | @tsv' <<< "$KVD_RUNNERS")
    fi

    kvd_set_job_phase "$job_id" SWEPT
    rm -rf -- "$KVD_STATE_DIR/jobs/$job_id"
    kvd_log "job-swept repo=$repo job=$job_id"
}

kvd_handle_inactive_job() {
    local job_id=$1 state_file state_dir adapter unit phase exit_status started now duration peak repo
    state_file="$KVD_STATE_DIR/jobs/$job_id/state.json"
    [[ -r $state_file ]] || return 0
    adapter=$(jq -r '.adapter' "$state_file")
    unit=$(jq -r '.unit' "$state_file")
    phase=$(jq -r '.phase' "$state_file")
    repo=$(jq -r '.repo' "$state_file")
    state_dir="$KVD_STATE_DIR/jobs/$job_id"
    case $phase in
        DISCOVERED|CLAIMED)
            rm -rf -- "$state_dir"
            return 0
            ;;
        DONE|CANCELLED|STUCK)
            kvd_mark_job_consumed "$job_id"
            kvd_sweep_job "$job_id" || true
            return 0
            ;;
        FAILED)
            kvd_sweep_job "$job_id" || true
            return 0
            ;;
    esac
    exit_status=$(kvd_unit_exit_status "$unit")
    started=$(jq -r '.started_epoch // .claimed_epoch // 0' "$state_file")
    now=$(kvd_now)
    duration=$((now - started))
    (( duration < 0 )) && duration=0
    peak=$(kvd_unit_memory_peak_mib "$unit")
    kvd_log "job-finished unit=$unit exit=$exit_status duration=${duration}s memory_peak_mib=$peak"
    kvd_mark_job_consumed "$job_id"
    kvd_set_job_phase "$job_id" DONE
    kvd_sweep_job "$job_id" || true
}

kvd_mark_start_failure() {
    local adapter=$1 job_id=$2 attempt_file count now repo blocked retry tmp
    attempt_file="$KVD_ATTEMPT_DIR/$job_id.json"
    now=$(kvd_now)
    repo=${KVD_A_REPO[$adapter]}
    count=0
    if [[ -r $attempt_file ]]; then
        count=$(jq -r '.attempts // 0' "$attempt_file")
        [[ $count =~ ^[0-9]+$ ]] || count=0
    fi
    count=$((count + 1))
    blocked=false
    retry=$((now + 300))
    (( count >= 3 )) && { blocked=true; retry=0; }
    tmp=$(mktemp "$KVD_ATTEMPT_DIR/.${job_id}.XXXXXX")
    jq -cn --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$job_id" --argjson attempts "$count" --argjson retry_after "$retry" --argjson blocked "$blocked" '{adapter:$adapter,repo:$repo,job_id:$job_id,attempts:$attempts,retry_after:$retry_after,blocked:$blocked}' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$attempt_file"
    if [[ $blocked == true ]]; then
        kvd_log "job-blocked repo=$repo job=$job_id attempts=$count"
    else
        kvd_log "job-start-failed repo=$repo job=$job_id attempts=$count retry_in=300s"
    fi
}

kvd_mark_job_consumed() {
    local job_id=$1 state_file="$KVD_STATE_DIR/jobs/$1/state.json" attempt_file adapter repo tmp
    [[ -r $state_file ]] || return 0
    adapter=$(jq -r '.adapter' "$state_file")
    repo=$(jq -r '.repo' "$state_file")
    attempt_file="$KVD_ATTEMPT_DIR/$job_id.json"
    tmp=$(mktemp "$KVD_ATTEMPT_DIR/.${job_id}.XXXXXX")
    jq -cn --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$job_id" \
        '{adapter:$adapter,repo:$repo,job_id:$job_id,attempts:0,retry_after:0,blocked:false,consumed:true,reason:"unit-already-ran"}' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$attempt_file"
}

kvd_prune_attempt_records() {
    local attempt_file adapter job_id status
    for attempt_file in "$KVD_ATTEMPT_DIR"/*.json; do
        [[ -r $attempt_file ]] || continue
        jq -e '.blocked != true' "$attempt_file" >/dev/null || continue
        adapter=$(jq -r '.adapter' "$attempt_file")
        [[ ${KVD_REPO_OK[$adapter]:-0} == 1 ]] || continue
        job_id=$(jq -r '.job_id' "$attempt_file")
        status=$(jq -r --arg id "$job_id" '.[$id].status // "gone"' <<< "$KVD_JOB_MAP")
        if [[ $status != queued && $status != in_progress ]]; then
            rm -f "$attempt_file"
        fi
    done
}

kvd_candidate_allowed() {
    local item=$1 adapter id now attempt_file retry blocked consumed repo_count memory_used phase repo
    adapter=$(jq -r '.adapter' <<< "$item")
    id=$(jq -r '.job_id' <<< "$item")
    repo=${KVD_A_REPO[$adapter]}
    attempt_file="$KVD_ATTEMPT_DIR/$id.json"
    now=$(kvd_now)
    if [[ -r "$KVD_STATE_DIR/jobs/$id/state.json" ]]; then
        phase=$(jq -r '.phase' "$KVD_STATE_DIR/jobs/$id/state.json")
        [[ $phase == DISCOVERED ]] || return 1
    fi
    if [[ -r $attempt_file ]]; then
        blocked=$(jq -r '.blocked // false' "$attempt_file")
        consumed=$(jq -r '.consumed // false' "$attempt_file")
        [[ $blocked == true || $consumed == true ]] && return 1
        retry=$(jq -r '.retry_after // 0' "$attempt_file")
        (( now < retry )) && return 1
    fi
    repo_count=0
    memory_used=0
    local file unit
    for file in "$KVD_STATE_DIR"/jobs/*/state.json; do
        [[ -r $file ]] || continue
        unit=$(jq -r '.unit' "$file")
        kvd_systemd_active "$unit" || continue
        memory_used=$((memory_used + $(jq -r '.memory_mib' "$file")))
        [[ $(jq -r '.repo' "$file") == "$repo" ]] && repo_count=$((repo_count + 1))
    done
    (( repo_count < ${KVD_A_CONCURRENCY[$adapter]} )) || return 1
    (( memory_used + ${KVD_A_MEMORY[$adapter]} <= KVD_CAPACITY_MIB )) || return 1
    return 0
}

kvd_start_candidate() {
    local item=$1 adapter id run_id repo created_at unit token state_dir state_file now now_iso tmp
    adapter=$(jq -r '.adapter' <<< "$item")
    id=$(jq -r '.job_id' <<< "$item")
    run_id=$(jq -r '.run_id' <<< "$item")
    repo=${KVD_A_REPO[$adapter]}
    created_at=$(jq -r '.created_at' <<< "$item")
    unit="${KVD_A_UNIT[$adapter]}$id.service"
    [[ $id =~ ^[0-9a-z-]+$ ]] || return 1

    if ! kvd_get_installation_token "${KVD_A_INSTALLATION[$adapter]}"; then
        return 1
    fi
    state_dir="$KVD_STATE_DIR/jobs/$id"
    mkdir -p "$state_dir" || return 1
    chmod 0700 "$state_dir"
    printf '%s' "$KVD_TOKEN" > "$state_dir/github-token"
    chmod 0600 "$state_dir/github-token"
    now=$(kvd_now)
    now_iso=$(kvd_iso_now)
    state_file="$state_dir/state.json"
    jq -cn \
        --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$id" \
        --arg run_id "$run_id" --arg created_at "$created_at" --arg unit "$unit" \
        --arg phase CLAIMED --arg since "$now_iso" \
        --argjson claimed_epoch "$now" --argjson started_epoch "$now" \
        --argjson memory_mib "${KVD_A_MEMORY[$adapter]}" \
        --argjson max_unit_seconds "${KVD_A_MAX_SECONDS[$adapter]}" \
        '{adapter:$adapter,repo:$repo,job_id:$job_id,run_id:$run_id,created_at:$created_at,unit:$unit,phase:$phase,since:$since,claimed_epoch:$claimed_epoch,started_epoch:$started_epoch,memory_mib:$memory_mib,max_unit_seconds:$max_unit_seconds}' > "$state_file"
    chmod 0600 "$state_file"

    if systemctl start "$unit" || kvd_systemd_active "$unit"; then
        kvd_set_job_phase "$id" STARTED
        kvd_log "job-started unit=$unit"
        rm -f "$KVD_ATTEMPT_DIR/$id.json"
        return 0
    fi

    kvd_set_job_phase "$id" FAILED
    kvd_mark_start_failure "$adapter" "$id"
    kvd_sweep_job "$id" || true
    return 1
}

kvd_schedule_queued() {
    local item
    while IFS= read -r item; do
        [[ -n $item ]] || continue
        if kvd_candidate_allowed "$item"; then
            kvd_start_candidate "$item" || true
        fi
    done < <(jq -c '.[]' <<< "$KVD_QUEUE")
}

kvd_monitor_inflight() {
    local state_file job_id adapter unit phase started max_seconds now elapsed status busy
    now=$(kvd_now)
    for state_file in "$KVD_STATE_DIR"/jobs/*/state.json; do
        [[ -r $state_file ]] || continue
        job_id=${state_file%/state.json}
        job_id=${job_id##*/}
        adapter=$(jq -r '.adapter' "$state_file")
        unit=$(jq -r '.unit' "$state_file")
        phase=$(jq -r '.phase' "$state_file")
        if [[ $phase == DISCOVERED ]]; then
            if kvd_systemd_active "$unit"; then
                kvd_mark_job_running "$job_id"
                phase=RUNNING
            else
                continue
            fi
        fi

        if ! kvd_systemd_active "$unit"; then
            kvd_handle_inactive_job "$job_id"
            continue
        fi
        case $phase in
            DONE|CANCELLED|STUCK|FAILED)
                if systemctl stop "$unit"; then
                    kvd_sweep_job "$job_id" || true
                fi
                continue
                ;;
        esac
        [[ $phase == STARTED ]] && { kvd_set_job_phase "$job_id" RUNNING; phase=RUNNING; }

        started=$(jq -r '.started_epoch // .claimed_epoch // 0' "$state_file")
        max_seconds=$(jq -r '.max_unit_seconds' "$state_file")
        elapsed=$((now - started))
        if (( elapsed > max_seconds )); then
            if systemctl stop "$unit"; then
                kvd_mark_job_consumed "$job_id"
                kvd_set_job_phase "$job_id" STUCK
                kvd_log "job-stuck unit=$unit duration=${elapsed}s"
                kvd_sweep_job "$job_id" || true
            fi
            continue
        fi

        [[ ${KVD_REPO_OK[$adapter]:-0} == 1 ]] || continue
        status=$(jq -r --arg id "$job_id" '.[$id].status // "gone"' <<< "$KVD_JOB_MAP")
        if [[ $status != queued && $status != in_progress ]]; then
            if kvd_runner_busy "$adapter" "$job_id" "$unit"; then
                busy=$KVD_RUNNER_BUSY
                if [[ $busy == false ]] && systemctl stop "$unit"; then
                    kvd_mark_job_consumed "$job_id"
                    kvd_set_job_phase "$job_id" CANCELLED
                    kvd_log "job-cancelled unit=$unit"
                    kvd_sweep_job "$job_id" || true
                fi
            fi
        fi
    done
}

kvd_active_job_units() {
    local listing unit
    listing=$(systemctl list-units --state=active --type=service --no-legend --plain --full '*-runner-job@*.service' 2>/dev/null || true)
    while IFS= read -r unit; do
        unit=${unit%%[[:space:]]*}
        [[ $unit == *-runner-job@*.service ]] && printf '%s\n' "$unit"
    done <<< "$listing"
    return 0
}

kvd_adopt_active_units() {
    local unit adapter prefix job_id state_dir state_file started_text started_epoch repo now since_text phase
    now=$(kvd_now)
    while IFS= read -r unit; do
        [[ -n $unit ]] || continue
        for adapter in "${KVD_ADAPTER_NAMES[@]}"; do
            prefix=${KVD_A_UNIT[$adapter]}
            [[ $unit == "$prefix"*'.service' ]] || continue
            job_id=${unit#"$prefix"}
            job_id=${job_id%.service}
            [[ $job_id =~ ^[0-9a-z-]+$ ]] || continue
            state_dir="$KVD_STATE_DIR/jobs/$job_id"
            state_file="$state_dir/state.json"
            mkdir -p "$state_dir"
            chmod 0700 "$state_dir"
            if [[ -r $state_file ]]; then
                phase=$(jq -r '.phase' "$state_file")
                if [[ $phase == DISCOVERED ]]; then
                    kvd_mark_job_running "$job_id"
                else
                    kvd_set_job_phase "$job_id" RUNNING
                fi
            else
                started_text=$(systemctl show --property=ActiveEnterTimestamp --value "$unit" 2>/dev/null || true)
                started_epoch=$now
                if [[ -n $started_text ]]; then
                    started_epoch=$(date -d "$started_text" +%s 2>/dev/null || printf '%s' "$now")
                fi
                since_text=$(date -u -d "@$started_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || kvd_iso_now)
                repo=${KVD_A_REPO[$adapter]}
                jq -cn \
                    --arg adapter "$adapter" --arg repo "$repo" --arg job_id "$job_id" \
                    --arg unit "$unit" --arg phase RUNNING --arg since "$since_text" \
                    --argjson claimed_epoch "$started_epoch" --argjson started_epoch "$started_epoch" \
                    --argjson memory_mib "${KVD_A_MEMORY[$adapter]}" \
                    --argjson max_unit_seconds "${KVD_A_MAX_SECONDS[$adapter]}" \
                    '{adapter:$adapter,repo:$repo,job_id:$job_id,run_id:null,created_at:null,unit:$unit,phase:$phase,since:$since,claimed_epoch:$claimed_epoch,started_epoch:$started_epoch,memory_mib:$memory_mib,max_unit_seconds:$max_unit_seconds}' > "$state_file"
                chmod 0600 "$state_file"
            fi
            break
        done
    done < <(kvd_active_job_units)
}

# Delete offline, idle registrations under an adapter prefix that no active job unit
# references. Runners are listed before journals are read, so a registration minted
# after the listing cannot be mistaken for an orphan.
kvd_sweep_orphan_runners() {
    local adapter repo installation prefix unit job_id name_file runner_id runner_name referenced='[]'
    local -a names=()
    local -A runners=()
    for adapter in "${KVD_ADAPTER_NAMES[@]}"; do
        if kvd_list_runners "${KVD_A_INSTALLATION[$adapter]}" "${KVD_A_REPO[$adapter]}" 1; then
            runners[$adapter]=$KVD_RUNNERS
        fi
    done
    while IFS= read -r unit; do
        [[ -n $unit ]] || continue
        if ! kvd_unit_journal_runner "$unit"; then
            kvd_log "orphan-sweep-skipped unit=$unit reason=journal-unavailable"
            return 0
        fi
        job_id=${unit#*-runner-job@}
        job_id=${job_id%.service}
        name_file="$KVD_STATE_DIR/jobs/$job_id/runner-name"
        names=()
        [[ -n $KVD_JOURNAL_RUNNER_NAME ]] && names+=("$KVD_JOURNAL_RUNNER_NAME")
        [[ $job_id =~ ^[0-9a-z-]+$ && -r $name_file ]] && names+=("$(<"$name_file")")
        if (( ${#names[@]} == 0 )); then
            kvd_log "orphan-sweep-skipped unit=$unit reason=runner-unidentified"
            return 0
        fi
        referenced=$(jq -c '. + $ARGS.positional' --args "${names[@]}" <<< "$referenced")
    done < <(kvd_active_job_units)

    for adapter in "${!runners[@]}"; do
        repo=${KVD_A_REPO[$adapter]}
        installation=${KVD_A_INSTALLATION[$adapter]}
        prefix=${KVD_A_PREFIX[$adapter]}
        while IFS=$'\t' read -r runner_id runner_name; do
            [[ $runner_id =~ ^[0-9]+$ ]] || continue
            if kvd_github_request "$installation" DELETE "/repos/$repo/actions/runners/$runner_id"; then
                kvd_log "orphan-runner-deleted repo=$repo runner=$runner_name"
            fi
        done < <(jq -r --arg prefix "$prefix" --argjson referenced "$referenced" '
          .runners[]?
          | select((.name | startswith($prefix)) and .status == "offline" and .busy == false and (.name | IN($referenced[]) | not))
          | [.id,.name] | @tsv' <<< "${runners[$adapter]}")
    done
}

kvd_sweep_startup() {
    local state_file job_id
    kvd_adopt_active_units
    for state_file in "$KVD_STATE_DIR"/jobs/*/state.json; do
        [[ -r $state_file ]] || continue
        job_id=${state_file%/state.json}
        job_id=${job_id##*/}
        if ! kvd_systemd_active "$(jq -r '.unit' "$state_file")"; then
            kvd_handle_inactive_job "$job_id"
        fi
    done
    kvd_sweep_orphan_runners
}

kvd_write_status() {
    local now_iso tmp in_flight='[]' queued='[]' blocked='[]' state_file unit job_id item attempt_file phase
    now_iso=$(kvd_iso_now)
    for state_file in "$KVD_STATE_DIR"/jobs/*/state.json; do
        [[ -r $state_file ]] || continue
        unit=$(jq -r '.unit' "$state_file")
        kvd_systemd_active "$unit" || continue
        item=$(jq -c '{repo,job_id,unit,since}' "$state_file")
        in_flight=$(jq -c --argjson item "$item" '. + [$item]' <<< "$in_flight")
    done
    for attempt_file in "$KVD_ATTEMPT_DIR"/*.json; do
        [[ -r $attempt_file ]] || continue
        jq -e '.blocked == true or .consumed == true' "$attempt_file" >/dev/null || continue
        item=$(jq -c '{repo,job_id,attempts,reason:(.reason // "start-failures")}' "$attempt_file")
        blocked=$(jq -c --argjson item "$item" '. + [$item]' <<< "$blocked")
    done
    while IFS= read -r item; do
        [[ -n $item ]] || continue
        job_id=$(jq -r '.job_id' <<< "$item")
        if [[ -r "$KVD_ATTEMPT_DIR/$job_id.json" ]] && jq -e '.blocked == true or .consumed == true' "$KVD_ATTEMPT_DIR/$job_id.json" >/dev/null; then
            continue
        fi
        if [[ -r "$KVD_STATE_DIR/jobs/$job_id/state.json" ]]; then
            phase=$(jq -r '.phase' "$KVD_STATE_DIR/jobs/$job_id/state.json")
            [[ $phase == DISCOVERED ]] || continue
        fi
        item=$(jq -c '{repo,job_id,created_at}' <<< "$item")
        queued=$(jq -c --argjson item "$item" '. + [$item]' <<< "$queued")
    done < <(jq -c '.[]' <<< "$KVD_QUEUE")
    tmp=$(mktemp "$KVD_STATUS_DIR/.status.XXXXXX")
    jq -cn \
        --arg updated_at "$now_iso" \
        --argjson capacity_mib "$KVD_CAPACITY_MIB" \
        --argjson in_flight "$in_flight" \
        --argjson queued "$queued" \
        --argjson last_poll "$KVD_LAST_POLL_JSON" \
        --argjson blocked "$blocked" \
        '{updated_at:$updated_at,capacity_mib:$capacity_mib,in_flight:$in_flight,queued:$queued,last_poll:$last_poll,blocked:$blocked}' > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$KVD_STATUS_FILE"
}

kvd_run_once() {
    kvd_poll_all || true
    kvd_monitor_inflight
    kvd_schedule_queued
    kvd_write_status
}
