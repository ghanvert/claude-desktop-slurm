#!/usr/bin/env bash
# Install the hook that starts the Claude desktop SSH daemon in Slurm or systemd.
#
#   ./install.sh slurm|systemd [--bindir DIR]
#
# Copies the launcher to DIR (default ~/.local/bin), creates the config file if
# it is missing, and puts the hook block at the top of ~/.bashrc (after a
# backup). Run it again to switch methods; the old block is replaced.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bindir=$HOME/.local/bin
method=""
while [ $# -gt 0 ]; do
    case "$1" in
        slurm|systemd) method=$1; shift ;;
        --bindir) [ $# -ge 2 ] || { echo "--bindir needs a directory" >&2; exit 2; }; bindir=$2; shift 2 ;;
        -h|--help) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$method" ] || { echo "Usage: $0 slurm|systemd [--bindir DIR]" >&2; exit 2; }

warn() { echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
[ "$(basename "${SHELL:-}")" = bash ] || warn "your login shell is ${SHELL:-unknown}, not bash: sshd will not read ~/.bashrc."
if [ "$method" = slurm ]; then
    for c in sbatch scancel jq realpath; do command -v "$c" >/dev/null || die "'$c' not found."; done
else
    command -v systemd-run >/dev/null || die "'systemd-run' not found."
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    systemctl --user show-environment >/dev/null 2>&1 \
        || die "no systemd user manager is reachable (systemctl --user fails)."
    [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ] \
        || warn "cgroup v2 is not mounted at /sys/fs/cgroup: MemoryMax and CPUQuota have no effect."
    uid=$(id -u)
    ctl=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers
    if [ -r "$ctl" ]; then
        grep -qw memory "$ctl" || warn "the memory controller is not delegated to you: MemoryMax has no effect."
        grep -qw cpu "$ctl" || warn "the cpu controller is not delegated to you: CPUQuota has no effect."
    else
        warn "cannot read $ctl: cannot check which limits work."
    fi
    [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] \
        || warn "linger is off: the daemon stops at your last logout. Turn it on with: loginctl enable-linger"
fi

# --- launcher and config -----------------------------------------------------
launcher=$bindir/claude-desktop-$method
mkdir -p "$bindir"
install -m 755 "$here/bin/claude-desktop-$method" "$launcher"
echo "Installed $launcher"

confdir=$HOME/.config/claude-desktop-slurm
mkdir -p "$confdir"
if [ -f "$confdir/$method.conf" ]; then
    echo "Kept $confdir/$method.conf"
else
    cp "$here/config/$method.conf.example" "$confdir/$method.conf"
    echo "Created $confdir/$method.conf (edit it to change the resources)"
fi

# --- hook block in ~/.bashrc -------------------------------------------------
rc=$HOME/.bashrc
begin='# >>> claude-desktop-slurm >>>'
end='# <<< claude-desktop-slurm <<<'
touch "$rc"
backup=$rc.bak-claude-desktop-$(date +%Y%m%d-%H%M%S)
cp -p "$rc" "$backup"

new=$(mktemp)
{
    echo "$begin"
    echo "# Start the Claude desktop SSH daemon through $method (installed by claude-desktop-slurm)."
    echo "# Must stay at the top: it acts on non-interactive ssh commands."
    sed "s|@LAUNCHER@|$launcher|" "$here/hook/bashrc-hook.sh"
    echo "$end"
    echo
    # the old file without an earlier block
    awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0; next}' "$rc" \
        | awk 'BEGIN {lead = 1} lead && /^$/ {next} {lead = 0; print}'
} >"$new"

if ! bash -n "$new"; then
    rm -f "$new"
    die "the new ~/.bashrc has a syntax error; nothing changed (backup: $backup)."
fi
cat "$new" >"$rc"
rm -f "$new"
echo "Added the hook to $rc (backup: $backup)"

cat <<EOF

Next steps:
  1. Keep a second ssh login open until the next step works.
  2. Stop the running desktop daemon, so the app starts a new one through the hook:
       pkill -u "\$USER" -f '\.claude/remote/srv/.*/server --serve'
     This ends the desktop SSH sessions that run now.
  3. Open a new SSH session in the Claude desktop app.
  4. Check it:
EOF
if [ "$method" = slurm ]; then
    echo "       squeue -u \"\$USER\" -n claude-desktop"
else
    echo "       systemctl --user list-units --type=scope 'claude-desktop-*'"
fi
