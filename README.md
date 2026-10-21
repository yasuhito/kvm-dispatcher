# kvm-dispatcher

Event-driven dispatcher that runs GitHub Actions jobs for several repositories on one KVM host.

It polls each registered repository for queued jobs, mints a one-job JIT runner configuration with a GitHub App installation token, boots that repository's disposable guest, and destroys the guest and the runner registration when the job ends. No idle guests hold the host; a concurrency limit replaces the exclusive idle lock.
