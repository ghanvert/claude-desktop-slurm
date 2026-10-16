# claude-desktop-slurm

Run every Claude desktop **SSH session** on a remote Linux host inside **one resource
container**: a Slurm job, or a systemd user scope. It needs no root and no change to the app.

The Claude desktop app can open a session on a remote machine over SSH. In that mode it starts a
daemon on the host, and the daemon starts Claude, shell-mode commands and the terminal. All of
them run directly on the host, outside any scheduler and with no resource limit. On a cluster
where all work must go through Slurm, or on a shared server where one user must not take every
core, that is a problem.

This repo adds a small hook at the top of `~/.bashrc`. When ssh runs the daemon's start command,
the hook sends it to a launcher, and the launcher starts the daemon inside a container. All
later processes of the daemon stay in that container.

| Method | Container | Use it when |
|---|---|---|
| `slurm` | One `sbatch` job (`claude-desktop`) | The host is a Slurm node and work outside Slurm is not allowed |
| `systemd` | One transient user scope (`claude-desktop-*.scope`) with `MemoryMax` / `CPUQuota` | The host has no Slurm, but has systemd with cgroup v2 |

## Requirements

Both methods:

- Your login shell on the host is **bash**. sshd runs remote commands as `bash -c "<command>"`, and
  bash reads `~/.bashrc` first. The hook depends on this.
- Linux, and the Claude desktop app with SSH sessions (tested with desktop 2.42304.0, CLI 2.1.299).

`slurm`:

- `sbatch`, `scancel`, `jq` on the host.
- The host is a node of the partition that the job uses. The daemon's socket is in your home
  directory, and the SSH bridge outside the job must reach it.
- A QoS where a small job starts in seconds. The app waits for the start command (at most
  `START_TIMEOUT`, 120 s by default).

`systemd` (no root needed if the host meets these):

| Requirement | Why | Check |
|---|---|---|
| cgroup v2 | Limits on user units need v2 | `stat -fc %T /sys/fs/cgroup` → `cgroup2fs` |
| Delegated controllers | `MemoryMax` needs `memory`, `CPUQuota` needs `cpu` | `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers` |
| A user manager | `systemd-run --user` talks to it | `systemctl --user show-environment` |
| Linger (recommended) | Without it, systemd stops the user manager, and the daemon, at your last logout | `loginctl show-user $USER -p Linger`; turn on with `loginctl enable-linger` |

Most current distributions (Ubuntu 22.04+, Debian 12+, Fedora) meet these by default. Some admins
block `loginctl enable-linger` for users, or delegate only `memory` and `pids`. `install.sh`
checks each item and warns you.

> **Do not use the `systemd` method on a Slurm cluster.** The scope is outside Slurm, so the
> cluster's rules (and any watchdog that kills processes outside Slurm) still apply to it.

## Install

On the remote host:

```bash
git clone git@github.com:ghanvert/claude-desktop-slurm.git
cd claude-desktop-slurm
./install.sh slurm        # or: ./install.sh systemd
```

`install.sh`:

1. Checks the requirements of the method.
2. Copies the launcher to `~/.local/bin/claude-desktop-<method>` (change with `--bindir DIR`).
3. Creates `~/.config/claude-desktop-slurm/<method>.conf` from the example, if it is missing.
4. Backs up `~/.bashrc` to `~/.bashrc.bak-claude-desktop-<date>`, and puts the hook block at the
   top, between `# >>> claude-desktop-slurm >>>` and `# <<< claude-desktop-slurm <<<`.
   It checks the new file with `bash -n` before it writes it.

Run it again with the other method to switch. The old block is replaced.

Then make the app start a new daemon through the hook:

1. **Keep a second ssh login open** until step 4 works. A broken `~/.bashrc` can break new ssh
   commands.
2. Stop the running daemon. This ends the desktop SSH sessions that run now:
   ```bash
   pkill -u "$USER" -f '\.claude/remote/srv/.*/server --serve'
   ```
3. Open a new SSH session in the Claude desktop app and send a message.
4. Check it:
   ```bash
   squeue -u "$USER" -n claude-desktop                               # slurm
   systemctl --user list-units --type=scope 'claude-desktop-*'       # systemd
   ```

## Configure

Edit `~/.config/claude-desktop-slurm/<method>.conf`. A change applies to the next daemon, not
to the one that runs now.

`slurm.conf` (an empty value means the cluster's default):

```bash
CPUS=8              # --cpus-per-task, shared by all desktop sessions
MEM=32G             # --mem
GPUS=0              # --gres=gpu:N
TIME=               # --time, e.g. 14-00:00:00
ACCOUNT=            # --account
QOS=                # --qos
PARTITION=          # --partition
JOB_NAME=claude-desktop
START_TIMEOUT=120
```

`systemd.conf`:

```bash
CPUS=8              # CPUQuota = CPUS x 100%; empty = no CPU limit
MEM=32G             # MemoryMax
TASKS_MAX=          # TasksMax
UNIT_PREFIX=claude-desktop
```

## Uninstall

```bash
./uninstall.sh
```

It removes the hook block (after a backup) and the launchers. It keeps the config and the logs.
A running daemon continues in its job or scope until it stops. To stop it now:
`scancel -n claude-desktop` or `systemctl --user stop 'claude-desktop-*.scope'`.

## How it works

### What the app does on the host

When the app connects, it sends these commands, each over its own SSH channel:

1. `sftp-server`, and a probe (`printenv HOME; uname -sm; id -u ...`).
2. `server --install --cli-dir ~/.claude/remote/ccd-cli ...`: installs the CLI that the app uses.
3. `server --stop --socket S && server --serve --socket S --token-file T`: starts the **daemon**.
4. `server --bridge --socket S`, one per connection: links the SSH channel to the daemon's socket.

`server` is `~/.claude/remote/srv/<hash>/server` and `S` is `~/.claude/remote/run/<id>/rpc.sock`.

`--serve` forks into the background and returns. The daemon then has parent PID 1 and its own
session, so it outlives the SSH connection. When you start a chat, the daemon starts the CLI
(`ccd-cli`) as its child. The terminal and shell mode are its children too. So every process that
does work descends from the daemon, and the daemon is the one place to control.

```
desktop app ──ssh──▶ bash -c "<cmd>" ──(hook in ~/.bashrc)──▶ claude-desktop-<method> '<cmd>'
                                                                   │
                                     ┌─────────────────────────────▼───────────────────────┐
                                     │  Slurm job "claude-desktop"  /  systemd user scope  │
                                     │    server --serve  (daemon, rpc.sock)               │
                                     │      ├── ccd-cli   (session 1)                      │
                                     │      ├── ccd-cli   (session 2)                      │
                                     │      └── bash      (terminal)                       │
                                     └─────────────────────────────▲───────────────────────┘
desktop app ──ssh──▶ server --bridge  (outside, copies bytes) ─────┘ unix socket
```

### The hook

```bash
if [ -n "${SSH_CONNECTION:-}" ] && [ -n "${BASH_EXECUTION_STRING:-}" ] && [ -z "${CLAUDE_DESKTOP_CONFINED:-}" ]; then
    printf '%s pid=%s cmd=%q\n' "$(date '+%F %T')" "$$" "$BASH_EXECUTION_STRING" \
        >> ~/.claude-desktop-ssh.log 2>/dev/null || true
    if [[ "$BASH_EXECUTION_STRING" == *"/.claude/remote/srv/"*"'--serve'"* ]] && [ -x "<launcher>" ]; then
        exec "<launcher>" "$BASH_EXECUTION_STRING"
    fi
fi
```

- In `~/.bashrc`, `$BASH_EXECUTION_STRING` holds the text of the command that sshd asked bash to
  run. So the hook can see the command before it runs, and replace the shell with the launcher.
- It acts only on ssh commands (`SSH_CONNECTION`) that are non-interactive
  (`BASH_EXECUTION_STRING`). Logins and local shells pass through.
- It redirects only the command that has the daemon path and the quoted `'--serve'`. `--bridge`,
  `--install` and `sftp` run as before.
- The launchers set `CLAUDE_DESKTOP_CONFINED`, so the same command inside the container runs for
  real and does not loop back into the launcher.
- It logs every non-interactive ssh command to `~/.claude-desktop-ssh.log`. If an app update
  breaks the redirect, this log shows the new start command.
- It must be at the very top, before the usual "not interactive, return" check.

A forced command in `~/.ssh/authorized_keys` is the usual way to rewrite ssh commands, but on
many clusters that file belongs to root. `~/.bashrc` is always yours.

### `slurm`: `claude-desktop-slurm`

1. It reads the socket path out of the command, to find the daemon's `daemon.lock`.
2. It clears `SLURM_*` (so `sbatch` always makes a new job) and submits **itself** with
   `--_job` and the original command.
3. In the job, it runs the command. The daemon forks, but Slurm's `proctrack/cgroup` keeps it in
   the job's cgroup, whatever its parent PID. The script reads the daemon PID from
   `daemon.lock`, writes the command's exit status, and then checks every 30 s whether the daemon
   is alive. A batch job kills everything left in its cgroup when the script exits, so the
   script must hold. When the daemon exits, the job ends.
4. Outside, the launcher waits for the status file, then prints the command's output and exits
   with its status. To the app, the ssh command looks the same as before.

Job logs: `~/.claude/remote/slurm/<jobid>.log`.

> If your cluster uses `proctrack/linuxproc` or `pgid` instead of `cgroup`, a forked daemon can
> escape the job. Check with `scontrol show config | grep ProctrackType`.

### `systemd`: `claude-desktop-systemd`

```bash
exec systemd-run --user --scope --quiet --collect --unit=claude-desktop-<time>-<pid> \
    -p MemoryMax=32G -p CPUQuota=800% bash -c "<cmd>"
```

`systemd-run --scope` makes a new transient scope with the limits, and runs the command in the
foreground, in that scope. So ssh gets the command's output and exit status unchanged. The daemon
forks but stays in the scope's cgroup. The scope ends when its last process exits.

### Why all sessions share one container

The app keeps one daemon per host and finds it again through `rpc.sock`. A second session, or a
reconnection, sends only `--bridge`, which the hook does not touch. The new session is a new
`ccd-cli` child of the same daemon, in the same container. One job or scope serves all desktop
sessions until the daemon stops.

## Limits

- **Shared resources.** All desktop sessions share one job or scope. Two heavy sessions compete.
  Send GPU or long work to its own job.
- **The container ends the sessions.** When the job reaches its time limit, or you `scancel` it
  or stop the scope, the daemon and all its sessions stop. The next connection starts a new one.
- **The start command stops the old daemon.** It begins with `server --stop`. If the app decides
  to start a new daemon (for example, after an update), the running sessions stop.
- **It depends on internal app behavior.** If an update changes the start command, the hook no
  longer matches and the daemon starts on the host again, outside the container. Nothing breaks,
  but the limits do not apply. Look at `~/.claude-desktop-ssh.log`.
- **Not Remote Control.** Desktop SSH sessions do not show in claude.ai/code or the mobile app,
  even with `remoteControlAtStartup: true`: in its stream-json mode, the CLI leaves that decision
  to the app. Type `/rc` in a session to control it from elsewhere.
- **Only bash.** With zsh or another login shell, sshd does not read `~/.bashrc`.

## Tested

- **`slurm`:** used with the real desktop app on a Slurm 8-GPU node (`proctrack/cgroup`). The
  daemon, two sessions and their tools ran in one job. The repo's install path was also tested
  end to end with a fake daemon: hook → `sbatch` → job started in ~1 s, and the job ended when
  the daemon exited.
- **`systemd`:** the launcher was tested with a stand-in `systemd-run` (options, output, exit
  status), and `install.sh` passed its checks on systemd 255. It was **not** yet tested with the
  real app and a real scope.

## Troubleshooting

| Symptom | Look at |
|---|---|
| The app cannot connect | `tail ~/.claude-desktop-ssh.log`; run `bash -n ~/.bashrc`; restore a backup `~/.bashrc.bak-claude-desktop-*` |
| `job ... did not start the daemon within 120 s` | `squeue -u $USER` (pending reason); the account / QoS / partition in `slurm.conf` |
| The daemon still runs outside the container | Was the old daemon stopped? Does the start command in the log still match `'--serve'`? |
| `Failed to connect to bus` (systemd) | `systemctl --user show-environment`; is linger on; is `XDG_RUNTIME_DIR` set? |
| Limits have no effect (systemd) | The delegated controllers, see Requirements |

## Files

```
bin/claude-desktop-slurm      launcher + batch job for the slurm method
bin/claude-desktop-systemd    launcher for the systemd method
hook/bashrc-hook.sh           the hook block (install.sh fills in the launcher path)
config/*.conf.example         default settings
install.sh / uninstall.sh
```
