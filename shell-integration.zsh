# ─────────────────────────────────────────────────────────────────────────────
# zupershell (zush) shell integration — pure zsh, no dependencies.
#
# Emits OSC 133 semantic command marks + OSC 7 cwd so zupershell's audit tap
# can record command_start / command_end (+ exit code + command text) and
# directory changes, independent of your prompt framework (p10k, starship,
# plain).
#
# Install: add this one guarded line to ~/.zshrc
#     [[ -f ~/src/zupershell/shell-integration.zsh ]] && source ~/src/zupershell/shell-integration.zsh
#
# Self-gates on TERM_PROGRAM=zupershell, so it is completely inert in every
# other terminal (iTerm, Terminal.app, etc.).
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$TERM_PROGRAM" == "zupershell" ]]; then
  autoload -Uz add-zsh-hook

  # Before each command runs (user hit enter): mark output start (C).
  # Piggyback the command text (base64 so control chars in $1 can't break OSC
  # parsing) as the C phase's argument: '133;C;<b64>'. zupershell's OSC 133
  # handler decodes it into the 'cmd' audit field.
  _zupershell_preexec() {
    local b64
    b64=$(print -rn -- "$1" | base64 | tr -d '\n')
    print -n "\e]133;C;${b64}\a"
  }

  # Before each prompt is drawn: mark the previous command's end with its exit
  # status (D;<code>), and report the current directory (OSC 7).
  _zupershell_precmd() {
    local ec=$?
    print -n "\e]133;D;${ec}\a"
    print -n "\e]7;file://${HOST}${PWD}\a"
    print -n '\e]133;A\a'          # next prompt start
  }

  add-zsh-hook preexec _zupershell_preexec
  add-zsh-hook precmd  _zupershell_precmd
fi
