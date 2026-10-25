# kvm-dispatcher

A small GitHub Actions dispatcher for repositories that share one KVM host. The dispatcher starts an existing repository-specific worker unit only after finding a matching queued job. Runner scripts remain responsible for their JIT configuration, guest boot, job execution, and guest cleanup. This removes idle guests from the host without merging repository-specific VM code into the dispatcher.

The initial Beelink policy is one 12 GiB guest at a time. It samples each job unit's cgroup `memory.peak` while the unit is active, because systemd discards it once the unit exits, and records the maximum as `memory_peak_mib` so capacity can be reconsidered from measurements, not guesses.

## Host components

- `host/kvm_dispatcher.sh`: polling, scheduling, and in-flight monitoring loop.
- `host/kvm_dispatcher_lib.sh`: trusted shell config loading, GitHub App JWT and installation-token handling, job state, and status output.
- `host/kvm_dispatcher_install_wizard.sh`: the root-only, staged core-install entry point. It installs files, applies sysusers/tmpfiles and group membership, invokes the PEM wizard, and runs the no-adapter probe without enabling or starting the service.
- `host/kvm_dispatcher_host_wizard.sh`: the PEM stage used by the install wizard. It encrypts a GitHub App PEM supplied through hidden terminal stdin and refuses to overwrite an existing credential.
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

Run `host/kvm_dispatcher_install_wizard.sh` from the root of a clean checkout in a root-controlled terminal. It prints the checkout HEAD and asks for confirmation separately before each stage. The PEM stage invokes `host/kvm_dispatcher_host_wizard.sh`; paste the PEM with terminal echo disabled and press Ctrl-D. `systemd-creds encrypt` consumes it on stdin, and only the encrypted credential is installed. Each stage writes an audit event to the journal. The install and verification stages never enable or start `kvm-dispatcher.service`.

## Configuration and adding a repository

### Core installation and verification

On Beelink, obtain the reviewed source revision in a new checkout. Pin it to the commit approved for installation, then run the single install wizard from the checkout root:

```sh
mkdir -p "$HOME/src"
git clone --branch main --single-branch https://github.com/yasuhito/kvm-dispatcher "$HOME/src/kvm-dispatcher"
git -C "$HOME/src/kvm-dispatcher" checkout --detach <approved-commit>
```

From that checkout's root, run:

```sh
sudo ./host/kvm_dispatcher_install_wizard.sh
```

The wizard refuses a dirty checkout, prints the HEAD commit for confirmation, and asks before every stage: preflight, core-file placement, identity/configuration, hidden PEM entry, and the no-adapter verification probe. It can run one stage again with `--stage preflight|install|identity|pem|verify`; identical files are skipped and differing files are never overwritten. `--rollback` implements the pre-adapter rollback and refuses to proceed if `repos.d` is non-empty. Do not run `--rollback` after installing adapters. The wizard never creates the QA2 or Qoral job groups and never enables or starts `kvm-dispatcher.service`.

`KVM_DISPATCHER_INSTALL_ROOT` is reserved for tests that place files in a temporary fake root. With it set, only `--stage install` is allowed; it does not invoke system-changing commands or provide a way to install into the live host.

The file-placement table is retained as a reference for manual inspection. The wizard checks every listed path, skips a matching file with the expected owner and mode, and refuses a differing file.

| Checkout source | Destination | Owner:group | Mode |
|---|---|---|---:|
| `host/kvm_dispatcher.sh` | `/opt/kvm-dispatcher/host/kvm_dispatcher.sh` | `root:root` | `0755` |
| `host/kvm_dispatcher_lib.sh` | `/opt/kvm-dispatcher/host/kvm_dispatcher_lib.sh` | `root:root` | `0644` |
| `host/kvm_dispatcher_host_wizard.sh` | `/opt/kvm-dispatcher/host/kvm_dispatcher_host_wizard.sh` | `root:root` | `0755` |
| `host/systemd/kvm-dispatcher.service` | `/etc/systemd/system/kvm-dispatcher.service` | `root:root` | `0644` |
| `host/systemd/kvm-dispatcher.service.d/10-isolation.conf` | `/etc/systemd/system/kvm-dispatcher.service.d/10-isolation.conf` | `root:root` | `0644` |
| `host/polkit/50-kvm-dispatcher.rules` | `/etc/polkit-1/rules.d/50-kvm-dispatcher.rules` | `root:root` | `0644` |
| `host/systemd/kvm-dispatcher.sysusers.conf` | `/etc/sysusers.d/kvm-dispatcher.conf` | `root:root` | `0644` |
| `host/systemd/kvm-dispatcher.tmpfiles.conf` | `/etc/tmpfiles.d/kvm-dispatcher.conf` | `root:root` | `0644` |
| `host/dispatcher.conf.example` | `/etc/kvm-dispatcher/dispatcher.conf` | `root:kvm-dispatcher` | `0640` |
| wizard output (no plaintext file) | `/etc/kvm-dispatcher/app-key.cred` | `root:root` | `0600` |

The test script and adapter examples are not installed by the core wizard. After the no-adapter probe passes, a repository joins by shipping its adapter config and unit:

- Its adapter config sets `KVM_DISPATCHER_REPO`, `KVM_DISPATCHER_INSTALLATION`, `KVM_DISPATCHER_LABELS`, `KVM_DISPATCHER_UNIT`, `KVM_DISPATCHER_RUNNER_NAME_PREFIX`, `KVM_DISPATCHER_MAX_UNIT_SECONDS`, `KVM_DISPATCHER_MEMORY_MIB`, `KVM_DISPATCHER_CONCURRENCY`, and `KVM_DISPATCHER_JOB_GROUP` (the primary group of its job template's `User=`). See the QA2 and Qoral examples in `host/repos.d/`.
- Its template unit runs the existing one-job script and loads the per-job token with `LoadCredential=github-token:/run/kvm-dispatcher/jobs/%i/github-token`. The effective unit must set `Restart=no` and `MemoryAccounting=yes`, and it must not require `github-token.cred` because the dispatcher supplies the credential per job.
- Keep both drop-ins under `<adapter-unit>@.service.d/`: the repository's own `10-isolation.conf` for its isolation policy, and `20-job-runtime.conf` from `host/systemd/examples/`. The 20 drop-in sets `Restart=no` and `MemoryAccounting=yes`. `RuntimeDirectory=` is list-valued and re-specifying it appends, so the drop-in first clears the shared directory set by `10-isolation.conf` and then sets a per-job directory with `RuntimeDirectoryMode=0700`. Without it, `RUNTIME_DIRECTORY` would name two directories and concurrent instances would share one.
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
  "in_flight": [{"repo":"qniapp/qa2","job_id":"123","unit":"qa2-runner-job@123.service","since":"2026-01-01T00:00:00Z","memory_peak_mib":10240}],
  "queued": [{"repo":"qorraq/qoral","job_id":"456","created_at":"2026-01-01T00:00:20Z"}],
  "last_poll": {"qniapp/qa2":{"http":"200","at":"2026-01-01T00:00:00Z"}},
  "blocked": [{"repo":"qniapp/qa2","job_id":"789","attempts":3,"reason":"start-failures"}],
  "recent": [{"repo":"qorraq/qoral","job_id":"455","unit":"qoral-runner-job@455.service","outcome":"done","started_at":"2025-12-31T22:00:00Z","finished_at":"2025-12-31T23:30:00Z","duration_s":5400,"memory_peak_mib":11800,"exit_status":0}]
}
```

`memory_peak_mib` is the largest cgroup `memory.peak` sampled so far, in MiB, or `null` before any sample. `recent` holds the newest 20 finished jobs, newest first, with `outcome` `done`, `cancelled`, or `stuck`; `exit_status` is `null` when systemd did not report one. The history is kept in `/var/lib/kvm-dispatcher/recent.json`, so it survives dispatcher restarts and reboots. If that file is not exactly one JSON array of objects, the dispatcher logs `recent-history-invalid` and treats the history as empty until the next finished job rewrites it.

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
- `recent-history-invalid file=...` when the persisted recent history cannot be read.

## Migration and rollback

Install and verify the dispatcher with no adapters first. Before adding an adapter, `sudo ./host/kvm_dispatcher_install_wizard.sh --rollback` removes the core installation. It refuses to proceed if `repos.d` contains any entry and never changes either legacy runner service.

Run the Japanese cutover wizard from a clean kvm-dispatcher checkout on the host:

```sh
sudo ./host/kvm_dispatcher_cutover_wizard.sh
```

Choose the QA2 stage first, or run it directly with `--stage qa2`. Enter the QA2 repository checkout when prompted. The wizard checks its template and installed runner files, checks the current runner journal, and asks you to confirm from GitHub Actions that QA2 is idle. It then installs the template, both drop-ins, and the adapter, stops and disables `qa2-runner.service`, and enables and starts the dispatcher. It checks the resulting unit states, a fresh QA2 HTTP 200, and the dispatcher journal before it reports success. It does not remove the legacy unit file.

Wait for one successful QA2 job under dispatch before adding Qoral. Run `sudo ./host/kvm_dispatcher_cutover_wizard.sh --stage qoral` and enter a clean Qoral checkout containing the job template, isolation drop-in, runner script, library, isolation check, and `QORAL_RUNNER_GITHUB_TOKEN_FILE` support. The wizard requires a successful QA2 job in `status.json` and the dispatcher journal. It installs the Qoral template, both drop-ins, and the local Qoral adapter example, restarts the dispatcher, and verifies a fresh Qoral HTTP 200. It never asks for or creates a Qoral PAT. Both legacy unit files remain installed and disabled.

The current Qoral `main` checkout lacks the dispatcher job template and token-file override; those artifacts are in [Qoral pull request 3](https://github.com/qorraq/qoral/pull/3). Until they are merged, use a clean source checkout that contains them. The wizard refuses to proceed when any required source artifact is missing.

After an adapter is installed, do not use the pre-adapter install wizard rollback. Choose `--rollback qa2` or `--rollback qoral` in the cutover wizard. It stops the dispatcher before stopping active job templates, then removes only the selected adapter and re-enables the corresponding legacy service. If the QA2 adapter remains during Qoral rollback, it restarts the dispatcher with QA2 still configured; it refuses QA2 rollback until Qoral has been rolled back first. To return both repositories to legacy mode, run Qoral rollback first and QA2 rollback second. The wizard does not remove templates or drop-ins. Restore legacy configuration and credentials first if they were removed, and confirm they are ready without displaying their contents. Existing GitHub jobs remain queued unless the dispatcher already claimed them.
