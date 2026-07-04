# ─────────────────────────────────────────────────────────────────────────────
# myterm shell integration — pure zsh, no dependencies.
#
# Emits OSC 133 semantic command marks + OSC 7 cwd so myterm's audit tap can
# record command_start / command_end (+ exit code) and directory changes,
# independent of your prompt framework (p10k, starship, plain).
#
# Install: add this one guarded line to ~/.zshrc
#     [[ -f ~/src/myterm/shell-integration.zsh ]] && source ~/src/myterm/shell-integration.zsh
#
# Self-gates on TERM_PROGRAM=myterm, so it is completely inert in every other
# terminal (iTerm, Terminal.app, etc.).
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$TERM_PROGRAM" == "myterm" ]]; then
  autoload -Uz add-zsh-hook

  # Before each command runs (user hit enter): mark output start (C).
  # Piggyback the command text (base64 so control chars in $1 can't break OSC
  # parsing) as the C phase's argument: '133;C;<b64>'. myterm's OSC 133 handler
  # decodes it into the 'cmd' audit field.
  _myterm_preexec() {
    local b64
    b64=$(print -rn -- "$1" | base64 | tr -d '\n')
    print -n "\e]133;C;${b64}\a"
  }

  # Before each prompt is drawn: mark the previous command's end with its exit
  # status (D;<code>), and report the current directory (OSC 7).
  _myterm_precmd() {
    local ec=$?
    print -n "\e]133;D;${ec}\a"
    print -n "\e]7;file://${HOST}${PWD}\a"
    print -n '\e]133;A\a'          # next prompt start
  }

  add-zsh-hook preexec _myterm_preexec
  add-zsh-hook precmd  _myterm_precmd
fi
