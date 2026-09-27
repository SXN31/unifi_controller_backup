# Unifi Controller Backup

Backs up one or more UniFi Network controllers via the API — including UniFi
OS controllers (UDM/UDM-Pro, UniFi OS Server, etc.) on port `11443`/`443`.
Each controller can have multiple sites; each gets its own dated `.unf` file
with automatic retention/cleanup.

## Requirements

* `bash`, `curl`.
* A **local** admin account on each controller with:
  * Network: **Full Management** (required — triggering a backup is a
    write operation; UniFi OS has no finer-grained "backup only" permission)
  * System/User management can stay **View Only**.
* Cloud accounts / MFA-enabled accounts are not supported by this API flow.

## Setup

1. Copy `config.sample` → `config` and set:
   * `UCB_LOG_FILE` — log file path
   * `BACKUP_DIR` — where `.unf` files are stored
2. Create a `controllers/` directory, and for each controller, copy
   `example.conf.sample` → `controllers/<name>.conf` and set:
   * `username` / `password` — the local admin account above
   * `baseurl` — e.g. `https://10.0.0.4:11443` (UniFi OS Server /
     self-hosted) or `https://10.0.0.4` (UniFi OS console, port 443)
   * `SITES` — space-separated site **IDs** from the URL, not display names
   * `UNIFI_HOSTNAME` — used in backup filenames/logs
   * `KEEP_BACKUP` — number of `.unf` files to retain per site

`config` and `*.conf` are gitignored since they hold real paths/credentials —
never commit them.

If any of these files were edited on Windows, strip CRLF line endings before
running on Linux/Synology (`sed -i 's/\r$//' <file>`), otherwise bash fails
with `$'\r': command not found`.

## Use

```
$ ./unifi_controller_backup.sh              # uses ./config and ./controllers
$ ./unifi_controller_backup.sh -c /path/to/config -d /path/to/controllers
$ ./unifi_controller_backup.sh -v           # verbose (bash -x, echoes log to stderr too)
$ ./unifi_controller_backup.sh -h           # help
```

Schedule it with cron or, on Synology, Task Scheduler. Note: when run from
Task Scheduler it executes as that task's configured user — that's what
grants access to a share like `BACKUP_DIR`. Running it manually as a
different user will reach the controller fine but can fail on that path.

Exit code is non-zero if any controller/site failed, so the scheduler can
alert on it.

### Sample log

```
2026-09-27 10:07:48: [INFO] Starting backup from the file controllers/example.conf
2026-09-27 10:07:48: [INFO] Finding sites for example-controller
2026-09-27 10:07:48: [INFO] Hostname: example-controller, Site: default -> Login
2026-09-27 10:07:48: [INFO] Hostname: example-controller, Site: default -> Requesting backup -> /backups/20260927-example-controller-default.unf
2026-09-27 10:07:59: [INFO] Hostname: example-controller, Site: default -> Size of ...default.unf is 24M
2026-09-27 10:07:59: [INFO] Hostname: example-controller, Site: default -> We must keep 10 backups and we have 1
2026-09-27 10:07:59: [INFO] Hostname: example-controller, Site: default -> No old copies to delete
2026-09-27 10:07:59: [INFO] Hostname: example-controller, Site: default -> Logout
2026-09-27 10:07:59: [INFO] Finished backup from the file controllers/example.conf
```

A failed step logs `[ERROR]` with the reason (login failure, permission
error, missing/unwritable backup dir, etc.) and processing continues with the
next site/controller rather than aborting the whole run.

## Limitations

* The account must have access to every site listed for its controller.
* Site names/IDs can't contain spaces.

## History

Originally based on [kamaxeon/ucb](https://github.com/kamaxeon/ucb) (2015,
classic controller API, unmaintained). Rewritten for UniFi OS: login moved to
`/api/auth/login` with CSRF tokens, and site endpoints moved under
`/proxy/network/api/s/<site>/...`.
