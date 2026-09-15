# SMB Backup Toolkit

Small Linux backup utility for copying or archiving data between SMB/CIFS shares without embedding infrastructure credentials in source code.

The repository preserves the history of several real SMB backup scripts while replacing environment-specific IP addresses, passwords, Telegram credentials, and archive passwords with a reusable configuration model.

## What it does

`backup-job.sh` supports two modes:

- `sync` — copy a mounted SMB source to an SMB target with `rsync`;
- `archive` — create timestamped `tar.gz` archives, validate them with `tar -t`, and write a SHA-256 sidecar.

The source share is mounted read-only. The target is mounted read-write. CIFS authentication is supplied through separate root-only credentials files.

## Requirements

Linux host with:

- Bash 4+;
- `cifs-utils`;
- `util-linux` (`mountpoint`, `flock`);
- `rsync` for sync jobs;
- GNU `tar`, `findutils`, and `sha256sum` for archive jobs.

Backup execution requires root because it mounts CIFS filesystems. Configuration validation can be run without mounting anything:

```bash
sudo ./backup-job.sh --config /etc/backup-toolkit/job.conf --check-config
```

## Installation

Install the script:

```bash
sudo install -m 0750 backup-job.sh /usr/local/sbin/backup-toolkit
```

Create the configuration directory:

```bash
sudo install -d -m 0750 /etc/backup-toolkit
```

Copy one of the examples:

```bash
sudo install -m 0640 config/job-sync.conf.example /etc/backup-toolkit/job.conf
```

Create independent credentials files for the source and target shares. Example format:

```text
username=backup-user
password=replace-with-real-password
domain=EXAMPLE
```

Install them with restrictive permissions:

```bash
sudo install -m 0600 source.credentials /etc/backup-toolkit/source.credentials
sudo install -m 0600 target.credentials /etc/backup-toolkit/target.credentials
```

Do not commit real credentials.

## Sync mode

Use `config/job-sync.conf.example` as the starting point.

By default, the job does **not** delete files from the destination. `RSYNC_DELETE='true'` enables `rsync --delete-delay` and should be treated as a destructive policy decision.

The script uses a non-blocking `flock` lock so overlapping scheduled jobs fail instead of running concurrently.

## Archive mode

Use `config/job-archive.conf.example`.

`INCLUDE_PATHS` contains source-relative paths. The script:

1. checks each path exists;
2. writes a `.partial` archive in the destination;
3. validates the archive with `tar -tzf`;
4. atomically renames it to the final filename;
5. writes a SHA-256 sidecar;
6. optionally removes archives older than `RETENTION_DAYS`.

The archive mode intentionally does not implement password-protected ZIP/7z archives. Passing archive passwords on command lines exposes them through process arguments, and encryption key management belongs outside this utility.

## Scheduling with systemd

Examples are provided under `systemd/`.

The timer example runs weekly on Thursday at 12:30 with a small randomized delay:

```bash
sudo install -m 0644 systemd/backup-toolkit.service.example /etc/systemd/system/backup-toolkit.service
sudo install -m 0644 systemd/backup-toolkit.timer.example /etc/systemd/system/backup-toolkit.timer
sudo systemctl daemon-reload
sudo systemctl enable --now backup-toolkit.timer
```

Check scheduling and results with:

```bash
systemctl list-timers backup-toolkit.timer
journalctl -u backup-toolkit.service
```

## Failure and cleanup model

The script does not use `ping` as an availability test. CIFS mount success is the authoritative check.

A trap records which shares were mounted by the current invocation and only unmounts those shares on exit. Pre-existing mounts are left alone.

## Security model

- no usernames/passwords in repository scripts;
- no Telegram tokens or chat IDs;
- credentials files must be root-owned and inaccessible to group/others;
- job configuration must be root-owned and not writable by group/others;
- source share is mounted `ro`;
- both CIFS mounts use `nosuid,nodev,noexec`;
- mount file/dir modes are restricted instead of `0777`;
- no `sudo` calls are embedded inside the scheduled root job;
- `sync` deletion is opt-in;
- archive output is validated before publication.

## Historical credentials note

Earlier revisions of the original `backup_share1`, `backup_share2`, and `backup_share3` experiments used environment-specific example credentials and notification values directly in source code. Those values were test data rather than production secrets, but the current implementation still treats credentials as external root-only configuration and keeps them out of source control.

## CI

GitHub Actions performs:

- Bash syntax validation;
- ShellCheck;
- configuration validation against safe examples;
- checks that source files do not contain obvious embedded password/token patterns.

CI intentionally does not mount real SMB shares.

## Scope

This is a small infrastructure utility, not a replacement for enterprise backup software. It does not provide snapshots, immutable storage, catalogues, application-consistent quiescing, encryption key management, off-site replication, or restore orchestration.

## Repository history

This repository is the consolidated successor to the historical `backup_share1`, `backup_share2`, and `backup_share3` experiments. The redundant companion repositories have been retired.

No license has been selected yet.
