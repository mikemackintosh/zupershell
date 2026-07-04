# myterm

A macOS terminal emulator with a **built-in, tamper-evident audit tap** — native
EDR-from-inside-the-terminal for Claude Code and other AI coding agents.

- **Full VT via SwiftTerm** — parser, grid, Metal renderer, PTY. No hand-written
  state machine.
- **Sensors** on OSC 52 (clipboard), OSC 133 (command marks + text via a pure-zsh
  shell integration), OSC 7 (cwd), plus title / resize / process events.
- **Signed JSONL** — every record HMAC-SHA256 hash-chained to the previous, so
  tampering with any line breaks the chain from that point forward.
- **Policy hook** — clipboard writes can be logged-and-blocked, not just logged.

## Build

```sh
swift build              # debug
swift run                # debug + launch
./bundle.sh              # release .app in ./myterm.app
./bundle.sh --run        # + open it
```

## Shell integration (recommended)

Sources OSC 133 command marks + OSC 7 cwd from any shell — no p10k / starship
dependency. Self-gates on `TERM_PROGRAM=myterm`, so it's inert everywhere else.

```sh
# ~/.zshrc
[[ -f ~/src/myterm/shell-integration.zsh ]] && source ~/src/myterm/shell-integration.zsh
```

## Audit log

- Location: `~/.myterm/audit-<session>.jsonl`
- HMAC key: `~/.myterm/audit.key` (0600, per-machine)
- Verify a log: `swift verify-audit.swift ~/.myterm/audit-*.jsonl`
- Live tail:   `tail -f ~/.myterm/audit-*.jsonl | jq -c '{type,cmd,exit,dir,preview}'`

## Layout

```
Package.swift                   SwiftTerm dependency
Sources/myterm/
    main.swift                  window, PTY, sensors, policy
    AuditLog.swift              HMAC hash-chained JSONL writer
verify-audit.swift              chain verifier (independent script)
shell-integration.zsh           zsh preexec/precmd → OSC 133 + OSC 7
bundle.sh                       reproducible .app builder
```
