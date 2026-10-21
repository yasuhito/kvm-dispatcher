# kvm-dispatcher

A small GitHub Actions dispatcher for repositories that share one KVM host. The dispatcher starts an existing repository-specific worker unit only after finding a matching queued job. Runner scripts remain responsible for their JIT configuration, guest boot, job execution, and guest cleanup. This removes idle guests from the host without merging repository-specific VM code into the dispatcher.

The initial Beelink policy is one 12 GiB guest at a time. It records the guest cgroup's `memory.peak` after each unit exits so capacity can be reconsidered from measurements, not guesses.

## Host components

- `host/kvm_dispatcher.sh`: polling, scheduling, and in-flight monitoring loop.
- `host/kvm_dispatcher_lib.sh`: trusted shell config loading, GitHub App JWT and installation-token handling, job state, and status output.
- `host/kvm_dispatcher_sweep.sh`: one-shot startup resynchronization helper. The service runs the same sweep itself before entering its loop.
- `host/kvm_dispatcher_host_wizard.sh`: encrypts a GitHub App PEM supplied through hidden terminal stdin. It does not enable or start the service.
- `host/systemd/`: service, isolation drop-in, sysusers, and tmpfiles configuration.
- `host/polkit/50-kvm-dispatcher.rules`: narrow authorization for starting and stopping only supported job templates.
- `host/repos.d/*.conf.example`: sample adapters. The QA2 and Qoral repositories ship their own adapter config and template service in their respective repositories.

Runtime secrets and job state live under `/run/kvm-dispatcher` (mode 0700). Retry and three-strike blocked records live under `/var/lib/kvm-dispatcher/attempts` so a host reboot does not silently unblock a repeatedly failing job. The status document is `/var/lib/kvm-dispatcher/status.json`, written by atomic rename.

## Scheduling and lifecycle

For each configured repository, one poll requests workflow runs in `queued`, `pending`, and `in_progress` status, then reads their jobs. A queued job is eligible only when it contains every adapter label. Run and job pagination uses 100-item pages. Candidate jobs are ordered by `created_at` across repositories. The dispatcher starts the next eligible job only when both its repository concurrency cap and the total `KVM_DISPATCHER_CAPACITY_MIB` allow it.

`KVM_DISPATCHER_PRIORITY` is empty by default, which gives global FIFO. Setting it to an adapter name such as `qa2` serves that adapter's queued jobs first while it has work; jobs within each adapter retain FIFO order. Remove the setting to return to global FIFO.

The lifecycle is:

1. `DISCOVERED`: a matching queued job is found and logged.
2. `CLAIMED`: the installation token is copied to `/run/kvm-dispatcher/jobs/<job-id>/github-token` and state is recorded.
3. `STARTED`, then `RUNNING`: start `<adapter-unit>@<job-id>.service` and monitor it.
4. `DONE`: the unit exits. Record exit status, duration, and `memory_peak_mib`.
5. `CANCELLED`: if a job is no longer queued or in progress and its runner is not busy, stop its unit.
6. `STUCK`: stop an active unit after its adapter's `MAX_UNIT_SECONDS` limit.
7. `FAILED`: a failed systemd start is retried after 300 seconds. Three start failures block that job ID until an operator clears its attempt record.
8. `SWEPT`: use a newly minted installation token to delete any remaining registration named `<RUNNER_NAME_PREFIX><job-id>`, then remove that job's runtime state.

A successfully started job ID is not launched a second time if GitHub still reports it queued after its unit exits. That condition is shown in `blocked` as `unit-already-ran`; rerun the workflow to get a new job ID. A systemd start failure is different because no worker unit was started, so it follows the 300-second retry and three-strike policy.

The startup sweep adopts active configured `*-runner-job@*` units, sweeps stale state without an active unit, and deletes offline registrations under an adapter's runner-name prefix when no corresponding unit is active. It does not delete registrations belonging to other prefixes. GitHub API failures use per-adapter retry intervals of 20, 60, then 300 seconds. In-flight unit, timeout, and memory monitoring continues on every loop during those intervals.

## GitHub App and secrets

The GitHub App needs repository permissions:

- Administration: read and write, for JIT runner creation and runner deletion.
- Actions: read, for workflow run and job discovery.
- Metadata: read, required by GitHub.

Restrict each installation to only the repository it serves. The example IDs in `host/dispatcher.conf.example` are the existing App (`5405924`) and its QA2 and Qoral installations; replace them if using another App. `KVM_DISPATCHER_INSTALLATIONS` and the corresponding `KVM_DISPATCHER_REPOSITORY_<ALIAS>` mappings let an empty `repos.d` verify token access and runner-list permissions for both installations before any adapter is enabled. Do not commit a PEM, installation token, or generated credential.

The service receives the PEM only as `LoadCredentialEncrypted=app-key:...`. It signs short-lived RS256 JWTs with `openssl dgst -sha256 -sign` and exchanges them for installation tokens. Tokens are cached per installation and refreshed with less than ten minutes remaining. GitHub requests put authentication in curl's config stream on stdin, not in curl arguments. Job token copies are atomically refreshed while their units remain active, which lets a Qoral adapter that uses an indirect host token path keep cleanup working after a long job. The token is not copied into the guest.

Run the host wizard from a root-controlled terminal. Confirm the displayed action, paste the PEM with terminal echo disabled, and press Ctrl-D. `systemd-creds encrypt` consumes it on stdin; the wizard installs only the encrypted credential, writes an audit event to the journal, and leaves service activation to the operator.

## Configuration and adding a repository

1. Install the host scripts under `/opt/kvm-dispatcher/host/`, the service and drop-in under `/etc/systemd/system/`, and the polkit rule under `/etc/polkit-1/rules.d/`.
2. Install `kvm-dispatcher.sysusers.conf` and `kvm-dispatcher.tmpfiles.conf` into the systemd sysusers and tmpfiles configuration directories. Run `systemd-sysusers` and `systemd-tmpfiles --create`.
3. Copy `host/dispatcher.conf.example` to `/etc/kvm-dispatcher/dispatcher.conf`, set the App and installation IDs, and keep the file root-owned and readable by the `kvm-dispatcher` group. Use the wizard to install `app-key.cred`.
4. For every repository, install its adapter file in `/etc/kvm-dispatcher/repos.d/<name>.conf` and its own template unit `<adapter-unit>@.service`. The dispatcher reads adapter files at startup, so restart it after adding or changing adapters. Startup resync adopts running job units. Verify the installation before enabling the dispatcher.

A repository joins by shipping those two files:

- Its adapter config sets `KVM_DISPATCHER_REPO`, `KVM_DISPATCHER_INSTALLATION`, `KVM_DISPATCHER_LABELS`, `KVM_DISPATCHER_UNIT`, `KVM_DISPATCHER_RUNNER_NAME_PREFIX`, `KVM_DISPATCHER_MAX_UNIT_SECONDS`, `KVM_DISPATCHER_MEMORY_MIB`, and `KVM_DISPATCHER_CONCURRENCY`. See the QA2 and Qoral examples in `host/repos.d/`.
- Its `Restart=no` template unit runs the existing one-job script, loads the token with `LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token`, uses a per-instance runtime directory, and sets `MemoryAccounting=yes` so per-job peak usage is available. Do not add an idle restart loop. The unit must not require `github-token.cred`, since the dispatcher supplies the credential per job.
- `KVM_DISPATCHER_RUNNER_NAME_PREFIX` must exactly match the runner naming convention used by the existing job script. The allowed unit prefix and runner name are validated to avoid arbitrary systemd unit starts.
- For Qoral, set `QORAL_RUNNER_GITHUB_TOKEN_FILE=/run/kvm-dispatcher/jobs/%i/github-token` in the template and make its token-file helper honor that override. `LoadCredential` is a snapshot at unit start; the indirect host path is what lets the long-running script read a refreshed token for final runner deletion. QA2 can continue reading the systemd credential directory because its job duration is below one hour.

The polkit rule allows `kvm-dispatcher` to start or stop only `qa2`, `qoral`, and `qa2-agent-loop` runner-job templates with lowercase alphanumeric or hyphen instance names. It does not grant permission to manage legacy services or other systemd units.

## Operations

The normal observation commands are:

```sh
journalctl -fu kvm-dispatcher.service
jq . /var/lib/kvm-dispatcher/status.json
```

`status.json` has exactly these top-level fields:

```json
{
  "updated_at": "2026-01-01T00:00:00Z",
  "capacity_mib": 12288,
  "in_flight": [{"repo":"qniapp/qa2","job_id":"123","unit":"qa2-runner-job@123.service","since":"2026-01-01T00:00:00Z"}],
  "queued": [{"repo":"qorraq/qoral","job_id":"456","created_at":"2026-01-01T00:00:20Z"}],
  "last_poll": {"qniapp/qa2":{"http":"200","at":"2026-01-01T00:00:00Z"}},
  "blocked": [{"repo":"qniapp/qa2","job_id":"789","attempts":3,"reason":"start-failures"}]
}
```

The `queued` list omits jobs already claimed by a unit. `in_flight` includes only active units. A three-strike start failure can be retried by removing its JSON record from `/var/lib/kvm-dispatcher/attempts/` after investigating the failure. A `unit-already-ran` record means the worker unit exited while GitHub still reports that job queued; the dispatcher will not start the same job ID again, so rerun the workflow or remove that record only after investigating.

Journal events include:

- `token-refreshed installation=... expires_at=...`
- `job-discovered repo=... job=... age=...s`
- `job-started unit=...`
- `job-finished unit=... exit=... duration=...s memory_peak_mib=...`
- `job-cancelled unit=...`
- `orphan-runner-deleted repo=... runner=...`
- `poll-error http=... repo=... retry_in=...s`
- `job-start-failed`, `job-blocked`, `job-stuck`, and `job-swept` for state transitions and cleanup.

## Migration and rollback

For the planned QA2 and Qoral move, install the dispatcher with no adapters first and verify App-token access. Add the QA2 template and adapter, then switch only while QA2 is idle: confirm its runner is not busy, stop and disable `qa2-runner.service`, and let the dispatcher claim the queued work. Add Qoral only after QA2 is running under dispatch. Keep the legacy unit files installed but disabled while either repository's preflight still checks them. Do not create a Qoral PAT.

To roll back, stop and disable `kvm-dispatcher.service`, remove the affected adapter config, and re-enable the corresponding legacy runner service. Restore the legacy service's credential and configuration first if they were removed. Existing GitHub jobs remain queued unless a job had already been claimed; stop any active job template before re-enabling the legacy service.
