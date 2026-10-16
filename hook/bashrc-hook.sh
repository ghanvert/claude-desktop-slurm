if [ -n "${SSH_CONNECTION:-}" ] && [ -n "${BASH_EXECUTION_STRING:-}" ] && [ -z "${CLAUDE_DESKTOP_CONFINED:-}" ]; then
    printf '%s pid=%s cmd=%q\n' "$(date '+%F %T')" "$$" "$BASH_EXECUTION_STRING" \
        >> ~/.claude-desktop-ssh.log 2>/dev/null || true
    if [[ "$BASH_EXECUTION_STRING" == *"/.claude/remote/srv/"*"'--serve'"* ]] && [ -x "@LAUNCHER@" ]; then
        exec "@LAUNCHER@" "$BASH_EXECUTION_STRING"
    fi
fi
