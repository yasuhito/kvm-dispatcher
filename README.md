# kvm-dispatcher

A small GitHub Actions dispatcher for repositories that share one KVM host. The dispatcher starts an existing repository-specific worker unit only after finding a matching queued job. Runner scripts remain responsible for their JIT configuration, guest boot, job execution, and guest cleanup. This removes idle guests from the host without merging repository-specific VM code into the dispatcher.

The initial Beelink policy is one 12 GiB guest at a time. It records the guest cgroup's `memory.peak` after each unit exits so capacity can be reconsidered from measurements, not guesses.

## Host components

- `host/kvm_dispatcher.sh`: polling, scheduling, and in-flight monitoring loop.
- `host/kvm_dispatcher_lib.sh`: trusted shell config loading, GitHub App JWT and installation-token handling, job state, and status output.
- `host/kvm_dispatcher_host_wizard.sh`: encrypts a GitHub App PEM supplied through hidden terminal stdin. It does not enable or start the service.
- `host/systemd/`: service, isolation drop-in, sysusers, and tmpfiles configuration.
- `host/systemd/examples/`: the `20-job-runtime.conf` drop-ins that the QA2 and Qoral job templates need.
- `host/polkit/50-kvm-dispatcher.rules`: narrow authorization for starting and stopping only supported job templates.
- `host/repos.d/*.conf.example`: sample adapters. The QA2 and Qoral repositories ship their own adapter config and template service in their respective repositories.

Runtime secrets and job state live under `/run/kvm-dispatcher`. The service sets `RuntimeDirectoryPreserve=yes`, so a dispatcher restart or stop keeps the token paths that running jobs read; the startup sweep reconciles any stale state. `/run/kvm-dispatcher` and its `jobs` directory are mode 0711, so other users can traverse them but not list job IDs. Each `jobs/<job-id>` directory is 0750 and its `github-token` is 0640, owned `kvm-dispatcher:<adapter job group>` from that adapter's `KVM_DISPATCHER_JOB_GROUP`. A QA2 job user can read QA2 job tokens but not Qoral job tokens, and the reverse. The installation token cache and `state.json` stay private to the dispatcher. Retry and three-strike blocked records live under `/var/lib/kvm-dispatcher/attempts` so a host reboot does not silently unblock a repeatedly failing job. The status document is `/var/lib/kvm-dispatcher/status.json`, written by atomic rename.

## Scheduling and lifecycle

For each configured repository, one poll requests workflow runs in `queued`, `pending`, and `in_progress` status, then reads their jobs. A queued job is eligible only when it contains every adapter label. Run and job pagination uses 100-item pages. Candidate jobs are ordered by `created_at` across repositories. The dispatcher starts the next eligible job only when both its repository concurrency cap and the total `KVM_DISPATCHER_CAPACITY_MIB` allow it.

`KVM_DISPATCHER_PRIORITY` is empty by default, which gives global FIFO. Setting it to an adapter name such as `qa2` serves that adapter's queued jobs first while it has work; jobs within each adapter retain FIFO order. Remove the setting to return to global FIFO.

The lifecycle is:

1. `DISCOVERED`: a matching queued job is found and logged.
2. `CLAIMED`: the installation token is copied to `/run/kvm-dispatcher/jobs/<job-id>/github-token` and state is recorded.
3. `STARTED`, then `RUNNING`: start `<adapter-unit>@<job-id>.service` and monitor it.
4. `DONE`: the unit exits. Record exit status, duration, and `memory_peak_mib`.
5. `CANCELLED`: if a job is completed or no longer listed, its unit is stopped only while the unit's runner registration is online and idle and no job has ever been attributed to that runner. Attribution comes from the polled jobs' `runner_name` and, for a job no longer listed, `GET /actions/jobs/<id>`, and is recorded as `runner_attributed` in the job's `state.json` so it outlives the job's run leaving the polled list. Once the runner has run any job, or its registration is offline or gone, the unit is left to finish its own cleanup, with `MAX_UNIT_SECONDS` as the limit, and is then handled by the normal end-of-unit attribution and sweep.
6. `STUCK`: stop an active unit after its adapter's `MAX_UNIT_SECONDS` limit. `CANCELLED` and `STUCK` units also record exit status, duration, and `memory_peak_mib` after they stop.
7. `FAILED`: a failed systemd start is retried after 300 seconds. Three start failures block that job ID until an operator clears its attempt record.
8. `SWEPT`: if the job script did not delete its own registration, use a newly minted installation token to delete it, then remove that job's runtime state.

A JIT runner can take any queued job with matching labels, not necessarily the one that triggered its unit. When a unit exits, the dispatcher reads the runner name from that invocation's journal and asks GitHub which runner ran the triggering job. Only a job that this runner actually ran is consumed, shown in `blocked` as `unit-already-ran`; a triggering job that the runner did not run is logged as `job-not-run` with `reason=runner-idle` or, when the unit exited nonzero, `reason=exit-nonzero`. It counts as a start failure, so it returns to the candidates after 300 seconds and is blocked on the third strike, which stops a broken worker from relaunching guests without limit. When the runner or the job's `runner_name` cannot be determined, the dispatcher logs `job-attribution-unknown` and keeps the job consumed; rerun the workflow to get a new job ID. A systemd start failure is different because no worker unit was started, so it follows the 300-second retry and three-strike policy.

The job scripts keep their own runner names, such as `qa2-kvm-<UTC time>-<pid>`. The dispatcher identifies a job's registration from its unit instance journal, where the script logs `event=jitconfig-minted runner_id=<id> runner_name=<name>` and, after its own cleanup, `event=runner-deleted runner_id=<id>`. Only names under the adapter's `KVM_DISPATCHER_RUNNER_NAME_PREFIX` are ever deleted. The service runs with `SupplementaryGroups=systemd-journal` to read these journals.

The startup sweep adopts active configured `*-runner-job@*` units and sweeps stale state without an active unit. It then deletes registrations under an adapter's runner-name prefix that are offline, not busy, and not referenced by the journal of any active `*-runner-job@*` unit. If an active unit has no identifiable registration yet, the orphan sweep is skipped rather than risking a live runner. It does not delete registrations belonging to other prefixes.

GitHub API failures use per-adapter retry intervals of 20, 60, then 300 seconds. While one adapter is failing or backing off, the others keep scheduling in FIFO order among themselves, so one installation's outage does not stop another repository's CI. A skipped adapter's queued jobs re-enter the FIFO after its next successful poll. In-flight unit, timeout, and memory monitoring continues on every loop during those intervals.

## GitHub App and secrets

The GitHub App needs repository permissions:

- Administration: read and write, for JIT runner creation and runner deletion.
- Actions: read, for workflow run and job discovery.
- Metadata: read, required by GitHub.

Restrict each installation to only the repository it serves. The example IDs in `host/dispatcher.conf.example` are the existing App (`5405924`) and its QA2 and Qoral installations; replace them if using another App. `KVM_DISPATCHER_INSTALLATIONS` and the corresponding `KVM_DISPATCHER_REPOSITORY_<ALIAS>` mappings let an empty `repos.d` verify token access and runner-list permissions for both installations before any adapter is enabled. Do not commit a PEM, installation token, or generated credential.

The service receives the PEM only as `LoadCredentialEncrypted=app-key:...`. It signs short-lived RS256 JWTs with `openssl dgst -sha256 -sign` and exchanges them for installation tokens. Tokens are cached per installation and refreshed with less than ten minutes remaining. GitHub requests put authentication in curl's config stream on stdin, not in curl arguments. Job token copies are refreshed while their units remain active by writing a temporary file with the same group and 0640 mode and renaming it into place, which lets a Qoral adapter that uses an indirect host token path keep cleanup working after a long job. The token is not copied into the guest.

Run the host wizard from a root-controlled terminal. Confirm the displayed action, paste the PEM with terminal echo disabled, and press Ctrl-D. `systemd-creds encrypt` consumes it on stdin; the wizard installs only the encrypted credential, writes an audit event to the journal, and leaves service activation to the operator.

## Configuration and adding a repository

1. Install the host scripts under `/opt/kvm-dispatcher/host/`, the service and drop-in under `/etc/systemd/system/`, and the polkit rule under `/etc/polkit-1/rules.d/`.
2. Install `kvm-dispatcher.sysusers.conf` and `kvm-dispatcher.tmpfiles.conf` into the systemd sysusers and tmpfiles configuration directories. Run `systemd-sysusers` and `systemd-tmpfiles --create`. Once an adapter's job user exists, add the dispatcher to that adapter's job group, for example `usermod -aG qa2-runner-host kvm-dispatcher` and `usermod -aG qoral-runner-host kvm-dispatcher`. This is not done in sysusers because a membership line would create the group before the adapter's own sysusers file creates its user. The dispatcher checks its membership at startup and refuses to start without it.
3. Copy `host/dispatcher.conf.example` to `/etc/kvm-dispatcher/dispatcher.conf`, set the App and installation IDs, and keep the file root-owned and readable by the `kvm-dispatcher` group. Use the wizard to install `app-key.cred`.
4. For every repository, install its adapter file in `/etc/kvm-dispatcher/repos.d/<name>.conf` and its own template unit `<adapter-unit>@.service`. The dispatcher reads adapter files at startup, so restart it after adding or changing adapters. Startup resync adopts running job units. Verify the installation before enabling the dispatcher.

A repository joins by shipping those two files:

- Its adapter config sets `KVM_DISPATCHER_REPO`, `KVM_DISPATCHER_INSTALLATION`, `KVM_DISPATCHER_LABELS`, `KVM_DISPATCHER_UNIT`, `KVM_DISPATCHER_RUNNER_NAME_PREFIX`, `KVM_DISPATCHER_MAX_UNIT_SECONDS`, `KVM_DISPATCHER_MEMORY_MIB`, `KVM_DISPATCHER_CONCURRENCY`, and `KVM_DISPATCHER_JOB_GROUP` (the primary group of its job template's `User=`). See the QA2 and Qoral examples in `host/repos.d/`.
- Its `Restart=no` template unit runs the existing one-job script, loads the token with `LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token`, and sets `MemoryAccounting=yes` so per-job peak usage is available. Do not add an idle restart loop. The unit must not require `github-token.cred`, since the dispatcher supplies the credential per job.
- Keep both drop-ins under `<adapter-unit>@.service.d/`: the repository's own `10-isolation.conf` for its isolation policy, and `20-job-runtime.conf` from `host/systemd/examples/`. `RuntimeDirectory=` is list-valued and re-specifying it appends, so `20-job-runtime.conf` first clears the shared directory set by `10-isolation.conf` and then sets a per-job `RuntimeDirectory` with `RuntimeDirectoryMode=0700`. Without it, `RUNTIME_DIRECTORY` would name two directories and concurrent instances would share one.
- `KVM_DISPATCHER_RUNNER_NAME_PREFIX` must be the common prefix of the runner names the existing job script generates, for example `qa2-kvm-`. The allowed unit prefix and runner name are validated to avoid arbitrary systemd unit starts.
- For Qoral, set `QORAL_RUNNER_GITHUB_TOKEN_FILE=/run/kvm-dispatcher/jobs/%i/github-token` in the template and make its token-file helper honor that override. `LoadCredential` is a snapshot at unit start; the indirect host path is what lets the long-running script read a refreshed token for final runner deletion. QA2 can continue reading the systemd credential directory because its job duration is below one hour.

The polkit rule allows `kvm-dispatcher` to start or stop only the `qa2` and `qoral` runner-job templates with lowercase alphanumeric or hyphen instance names. It does not grant permission to manage legacy services or other systemd units. When a third adapter is actually shipped, add its template name to both the `allowedUnit` expression in `host/polkit/50-kvm-dispatcher.rules` and the `KVM_DISPATCHER_UNIT` check in `kvd_load_config`, then extend the polkit cases in `host/kvm_dispatcher_host_test.sh`.

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

The `queued` list omits jobs already claimed by a unit. `in_flight` includes only active units. A three-strike start failure can be retried by removing its JSON record from `/var/lib/kvm-dispatcher/attempts/` after investigating the failure. A `unit-already-ran` record means a worker unit ran that job, or its runner could not be attributed, while GitHub still reports the job queued; the dispatcher will not start the same job ID again, so rerun the workflow or remove that record only after investigating.

Journal events include:

- `token-refreshed installation=... expires_at=...`
- `job-discovered repo=... job=... age=...s`
- `job-started unit=...`
- `job-finished unit=... exit=... duration=...s memory_peak_mib=... outcome=done|cancelled|stuck`
- `job-cancelled unit=...`
- `orphan-runner-deleted repo=... runner=...`
- `orphan-sweep-skipped unit=... reason=...`
- `poll-error http=... repo=... retry_in=...s`, and `poll-error repo=... skipped=true retry_in=...s` for each loop an adapter spends in backoff
- `job-not-run repo=... job=... runner=... reason=runner-idle|exit-nonzero` and `job-attribution-unknown repo=... job=...`
- `job-start-failed`, `job-blocked`, `job-stuck`, and `job-swept` for state transitions and cleanup.

## Migration and rollback

For the planned QA2 and Qoral move, install the dispatcher with no adapters first and verify App-token access. Add the QA2 template and adapter, then switch only while QA2 is idle: confirm its runner is not busy, stop and disable `qa2-runner.service`, and let the dispatcher claim the queued work. Add Qoral only after QA2 is running under dispatch. Keep the legacy unit files installed but disabled while either repository's preflight still checks them. Do not create a Qoral PAT.

To roll back, stop and disable `kvm-dispatcher.service`, remove the affected adapter config, and re-enable the corresponding legacy runner service. Restore the legacy service's credential and configuration first if they were removed. Existing GitHub jobs remain queued unless a job had already been claimed; stop any active job template before re-enabling the legacy service.
