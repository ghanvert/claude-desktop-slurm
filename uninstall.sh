#!/usr/bin/env bash
# Remove the hook block from ~/.bashrc and the launchers.
#
#   ./uninstall.sh [--bindir DIR]
#
# Keeps ~/.config/claude-desktop-slurm and the logs. A running daemon keeps
# running in its job or scope until it stops.
set -euo pipefail

bindir=$HOME/.local/bin
[ "${1:-}" != --bindir ] || { bindir=$2; shift 2; }

rc=$HOME/.bashrc
begin='# >>> claude-desktop-slurm >>>'
end='# <<< claude-desktop-slurm <<<'
if [ -f "$rc" ] && grep -qxF "$begin" "$rc"; then
    backup=$rc.bak-claude-desktop-$(date +%Y%m%d-%H%M%S)
    cp -p "$rc" "$backup"
    new=$(mktemp)
    awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$rc" \
        | awk 'BEGIN {lead = 1} lead && /^$/ {next} {lead = 0; print}' >"$new"
    bash -n "$new" || { rm -f "$new"; echo "ERROR: result has a syntax error; nothing changed." >&2; exit 1; }
    cat "$new" >"$rc"
    rm -f "$new"
    echo "Removed the hook from $rc (backup: $backup)"
else
    echo "No hook block in $rc"
fi

for m in slurm systemd; do
    if [ -f "$bindir/claude-desktop-$m" ]; then
        rm -f "$bindir/claude-desktop-$m"
        echo "Removed $bindir/claude-desktop-$m"
    fi
done
