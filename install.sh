#!/usr/bin/env bash
# Install or upgrade Bot HQ on an Orgo computer that runs a Hermes agent. Run it ON that computer, as root.
#
#   curl -fsSL <releases>/install.sh | bash                                    install, or upgrade to the latest
#   curl -fsSL <releases>/install.sh | bash -s -- --url https://<name>-xxxx.web.orgo.dev
#   bash install.sh --file hq-app-0.2.0.tgz [--url https://...]               from a pack already on the computer
#
# Options:
#   --url <address>   the computer's public web address (first install only; asked for when missing)
#   --from <address>  where releases are kept (the folder holding `latest`); also HQ_RELEASES
#   --version <v>     install that version instead of the latest; also HQ_VERSION
#   --file <pack>     use this pack instead of downloading one (its <pack>.sha256 is checked when present)
#
# A first install writes the settings file once, then, when it runs in a terminal, asks there for
# what a new Bot HQ needs: the Orgo key, a Tailscale auth key (for the private address and coding
# machines), the Composio and xAI keys, and the owner's name and email. Keys are typed hidden, and go
# to the app on this computer in a request body, never on a command line or into a file or log; the
# app tests each one with the same checks as the setup wizard in the browser. Any question can be
# skipped with Enter, and the setup link printed at the end asks for whatever was skipped. With no
# terminal (a script, or Orgo's bash API) it asks nothing and prints the link.
#
# An upgrade keeps the settings and the data, makes a checked backup first, and puts the previous code
# back if the new version does not start.
#
# Optional, as before (first install only): PORT (8787), PRIMARY_CDP_URL (DevTools URL of the main
# agent's own Chrome, if it has one), DEV_LOGIN=1 (test machines only), T3_PROXY (e.g.
# http://127.0.0.1:1055 where Tailscale runs in userspace mode, to reach coding machines),
# PRIMARY_BOT_NAME, PRIMARY_BOT_LABEL. To skip the wizard's questions, the keys can still be given up
# front: ORGO_COMPUTER_ID, ALLOWED_EMAILS, and KEYS_FILE (lines XAI_API_KEY=, COMPOSIO_API_KEY=,
# ORGO_API_KEY=; deleted afterwards).
#
# Hermes: on a first install whose Hermes agent has its API server switched off, it switches it on (in
# Hermes's .env, as Bot HQ does for a teammate's computer) and restarts that agent once. It then gives
# the main agent the app's tools (add-hq-to-hermes.py, which checks its edit of Hermes's config.yaml).
# Nothing else of Hermes's is changed, and an upgrade never restarts it.
#
# Everything is inside functions and `main` runs on the last line, so a download cut short by
# `curl | bash` changes nothing.

# "a && b || stop ..." is used on purpose throughout: stop when any step of it fails.
# shellcheck disable=SC2015
set -euo pipefail

# Where releases are published (scripts/publish-release.mjs puts them there). release.sh writes the
# address it was given into this line of the copy it publishes.
HQ_DEFAULT_RELEASES="https://raw.githubusercontent.com/Onyx-Dev-Labs/bot-hq-releases/main"
PLACEHOLDER_RELEASES="https://releases.invalid/bot-hq"

# Every path and command comes from a variable whose default is the real one on the computer, so the
# automated test (server/test/installer.test.ts) can run all of this inside a temporary folder with
# stand-ins. Nobody needs to set these on a real computer.
ROOT="${HQ_ROOT:-}"
HQ_DIR="$ROOT/opt/hq"
APP="$HQ_DIR/app"
NEW="$HQ_DIR/app.new"        # the new code is made ready here while the old one keeps running
PREV="$HQ_DIR/app.prev"      # the old code waits here until the new one is healthy
FAILED="$HQ_DIR/app.failed"
DATA="$HQ_DIR/data"
NODE_DIR="$HQ_DIR/node"
BACKUPS="$HQ_DIR/backups"
LOGS="$ROOT/var/log/hq"
SUPERVISOR_DIR="${HQ_SUPERVISOR_DIR:-$ROOT/etc/supervisor/conf.d}"
CONF="$SUPERVISOR_DIR/hq-app.conf"
HERMES_HOME_DIR="${HERMES_HOME_PRIMARY:-$ROOT/root/.hermes}"
SUPERVISORCTL="${HQ_SUPERVISORCTL:-supervisorctl}"
CURL="${HQ_CURL:-curl}"
TTY="${HQ_TTY:-/dev/tty}"
OS="${HQ_OS:-$(uname -s)}"
ARCH="${HQ_ARCH:-$(uname -m)}"
USER_ID="${HQ_USER_ID:-$(id -u)}"
MIN_FREE_MB="${HQ_MIN_FREE_MB:-500}"
KEEP_BACKUPS="${HQ_KEEP_BACKUPS:-10}"
HEALTH_WAIT="${HQ_HEALTH_WAIT:-60}"
HERMES_WAIT="${HQ_HERMES_WAIT:-90}"
NET_POLLS="${HQ_NET_POLLS:-160}"    # how many times to ask how joining Tailscale goes (it downloads Tailscale first)
POLL="${HQ_POLL_SECONDS:-3}"
METADATA="${HQ_METADATA:-http://169.254.169.254}"
NODE_V=v22.21.1
NODE_SITE="${HQ_NODE_SITE:-https://nodejs.org/dist}"

# ---------------------------------------------------------------- how it looks
# In a terminal: the logo, colors, a spinner while a step runs and ✓ or ✗ when it ends, questions set
# out one by one, and text wrapped to the window. Anywhere else (a log, a script, Orgo's bash API, the
# tests), or with NO_COLOR or TERM=dumb: plain lines with the same words, no colors, spinners or box
# characters. Nothing here changes what the installer does.

FANCY=0; TRUECOLOR=0; COLS=80; TEXT_W=80
c_o="" c_cream="" c_dim="" c_ok="" c_err="" c_b="" c_u="" c_n="" c_hl=""
ui_init() {
  if [ -t 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then FANCY=1; fi
  [ "$FANCY" = 1 ] || return 0
  local c; c="$(tput cols 2>/dev/null || true)"
  if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 40 ]; then COLS="$c"; fi
  TEXT_W=$(( COLS < 100 ? COLS : 100 ))
  # The mark's orange and cream, a quiet gray, and green and red for what worked and what did not: in
  # 24-bit color when the terminal says it has it, else the nearest of 256.
  case "${COLORTERM:-}" in truecolor|24bit) TRUECOLOR=1 ;; esac
  if [ "$TRUECOLOR" = 1 ]; then
    c_o=$'\033[38;2;253;127;1m' c_cream=$'\033[38;2;248;239;229m' c_dim=$'\033[38;2;139;145;141m'
    c_ok=$'\033[38;2;60;207;122m' c_err=$'\033[38;2;255;107;107m' c_hl=$'\033[48;2;253;127;1m\033[38;2;20;23;22m\033[1m'
  else
    c_o=$'\033[38;5;208m' c_cream=$'\033[38;5;230m' c_dim=$'\033[38;5;245m'
    c_ok=$'\033[38;5;78m' c_err=$'\033[38;5;203m' c_hl=$'\033[48;5;208m\033[38;5;234m\033[1m'
  fi
  c_b=$'\033[1m' c_u=$'\033[4m' c_n=$'\033[0m'
}

say() { [ -z "$SPIN_PID" ] || spin_off; printf '%s\n' "$@"; }

# Text wrapped to the window between words (in a terminal; elsewhere one line). $1 the first line's
# lead, $2 the next lines' lead, $3 how wide a lead is, $4 the text, $5 its color.
wrapped() {
  local lead="$1" next="$2" indent="$3" text="$4" color="${5:-}" width line="" word words=()
  if [ "$FANCY" = 0 ]; then printf '%s%s\n' "$lead" "$text"; return 0; fi
  width=$(( TEXT_W - indent )); [ "$width" -ge 20 ] || width=20
  read -ra words <<<"$text" || true
  for word in ${words[@]+"${words[@]}"}; do
    if [ -n "$line" ] && [ $(( ${#line} + 1 + ${#word} )) -gt "$width" ]; then
      printf '%s%s%s%s\n' "$lead" "$color" "$line" "$c_n"; lead="$next"; line="$word"
    else line="${line:+$line }$word"; fi
  done
  printf '%s%s%s%s\n' "$lead" "$color" "$line" "$c_n"
}
rule() { [ "$FANCY" = 0 ] || { local r; printf -v r '%*s' "$COLS" ''; printf '%s%s%s\n' "$c_o" "${r// /━}" "$c_n"; }; }

# A step: a spinner while it runs (in a terminal; elsewhere "What it does..."), then one line saying
# how it went, with the detail dimmed on the right. A spinner needs no ending of its own: step_ok,
# step_warn, step_fail, say and stop all end it.
SPIN_PID=""; STEP=""
spin() {
  [ "$FANCY" = 1 ] || return 0
  [ -z "$SPIN_PID" ] || spin_off
  local label="$1" max=$(( COLS - 8 ))
  [ "${#label}" -le "$max" ] || label="${label:0:max}"
  printf '\033[?25l'
  (
    trap - ERR; set +e
    while :; do
      for f in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do printf '\r  %s%s%s %s %s…%s\033[K' "$c_o" "$f" "$c_n" "$label" "$c_dim" "$c_n"; sleep 0.1; done
    done
  ) &
  SPIN_PID=$!
  disown "$SPIN_PID" 2>/dev/null || true
}
spin_off() {
  [ -n "$SPIN_PID" ] || return 0
  local pid="$SPIN_PID" i=0
  SPIN_PID=""
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.02; i=$((i + 1)); done
  printf '\r\033[K\033[?25h'
}
step() { STEP="$1"; if [ "$FANCY" = 1 ]; then spin "$1"; else say "$1..."; fi; }
step_end() { spin_off; STEP=""; }
# $1 the mark, $2 its color, $3 what happened, $4 the detail.
step_line() {
  step_end
  if [ "$FANCY" = 0 ]; then say "$3${4:+ ($4)}"; return 0; fi
  local pad=$(( 48 - 4 - ${#3} ))
  if [ -z "$4" ]; then printf '  %s%s%s %s\n' "$2" "$1" "$c_n" "$3"
  elif [ "$pad" -ge 2 ] && [ $(( 48 + ${#4} )) -le "$COLS" ]; then printf '  %s%s%s %s%*s%s%s%s\n' "$2" "$1" "$c_n" "$3" "$pad" '' "$c_dim" "$4" "$c_n"
  else printf '  %s%s%s %s\n' "$2" "$1" "$c_n" "$3"; wrapped "    " "    " 4 "$4" "$c_dim"; fi
}
step_ok() { step_line ✓ "$c_ok" "$1" "${2:-}"; }
step_warn() { step_line '!' "$c_o" "$1" "${2:-}"; }
step_fail() { [ -z "$STEP" ] || { local s="$STEP"; step_end; [ "$FANCY" = 0 ] || printf '  %s✗ %s%s\n' "$c_err" "$s" "$c_n"; }; spin_off; }
note() { if [ "$FANCY" = 1 ]; then spin_off; wrapped "  ${c_o}!${c_n} " "    " 4 "$1"; else say "$1"; fi; }

# Lines behind a red bar, the first in bold: a refusal, with the same words as in the browser. $1 is
# 1 when the last line is the "try again" that follows them (dimmed).
redbar() {
  local tail="$1" i=0 n line color; shift; n=$#
  for line in "$@"; do
    i=$((i + 1))
    if [ "$FANCY" = 0 ]; then printf '  | %s\n' "$line"; continue; fi
    color=""; [ "$i" != 1 ] || color="$c_err$c_b"; { [ "$tail" = 1 ] && [ "$i" = "$n" ]; } && color="$c_dim"
    case "$line" in
      "  "*) printf '  %s┃%s %s\n' "$c_err" "$c_n" "$line" ;;   # a command: kept whole, to copy
      *) wrapped "  ${c_err}┃${c_n} " "  ${c_err}┃${c_n} " 4 "$line" "$color" ;;
    esac
  done
}

# The logo: the three robots of assets/brand, drawn by hand as 24 x 24 pixels (. nothing, C cream,
# O orange, D the dark outline), two pixel rows to a character: ▀ in the top pixel's color on the
# bottom one's, or ▄ when only the bottom one is filled. Below, the grid made into those characters,
# once, in 24-bit color and in the 256 colors of a terminal that does not say it has more.
#   .....CC..........CC.....   ....C..C........C..C....
#   ....C..C........C..C....   .....CC..........CC.....
#   .....CC..........CC.....   ....CCCCC......CCCCC....
#   ...CCCCCCC.DD.CCCCCCC...   ..CCDDDDDCDOODCDDDDDCC..
#   C.CDCCDCCDOOOODCCDCCDC.C   C.CDCCDCCDOOOODCCDCCDC.C
#   C.CDCCDCCDDOODDCCDCCDC.C   C.CCDDDDDCDOODCDDDDDCC.C
#   ...CCCCCDDDOODDDCCCCC...   ....CCDDOOOOOOOODDCC....
#   .....DOOOOOOOOOOOOD.....   ....DOOOOOOOOOOOOOOD....
#   ...DDOODDDDDDDDDDOODD...   ..DODODDCCDDDDCCDDODOD..
#   .DOODODDCCDDDDCCDDODOOD.   .DOODODDCCDDDDCCDDODOOD.
#   .DOODOODDDDDDDDDDOODOOD.   ..DODDOOOOOOOOOOOODDOD..
#   .......DOOOOOOOOD.......   ........DDDDDDDD........
LOGO_256=(
  $'    \e[38;5;230m▄▀▀▄        ▄▀▀▄\e[0m'
  $'    \e[38;5;230m▀▄▄▀        ▀▄▄▀\e[0m'
  $'    \e[38;5;230m▄\e[48;5;230m▀▀\e[49m▄▄      ▄▄\e[48;5;230m▀▀\e[49m▄\e[0m'
  $'  \e[38;5;230m▄\e[48;5;230m▀\e[48;5;235m▀▀▀▀▀\e[48;5;230m▀\e[49;38;5;235m▄\e[48;5;208m▀▀\e[49m▄\e[48;5;230;38;5;230m▀\e[48;5;235m▀▀▀▀▀\e[48;5;230m▀\e[49m▄\e[0m'
  $'\e[48;5;230;38;5;230m▀\e[49m \e[48;5;230m▀\e[48;5;235;38;5;235m▀\e[48;5;230;38;5;230m▀▀\e[48;5;235;38;5;235m▀\e[48;5;230;38;5;230m▀▀\e[48;5;235;38;5;235m▀\e[48;5;208;38;5;208m▀▀▀▀\e[48;5;235;38;5;235m▀\e[48;5;230;38;5;230m▀▀\e[48;5;235;38;5;235m▀\e[48;5;230;38;5;230m▀▀\e[48;5;235;38;5;235m▀\e[48;5;230;38;5;230m▀\e[49m \e[48;5;230m▀\e[0m'
  $'\e[48;5;230;38;5;230m▀\e[49m \e[48;5;230m▀\e[38;5;235m▀\e[48;5;235;38;5;230m▀▀\e[38;5;235m▀\e[38;5;230m▀▀\e[48;5;230;38;5;235m▀\e[48;5;235m▀\e[48;5;208;38;5;208m▀▀\e[48;5;235;38;5;235m▀\e[48;5;230m▀\e[48;5;235;38;5;230m▀▀\e[38;5;235m▀\e[38;5;230m▀▀\e[48;5;230;38;5;235m▀\e[38;5;230m▀\e[49m \e[48;5;230m▀\e[0m'
  $'   \e[38;5;230m▀\e[48;5;230m▀▀\e[48;5;235m▀▀\e[48;5;208;38;5;235m▀▀▀\e[38;5;208m▀▀\e[38;5;235m▀▀▀\e[48;5;235;38;5;230m▀▀\e[48;5;230m▀▀\e[49m▀\e[0m'
  $'    \e[38;5;235m▄\e[48;5;208m▀\e[38;5;208m▀▀▀▀▀▀▀▀▀▀▀▀\e[38;5;235m▀\e[49m▄\e[0m'
  $'  \e[38;5;235m▄\e[48;5;208m▀\e[48;5;235m▀\e[48;5;208;38;5;208m▀\e[48;5;235m▀\e[38;5;235m▀\e[48;5;230m▀▀\e[48;5;235m▀▀▀▀\e[48;5;230m▀▀\e[48;5;235m▀\e[38;5;208m▀\e[48;5;208m▀\e[48;5;235;38;5;235m▀\e[48;5;208m▀\e[49m▄\e[0m'
  $' \e[48;5;235;38;5;235m▀\e[48;5;208;38;5;208m▀▀\e[48;5;235;38;5;235m▀\e[48;5;208;38;5;208m▀\e[48;5;235;38;5;235m▀▀\e[48;5;230;38;5;230m▀▀\e[48;5;235;38;5;235m▀▀▀▀\e[48;5;230;38;5;230m▀▀\e[48;5;235;38;5;235m▀▀\e[48;5;208;38;5;208m▀\e[48;5;235;38;5;235m▀\e[48;5;208;38;5;208m▀▀\e[48;5;235;38;5;235m▀\e[49m\e[0m'
  $' \e[38;5;235m▀\e[48;5;235;38;5;208m▀\e[48;5;208m▀\e[48;5;235;38;5;235m▀\e[38;5;208m▀\e[48;5;208m▀\e[38;5;235m▀▀▀▀▀▀▀▀▀▀\e[38;5;208m▀\e[48;5;235m▀\e[38;5;235m▀\e[48;5;208;38;5;208m▀\e[48;5;235m▀\e[49;38;5;235m▀\e[0m'
  $'       \e[38;5;235m▀\e[48;5;235;38;5;208m▀▀▀▀▀▀▀▀\e[49;38;5;235m▀\e[0m'
)
LOGO_24=(
  $'    \e[38;2;248;239;229m▄▀▀▄        ▄▀▀▄\e[0m'
  $'    \e[38;2;248;239;229m▀▄▄▀        ▀▄▄▀\e[0m'
  $'    \e[38;2;248;239;229m▄\e[48;2;248;239;229m▀▀\e[49m▄▄      ▄▄\e[48;2;248;239;229m▀▀\e[49m▄\e[0m'
  $'  \e[38;2;248;239;229m▄\e[48;2;248;239;229m▀\e[48;2;30;36;34m▀▀▀▀▀\e[48;2;248;239;229m▀\e[49;38;2;30;36;34m▄\e[48;2;253;127;1m▀▀\e[49m▄\e[48;2;248;239;229;38;2;248;239;229m▀\e[48;2;30;36;34m▀▀▀▀▀\e[48;2;248;239;229m▀\e[49m▄\e[0m'
  $'\e[48;2;248;239;229;38;2;248;239;229m▀\e[49m \e[48;2;248;239;229m▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;248;239;229;38;2;248;239;229m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;248;239;229;38;2;248;239;229m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀▀▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;248;239;229;38;2;248;239;229m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;248;239;229;38;2;248;239;229m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;248;239;229;38;2;248;239;229m▀\e[49m \e[48;2;248;239;229m▀\e[0m'
  $'\e[48;2;248;239;229;38;2;248;239;229m▀\e[49m \e[48;2;248;239;229m▀\e[38;2;30;36;34m▀\e[48;2;30;36;34;38;2;248;239;229m▀▀\e[38;2;30;36;34m▀\e[38;2;248;239;229m▀▀\e[48;2;248;239;229;38;2;30;36;34m▀\e[48;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;248;239;229m▀\e[48;2;30;36;34;38;2;248;239;229m▀▀\e[38;2;30;36;34m▀\e[38;2;248;239;229m▀▀\e[48;2;248;239;229;38;2;30;36;34m▀\e[38;2;248;239;229m▀\e[49m \e[48;2;248;239;229m▀\e[0m'
  $'   \e[38;2;248;239;229m▀\e[48;2;248;239;229m▀▀\e[48;2;30;36;34m▀▀\e[48;2;253;127;1;38;2;30;36;34m▀▀▀\e[38;2;253;127;1m▀▀\e[38;2;30;36;34m▀▀▀\e[48;2;30;36;34;38;2;248;239;229m▀▀\e[48;2;248;239;229m▀▀\e[49m▀\e[0m'
  $'    \e[38;2;30;36;34m▄\e[48;2;253;127;1m▀\e[38;2;253;127;1m▀▀▀▀▀▀▀▀▀▀▀▀\e[38;2;30;36;34m▀\e[49m▄\e[0m'
  $'  \e[38;2;30;36;34m▄\e[48;2;253;127;1m▀\e[48;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀\e[48;2;30;36;34m▀\e[38;2;30;36;34m▀\e[48;2;248;239;229m▀▀\e[48;2;30;36;34m▀▀▀▀\e[48;2;248;239;229m▀▀\e[48;2;30;36;34m▀\e[38;2;253;127;1m▀\e[48;2;253;127;1m▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;253;127;1m▀\e[49m▄\e[0m'
  $' \e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀\e[48;2;30;36;34;38;2;30;36;34m▀▀\e[48;2;248;239;229;38;2;248;239;229m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀▀▀▀\e[48;2;248;239;229;38;2;248;239;229m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀▀\e[48;2;253;127;1;38;2;253;127;1m▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[49m\e[0m'
  $' \e[38;2;30;36;34m▀\e[48;2;30;36;34;38;2;253;127;1m▀\e[48;2;253;127;1m▀\e[48;2;30;36;34;38;2;30;36;34m▀\e[38;2;253;127;1m▀\e[48;2;253;127;1m▀\e[38;2;30;36;34m▀▀▀▀▀▀▀▀▀▀\e[38;2;253;127;1m▀\e[48;2;30;36;34m▀\e[38;2;30;36;34m▀\e[48;2;253;127;1;38;2;253;127;1m▀\e[48;2;30;36;34m▀\e[49;38;2;30;36;34m▀\e[0m'
  $'       \e[38;2;30;36;34m▀\e[48;2;30;36;34;38;2;253;127;1m▀▀▀▀▀▀▀▀\e[49;38;2;30;36;34m▀\e[0m'
)
logo() {
  if [ "$TRUECOLOR" = 1 ]; then printf '   %s\n' "${LOGO_24[@]}"; else printf '   %s\n' "${LOGO_256[@]}"; fi
}
# $1 what this run does, $2 a line under it.
banner() {
  if [ "$FANCY" = 0 ]; then say "bothq · $1"; return 0; fi
  printf '\n'
  [ "$COLS" -lt 40 ] || { logo; printf '\n'; }
  printf '   %s%sbot%s%s%shq%s  %s·  %s%s\n' "$c_cream" "$c_b" "$c_n" "$c_o" "$c_b" "$c_n" "$c_dim" "$1" "$c_n"
  [ -z "${2:-}" ] || wrapped "   " "   " 3 "$2" "$c_dim"
  printf '\n'
}

# ---------------------------------------------------------------- a question, set out
# "[1/5] Orgo  the computer your Bots work on", what it is, where to get one, then the prompt.
q_head() { printf '\n  %s%s%s%s%s%s%s%s  %s%s%s\n' "$c_o" "$c_b" "$1" "$c_n" "${2:+ }" "$c_b" "$2" "$c_n" "$c_dim" "$3" "$c_n"; }
q_info() { wrapped "        " "        " 8 "$1"; }
q_where() { printf '        %sGet one at%s %s%s%s\n' "$c_dim" "$c_n" "$c_u" "$1" "$c_n"; }
q_ok() { if [ "$FANCY" = 1 ]; then wrapped "  ${c_ok}✓${c_n} " "    " 4 "$1" "$c_ok"; else say "  $1"; fi; }
q_more() { if [ "$FANCY" = 1 ]; then wrapped "    " "    " 4 "$1"; else say "    $1"; fi; }
Q_DONE=()   # what the questions came to: +Orgo when answered, -Orgo when skipped
skipped() {
  Q_DONE+=("-$1")
  if [ "$FANCY" = 1 ]; then printf '  %s–  Skipped: the browser asks for it.%s\n' "$c_dim" "$c_n"; else say "  - Skipped: the browser asks for it."; fi
}
answered() { Q_DONE+=("+$1"); }

# Anything that fails without its own message: say so, and whether Bot HQ was changed.
on_err() {
  # Inside $(...) a failure is the caller's to handle (the trap is inherited there too).
  [ "${BASH_SUBSHELL:-0}" = 0 ] || return 0
  trap - ERR
  if [ "${FINISHED:-0}" = 1 ]; then
    stop "Bot HQ $NEW_LABEL is installed and running, but the installer stopped unexpectedly (line $1) while tidying up."
  elif [ "${SWAPPED:-0}" = 1 ]; then
    stop "The installer stopped unexpectedly (line $1) after switching versions." \
         "Run the same command again: it puts the version from before back first, then tries again."
  elif [ "${STOPPED_APP:-0}" = 1 ]; then
    sv_start
    stop "The installer stopped unexpectedly (line $1) while switching versions; the version from before was started again." \
         "Run the same command again."
  fi
  stop "The installer stopped unexpectedly (line $1). Bot HQ was not changed. Run the same command again."
}
# Stop with a message for the person at the terminal. Everything that calls this before the swap
# has changed nothing (or has undone what it did).
stop() {
  step_fail
  printf '\n' >&2
  if [ "$FANCY" = 1 ]; then redbar 0 "$@" >&2; printf '\n' >&2; else printf '%s\n' "$@" >&2; fi
  exit 1
}

usage() {
  if [ "$FANCY" = 1 ]; then
    local o="$c_o" d="$c_dim" n="$c_n"
    printf '\n   %s%sbot%s%s%shq%s  %s·  Install or upgrade Bot HQ%s\n' "$c_cream" "$c_b" "$n" "$o" "$c_b" "$n" "$d" "$n"
    printf '   %sOn an Orgo computer that runs a Hermes agent, as root.%s\n\n' "$d" "$n"
    printf '   Install, or upgrade to the latest:\n     curl -fsSL <releases>/install.sh | bash\n'
    printf '   A first install, without being asked for the address:\n     curl -fsSL <releases>/install.sh | bash -s -- --url <address>\n\n'
    printf '   %s--url%s <address>    %sthe public address Orgo shows for port 8787%s\n' "$o" "$n" "$d" "$n"
    printf '                      %s(like https://<name>-xxxx.web.orgo.dev)%s\n' "$d" "$n"
    printf '   %s--from%s <address>   %swhere releases are kept (the folder holding latest)%s\n' "$o" "$n" "$d" "$n"
    printf '   %s--version%s <v>      %sinstall that version instead of the latest%s\n' "$o" "$n" "$d" "$n"
    printf '   %s--file%s <pack>      %suse a pack already on this computer%s\n\n' "$o" "$n" "$d" "$n"
    return 0
  fi
  cat <<'EOF'
Install or upgrade Bot HQ on an Orgo computer that runs a Hermes agent (as root, on that computer).

  curl -fsSL <releases>/install.sh | bash                          install, or upgrade to the latest
  curl -fsSL <releases>/install.sh | bash -s -- --url <address>    first install, without being asked

  --url <address>   the computer's public web address, like https://<name>-xxxx.web.orgo.dev
  --from <address>  where releases are kept (the folder holding `latest`)
  --version <v>     install that version instead of the latest
  --file <pack>     use a pack already on this computer instead of downloading one
EOF
}

# ---------------------------------------------------------------- arguments

OPT_URL="${PUBLIC_URL:-}"
OPT_FROM="${HQ_RELEASES:-}"
OPT_VERSION="${HQ_VERSION:-}"
OPT_FILE=""
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) OPT_URL="${2:-}"; shift 2 || stop "--url needs an address after it." ;;
      --url=*) OPT_URL="${1#*=}"; shift ;;
      --from) OPT_FROM="${2:-}"; shift 2 || stop "--from needs an address after it." ;;
      --from=*) OPT_FROM="${1#*=}"; shift ;;
      --version) OPT_VERSION="${2:-}"; shift 2 || stop "--version needs a version after it." ;;
      --version=*) OPT_VERSION="${1#*=}"; shift ;;
      --file) OPT_FILE="${2:-}"; shift 2 || stop "--file needs a pack after it." ;;
      --file=*) OPT_FILE="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) stop "Unknown option: $1" "Run it with --help to see the options." ;;
    esac
  done
  RELEASES="${OPT_FROM:-$HQ_DEFAULT_RELEASES}"
  RELEASES="${RELEASES%/}"
}

# The command to suggest when one has to be run again, in the same form as this run.
again_cmd() {
  local extra="${1:-}"
  if [ -n "$OPT_FILE" ]; then printf 'bash install.sh --file %s' "$OPT_FILE"
  else
    printf 'curl -fsSL %s/install.sh | bash' "$RELEASES"
    if [ -n "$OPT_FROM" ] || [ -n "$extra" ]; then printf ' -s --'; fi
    if [ -n "$OPT_FROM" ]; then printf ' --from %s' "$RELEASES"; fi
  fi
  if [ -n "$extra" ]; then printf ' %s' "$extra"; fi
}

# ---------------------------------------------------------------- 1. where are we (changes nothing)

# A setting from a KEY=value file, or empty. A missing key or file must not stop the script.
key() { { grep -E "^$1=" "$2" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }

# The "version" of a package.json read as text: release packs are written by npm, one key per line.
pkg_version() { { sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$1" 2>/dev/null || true; } | head -1; }

preflight() {
  if [ "$OS" != "Linux" ]; then
    stop "This is not an Orgo computer: it runs $OS, and Bot HQ needs the Linux computer Orgo makes." \
         "Paste the command into the terminal of your Orgo computer instead (in Orgo, open the computer, then its terminal)."
  fi
  case "$ARCH" in
    x86_64|amd64) NODE_ARCH=x64 ;;
    aarch64|arm64) NODE_ARCH=arm64 ;;
    *) stop "This computer's processor ($ARCH) is not one Bot HQ supports. It runs on x86_64 or arm64." ;;
  esac
  if [ "$USER_ID" != "0" ]; then
    stop "This has to run as root, and it is running as another user." \
         "On an Orgo computer the terminal is already root. Elsewhere, put sudo in front of bash: ... | sudo bash"
  fi
  local c
  for c in tar gzip openssl sha256sum "$CURL"; do
    command -v "$c" >/dev/null 2>&1 || stop "This computer has no '$c' command, which the installer needs." \
      "Bot HQ is made for an Orgo computer created from the Hermes Agent template, which has it."
  done
  if ! command -v "$SUPERVISORCTL" >/dev/null 2>&1 || [ ! -d "$SUPERVISOR_DIR" ]; then
    stop "This computer does not use supervisor to keep programs running, so Bot HQ cannot be installed here." \
         "Bot HQ runs on an Orgo computer created from the Hermes Agent template."
  fi
  # `version` asks the running supervisor itself; its exit code varies between releases, its output does not.
  local sv; sv="$("$SUPERVISORCTL" version 2>/dev/null || true)"
  if ! printf '%s\n' "$sv" | grep -qE '^[0-9]+\.[0-9]+'; then
    stop "supervisor is installed but not running, so nothing could keep Bot HQ running." \
         "Restart the computer from Orgo, wait a minute, then run this again."
  fi
  HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
  [ -n "$HERMES_BIN" ] || { [ ! -x "$ROOT/usr/local/bin/hermes" ] || HERMES_BIN="$ROOT/usr/local/bin/hermes"; }
  if [ -z "$HERMES_BIN" ] || [ ! -d "$HERMES_HOME_DIR" ]; then
    stop "This computer has no Hermes agent. In Orgo, create the computer from the Hermes Agent template, then run this again on it."
  fi

  # An upgrade when the settings file is there (or waits in app.prev, when a run was interrupted mid-switch).
  UPGRADE=0; SETTINGS="$APP/.env"
  [ -d "$APP" ] || [ ! -f "$PREV/.env" ] || SETTINGS="$PREV/.env"
  [ ! -f "$SETTINGS" ] || UPGRADE=1
  if [ "$UPGRADE" = 1 ]; then
    PORT="$(key PORT "$SETTINGS")"; PORT="${PORT:-8787}"
    HERMES_URL="$(key HERMES_URL "$SETTINGS")"
    DB="$(key DB_PATH "$SETTINGS")"
  else
    PORT="${PORT:-8787}"; HERMES_URL=""; DB=""
  fi
  local hp; hp="$(key API_SERVER_PORT "$HERMES_HOME_DIR/.env")"
  HERMES_URL="${HERMES_URL:-http://127.0.0.1:${hp:-8642}}"
  DB="${DB:-$DATA/hq.db}"
  # A first install on a Hermes agent whose API server is switched off switches it on (hermes_api_on,
  # once the pack is here). Switched on and still not answering is something a restart may fix.
  HERMES_OFF=0
  if ! hermes_up; then
    if [ "$UPGRADE" = 0 ] && ! hermes_api_enabled; then HERMES_OFF=1
    else
      stop "The Hermes agent on this computer is not running (it does not answer at $HERMES_URL)." \
           "Restart the computer from Orgo, wait a minute, then run this again."
    fi
  fi

  # Room for the new code and its packages next to the old, a first Node, and the backup.
  local need=$MIN_FREE_MB at=$HQ_DIR free_kb
  [ ! -f "$DB" ] || need=$(( need + 2 * $(wc -c <"$DB") / 1048576 ))
  while [ ! -d "$at" ]; do at="$(dirname "$at")"; done
  free_kb="$(df -Pk "$at" | awk 'NR==2 {print $4}')"
  if [ -z "$free_kb" ] || [ $(( free_kb / 1024 )) -lt "$need" ]; then
    stop "There is not enough free disk space. Bot HQ needs about $need MB free, and this computer has $(( ${free_kb:-0} / 1024 )) MB." \
         "Free some space (or give the computer a bigger disk in Orgo), then run this again."
  fi

  if [ -z "$OPT_FILE" ] && [ "$RELEASES" = "$PLACEHOLDER_RELEASES" ]; then
    stop "This copy of the installer does not know where Bot HQ releases are kept." \
         "Run it with --from and the address of the releases folder, or ask whoever gave you the command for the full one."
  fi
  if [ -n "$OPT_FILE" ]; then
    [ -f "$OPT_FILE" ] || stop "There is no file $OPT_FILE."
    OPT_FILE="$(cd "$(dirname "$OPT_FILE")" && pwd)/$(basename "$OPT_FILE")"
  fi
}

# ---------------------------------------------------------------- the terminal

# The terminal itself, opened once and kept open: with `curl | bash`, the script's own input is the
# download. No terminal (a script, or Orgo's bash API): nothing is asked.
TTY_OPEN=0
open_tty() {
  [ "$TTY_OPEN" = 0 ] || return 0
  { exec 3<"$TTY"; } 2>/dev/null || return 1
  TTY_OPEN=1
}
# The prompt, "› Orgo key", then what is typed, into ANSWER. $1 the label, $2 a hint shown until
# something is typed (dim, in a terminal). A line has the spaces at either end dropped.
ask_line() {
  read_answer "$1" "$2" 0
  ANSWER="${ANSWER#"${ANSWER%%[![:space:]]*}"}"; ANSWER="${ANSWER%"${ANSWER##*[![:space:]]}"}"
}
# A key, not shown as it is typed (a dot for each character, in a terminal), with all spaces dropped.
# It stays in this shell's memory: it is only ever written to a pipe (printf is part of bash), never
# put on a command line, in a file or in a log.
ask_secret() {
  read_answer "$1" "$2" 1
  ANSWER="${ANSWER//[[:space:]]/}"
}
read_answer() {
  local label="$1" hint="$2" hide="$3" ch esc shown=0
  ANSWER=""
  if [ "$FANCY" = 0 ]; then
    if [ "$hide" = 1 ]; then
      printf '  %s (hidden as you type; %s): ' "$label" "$hint"
      IFS= read -r -s -u 3 ANSWER || ANSWER=""
      printf '\n'
    else
      printf '  %s (%s): ' "$label" "$hint"
      IFS= read -r -u 3 ANSWER || ANSWER=""
    fi
    return 0
  fi
  # One character at a time, so a key shows as dots and the hint goes once typing starts.
  printf '  %s›%s %s  %s(%s)%s\033[%dD' "$c_o" "$c_n" "$label" "$c_dim" "$hint" "$c_n" $(( ${#hint} + 2 ))
  while IFS= read -r -s -n 1 -u 3 ch; do
    [ -n "$ch" ] || break   # Enter
    case "$ch" in
      $'\177'|$'\b')
        if [ -n "$ANSWER" ]; then ANSWER="${ANSWER%?}"; printf '\b \b'; fi ;;
      $'\025')                # Ctrl-U: start again
        while [ -n "$ANSWER" ]; do ANSWER="${ANSWER%?}"; printf '\b \b'; done ;;
      $'\033') IFS= read -r -s -n 2 -t 0.05 -u 3 esc || true ;;   # arrow keys: not used here
      [[:cntrl:]]) ;;
      *)
        if [ "$shown" = 0 ]; then printf '\033[K'; shown=1; fi
        ANSWER+="$ch"
        if [ "$hide" = 1 ]; then printf '%s•%s' "$c_dim" "$c_n"; else printf '%s' "$ch"; fi ;;
    esac
  done
  printf '\n'
}

# ---------------------------------------------------------------- 2. the public address (first install)

# The example address from the instructions rather than this computer's own: <name>, YOUR-ADDRESS,
# example, xxxx and the like. Anyone who copies the command as it is written ends up here.
placeholder_url() {
  local u host w words=()
  u="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$u" in
    *'<'*|*'>'*|*'{'*|*'}'*|*'['*|*']'*|*your-address*|*youraddress*|*your_address*|*your-url*|*yoururl*|\
    *your-name*|*yourname*|*your-computer*|*placeholder*|*changeme*|*change-me*) return 0 ;;
  esac
  host="${u#*://}"; host="${host%%[/:?#]*}"
  IFS='.-' read -ra words <<<"$host" || true
  for w in ${words[@]+"${words[@]}"}; do case "$w" in example|xxx|xxxx|xxxxx) return 0 ;; esac; done
  return 1
}
PLACEHOLDER_WORDS="That is the example address from the instructions, not this computer's own."
MAKE_ONE="To make one in Orgo: open the computer's menu, choose Public URLs, enter port 8787, and click Add."

ask_url() {
  PUBLIC=""
  if [ "$UPGRADE" = 1 ]; then
    if [ -n "$OPT_URL" ] && [ "${OPT_URL%/}" != "$(key APP_URL "$SETTINGS")" ]; then
      note "Note: this computer already has its settings, so the address given was not used. It keeps $(key APP_URL "$SETTINGS")."
    fi
    return 0
  fi
  local example="https://<name>-xxxx.web.orgo.dev" given=""
  if [ -n "$OPT_URL" ] && placeholder_url "$OPT_URL"; then
    # With a terminal, it is asked for instead; without one, nothing can be done but say so.
    open_tty || stop "\"$OPT_URL\" is the example address from the instructions, not this computer's own." \
                     "Make this computer's Public URL for port 8787 in Orgo (the computer's menu, Public URLs, port 8787, Add)," \
                     "then run the command again with the address Orgo shows:" \
                     "  $(again_cmd "--url <the address Orgo shows>")"
    given="$OPT_URL"
  elif [ -n "$OPT_URL" ]; then
    PUBLIC="${OPT_URL%/}"
    [[ "$PUBLIC" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?$ ]] ||
      stop "\"$OPT_URL\" is not a web address. It should look like https://<name>-xxxx.web.orgo.dev"
    return 0
  fi
  if ! open_tty; then
    stop "A first install needs this computer's public web address, and there is no terminal here to ask for it." \
         "Make one in Orgo (the computer's menu, Public URLs, port 8787, Add), then run:" \
         "  $(again_cmd "--url $example")"
  fi
  if [ "$FANCY" = 1 ]; then
    q_head "Public address" "" "where you open Bot HQ in a browser"
    q_info "$MAKE_ONE"
    q_info "Then copy the address it shows. It looks like $example"
  else
    say "" \
        "Bot HQ needs this computer's public web address, so you can open it in a browser." \
        "$MAKE_ONE" \
        "Then copy the address it shows. It looks like $example" ""
  fi
  [ -z "$given" ] || redbar 0 "--url $given: $PLACEHOLDER_WORDS" "Type the address Orgo shows for this computer instead."
  local answer tries=0
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    ask_line "Public address" "https://...orgo.dev"; answer="$ANSWER"
    answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    answer="${answer%/}"
    case "$answer" in ''|http://*|https://*) ;; *) answer="https://$answer" ;; esac
    if [ -n "$answer" ] && placeholder_url "$answer"; then
      redbar 0 "$PLACEHOLDER_WORDS" "Make the Public URL for port 8787 in Orgo and use the address it shows."
    elif [[ "$answer" =~ ^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.orgo\.dev$ ]]; then
      PUBLIC="$answer"; q_ok "$PUBLIC"; say ""; return 0
    else
      redbar 0 "That does not look like an Orgo public address. It starts with https:// and ends with .orgo.dev."
    fi
  done
  stop "No address was given, so nothing was installed." "Run the command again when you have it, or give it directly:" \
       "  $(again_cmd "--url $example")"
}

# ---------------------------------------------------------------- Hermes's API server (first install)

hermes_up() { "$CURL" -fsS -m 5 "$HERMES_URL/health" >/dev/null 2>&1; }
hermes_api_enabled() {
  [ "$(key API_SERVER_ENABLED "$HERMES_HOME_DIR/.env")" = true ] && [ -n "$(key API_SERVER_KEY "$HERMES_HOME_DIR/.env")" ]
}

# Set NAME=value in a KEY=value file, keeping every other line as it is. Only bash itself handles the
# value (it may be a key), so it is never on a command line.
env_put() {
  local f="$1" name="$2" value="$3" line hit=0
  {
    if [ -f "$f" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "$name" ]; then printf '%s=%s\n' "$name" "$value"; hit=1; else printf '%s\n' "$line"; fi
      done <"$f"
    fi
    [ "$hit" = 1 ] || printf '%s=%s\n' "$name" "$value"
  } >"$f.hq-new"
  chmod 600 "$f.hq-new" && mv -f "$f.hq-new" "$f"
}

# Restart the main Hermes agent so it reads its settings again: its program under supervisor when
# there is exactly one, else Hermes's own command. (server/box/hq-remote.sh does the same on a
# teammate's computer.)
restart_hermes() {
  local progs n
  progs="$("$SUPERVISORCTL" status 2>/dev/null | awk 'tolower($1) ~ /hermes/ {print $1}' || true)"
  n="$(printf '%s\n' "$progs" | grep -c . || true)"
  if [ "$n" -gt 1 ]; then
    stop "More than one Hermes agent runs on this computer ($(printf '%s ' $progs)), so the installer restarted none." \
         "Hermes's API server is now switched on in $HERMES_HOME_DIR/.env. Restart the main agent yourself (supervisorctl restart <its program>), then run this again."
  fi
  if [ "$n" = 1 ]; then "$SUPERVISORCTL" restart "$progs" >/dev/null 2>&1 && return 0; fi
  "$HERMES_BIN" gateway restart >/dev/null 2>&1 || true
}

# The template may leave the API server off; Bot HQ talks to the agent through it. Switch it on with a
# key of its own (an existing key is kept), on 127.0.0.1 only, and wait until it answers.
hermes_api_on() {
  [ "${HERMES_OFF:-0}" = 1 ] || return 0
  local f="$HERMES_HOME_DIR/.env" k i=0
  note "The Hermes agent's API server, which Bot HQ talks to, is switched off."
  step "Switching it on (Hermes restarts once)"
  k="$(key API_SERVER_KEY "$f")"; [ -n "$k" ] || k="$(openssl rand -hex 32)"
  env_put "$f" API_SERVER_ENABLED true
  env_put "$f" API_SERVER_KEY "$k"
  [ -n "$(key API_SERVER_PORT "$f")" ] || env_put "$f" API_SERVER_PORT "${HERMES_URL##*:}"
  [ -n "$(key API_SERVER_HOST "$f")" ] || env_put "$f" API_SERVER_HOST 127.0.0.1
  k=""
  restart_hermes
  while [ $i -lt "$HERMES_WAIT" ]; do hermes_up && { step_ok "Hermes's API server is on."; return 0; }; sleep 1; i=$((i + 1)); done
  stop "Hermes's API server was switched on in $f, but it has not started answering at $HERMES_URL." \
       "Bot HQ was not installed. Restart the computer from Orgo, wait a minute, then run this again."
}

# ---------------------------------------------------------------- 3. the pack (downloaded to a temporary folder)

sha_of() { sha256sum "$1" | awk '{print $1}'; }
download() { "$CURL" -fsSL --retry 2 --connect-timeout 20 -m 900 -o "$2" "$1"; }

get_pack() {
  local sumfile expected
  if [ -n "$OPT_FILE" ]; then
    PACK="$OPT_FILE"; sumfile="$OPT_FILE.sha256"
    [ -f "$sumfile" ] || sumfile=""
    step "Checking $(basename "$PACK")"
  else
    local version="$OPT_VERSION"
    if [ -z "$version" ]; then
      spin "Looking for the newest Bot HQ"
      download "$RELEASES/latest" "$TMP/latest" ||
        stop "Could not reach $RELEASES/latest to find the newest version." \
             "Check that this computer is online and the address is right, then run this again. Nothing was changed."
      version="$(head -1 "$TMP/latest" | tr -d '[:space:]')"
    fi
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ]] ||
      stop "The releases folder did not name a version this installer understands (\"$version\"). Nothing was changed."
    PACK="$TMP/hq-app-$version.tgz"; sumfile="$TMP/hq-app-$version.tgz.sha256"
    step "Downloading Bot HQ $version"
    download "$RELEASES/hq-app-$version.tgz" "$PACK" && download "$RELEASES/hq-app-$version.tgz.sha256" "$sumfile" ||
      stop "Could not download Bot HQ $version from $RELEASES." \
           "Check that this computer is online and the address is right, then run this again. Nothing was changed."
  fi
  if [ -n "$sumfile" ]; then
    expected="$(awk 'NR==1 {print tolower($1)}' "$sumfile")"
    if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$(sha_of "$PACK")" != "$expected" ]; then
      stop "The download did not match its published checksum, so it was not used. Nothing was changed." \
           "Run this again in a few minutes. If it keeps happening, tell whoever publishes Bot HQ."
    fi
  fi
  # A Bot HQ pack: the server and its own package.json with a version.
  tar -tzf "$PACK" >"$TMP/list" 2>/dev/null && grep -qx 'server/dist/index.js' "$TMP/list" &&
    tar -xzOf "$PACK" package.json >"$TMP/package.json" 2>/dev/null ||
    stop "$(basename "$PACK") is not a Bot HQ pack, or it is damaged. Nothing was changed."
  NEW_VERSION="$(pkg_version "$TMP/package.json")"
  NEW_LABEL="${NEW_VERSION:-a version with no number}"
  local size; size="$(wc -c <"$PACK" | awk '{ s = $1 / 1024; if (s < 1024) printf "%d KB", s + 0.5; else printf "%.1f MB", s / 1024 }')"
  if [ -n "$OPT_FILE" ]; then step_ok "Using $(basename "$PACK"), Bot HQ $NEW_LABEL" "$size${sumfile:+ · checksum ok}"
  else step_ok "Downloaded Bot HQ $NEW_LABEL" "$size · checksum ok"; fi
}

# ---------------------------------------------------------------- health

health_json() { "$CURL" -fsS -m 3 "http://127.0.0.1:$PORT/api/health" 2>/dev/null; }
# Healthy: answers ok, and (when a version is given) is that version, so an old process cannot pass for the new one.
healthy() {
  local out; out="$(health_json)" || return 1
  case "$out" in *'"ok":true'*) ;; *) return 1 ;; esac
  [ -z "${1:-}" ] || case "$out" in *"\"version\":\"$1\""*) ;; *) return 1 ;; esac
}
wait_healthy() {
  local i=0
  while [ $i -lt "$HEALTH_WAIT" ]; do healthy "${1:-}" && return 0; sleep 1; i=$((i + 1)); done
  healthy "${1:-}"
}

# ---------------------------------------------------------------- locking and leftovers

LOCKED=0; SWAPPED=0; TMP=""; MADE_HQ_DIR=0
cleanup() {
  spin_off   # a spinner still turning (the window was closed, Ctrl-C) stops, and the cursor comes back
  [ -z "$TMP" ] || rm -rf "$TMP"
  # The new code is only ever left behind when a run stops before it was put in place.
  [ "$SWAPPED" = 1 ] || rm -rf "$NEW" "$NODE_DIR.new"
  [ "$LOCKED" = 0 ] || rm -rf "$HQ_DIR/.install-lock"
  # A first install that stopped early leaves no empty /opt/hq behind.
  [ "$MADE_HQ_DIR" = 0 ] || rmdir "$HQ_DIR" 2>/dev/null || true
}

lock() {
  [ -d "$HQ_DIR" ] || MADE_HQ_DIR=1
  mkdir -p "$HQ_DIR"
  if ! mkdir "$HQ_DIR/.install-lock" 2>/dev/null; then
    local pid; pid="$(cat "$HQ_DIR/.install-lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      stop "The installer is already running on this computer. Wait for it to finish."
    fi
    rm -rf "$HQ_DIR/.install-lock"; mkdir "$HQ_DIR/.install-lock"
  fi
  LOCKED=1
  echo $$ >"$HQ_DIR/.install-lock/pid"
}

# A run that was stopped half way (the computer restarted, the window was closed) leaves one of these.
# app.prev only exists between stopping the old version and seeing the new one healthy, so finding it
# means that run never finished: go back to the version from before it, then carry on as usual.
recover() {
  rm -rf "$NEW" "$FAILED" "$NODE_DIR.new"
  [ -d "$PREV" ] || return 0
  note "An earlier run was interrupted while switching versions."
  step "Putting the version from before it back first"
  sv_stop
  if [ -d "$APP" ]; then mv "$APP" "$FAILED"; fi
  mv "$PREV" "$APP"
  rm -rf "$FAILED"
  CONF_CHANGED=0; sv_start
  if wait_healthy; then step_ok "The version from before it is back"
  else step_warn "It has not come back up yet; carrying on with the install."; fi
}

# ---------------------------------------------------------------- 4. Node, and the new code beside the old

install_node() {
  local have; have="$("$NODE_DIR/bin/node" -v 2>/dev/null || true)"
  case "$have" in v22.*) step_ok "Node.js ${have#v}" "Bot HQ's own copy, already here"; return 0 ;; esac
  local name="node-$NODE_V-linux-$NODE_ARCH.tar.gz"
  step "Getting Node.js $NODE_V (Bot HQ keeps its own copy; the system one is left alone)"
  download "$NODE_SITE/$NODE_V/$name" "$TMP/$name" && download "$NODE_SITE/$NODE_V/SHASUMS256.txt" "$TMP/node-sums" ||
    stop "Could not download Node.js from $NODE_SITE. Check that this computer is online, then run this again."
  [ "$(awk -v f="$name" '$2 == f {print $1}' "$TMP/node-sums")" = "$(sha_of "$TMP/$name")" ] ||
    stop "The Node.js download did not match its published checksum, so it was not used. Run this again in a few minutes."
  rm -rf "$NODE_DIR.new"; mkdir -p "$NODE_DIR.new"
  tar -xzf "$TMP/$name" -C "$NODE_DIR.new" --strip-components=1
  rm -rf "$NODE_DIR"; mv "$NODE_DIR.new" "$NODE_DIR"
  step_ok "Node.js ${NODE_V#v}" "Bot HQ's own copy"
}

stage() {
  step "Preparing Bot HQ $NEW_LABEL (the running one is not touched yet)"
  mkdir -p "$NEW"
  tar -xzf "$PACK" -C "$NEW" --no-same-owner
  # --ignore-scripts: the SQLite package ships ready-made binaries; without this npm tries to compile it.
  if ! (cd "$NEW" && npm ci --omit=dev -w server --ignore-scripts --no-audit --no-fund >"$LOGS/npm.log" 2>&1); then
    step_fail
    if [ "$FANCY" = 1 ]; then tail -20 "$LOGS/npm.log" | sed "s/^/    $c_dim/; s/\$/$c_n/" >&2 || true
    else tail -20 "$LOGS/npm.log" >&2 || true; fi
    stop "Installing the app's packages failed (the lines above are the end of $LOGS/npm.log)." \
         "Bot HQ was not changed. Check that this computer is online, then run this again."
  fi
  step_ok "Prepared Bot HQ $NEW_LABEL" "its packages are installed"
}

# ---------------------------------------------------------------- 5. the backup (upgrade only, before any code is replaced)

BACKUP=""
backup() {
  local ts dir n=1 label="before-${NEW_VERSION:-upgrade}"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  [ -d "$BACKUPS" ] || MADE_BACKUPS=1
  if ! mkdir -p "$BACKUPS" 2>/dev/null; then backup_failed "could not make $BACKUPS"; fi
  dir="$BACKUPS/$ts-$label"
  while ! mkdir "$dir" 2>/dev/null; do
    n=$((n + 1)); [ $n -lt 50 ] || backup_failed "could not make a folder in $BACKUPS"
    dir="$BACKUPS/$ts-$label-$n"
  done
  BACKUP="$dir"
  step "Backing up"

  # The database: SQLite's own backup, which is consistent while the app is writing, then checked.
  # It uses the new code's SQLite package, which is in place by now even when the old one is broken.
  if [ -f "$DB" ]; then
    "$NODE_DIR/bin/node" -e '
      const [src, dest, pkg] = process.argv.slice(1);
      const Database = require("module").createRequire(pkg)("better-sqlite3");
      const from = new Database(src, { fileMustExist: true });
      from.backup(dest).then(() => {
        from.close();
        const copy = new Database(dest, { fileMustExist: true });
        const result = copy.pragma("integrity_check", { simple: true });
        copy.close();
        if (result !== "ok") { console.error("integrity check: " + result); process.exit(1); }
      }).catch((e) => { console.error(e.message); process.exit(1); });
    ' "$DB" "$dir/hq.db" "$NEW/server/package.json" >"$dir/.db-check.log" 2>&1 ||
      backup_failed "the copy of the database did not pass SQLite's check ($(tail -1 "$dir/.db-check.log" 2>/dev/null))"
    rm -f "$dir/.db-check.log" "$dir/hq.db-wal" "$dir/hq.db-shm"
  fi
  # The settings file (it holds the secrets: readable by root only).
  cp "$APP/.env" "$dir/app.env" && chmod 600 "$dir/app.env" && cmp -s "$APP/.env" "$dir/app.env" ||
    backup_failed "the settings file could not be copied"
  # The code, in the same shape as a release pack (so install.sh --file can put it back), without its
  # packages (npm puts them back) and without the settings (copied above).
  local names=() name
  while IFS= read -r name; do
    case "$name" in node_modules|.env) ;; *) names+=("$name") ;; esac
  done < <(top_level "$APP")
  (cd "$APP" && tar -czf "$dir/app-code.tgz" "${names[@]}") && tar -tzf "$dir/app-code.tgz" >/dev/null ||
    backup_failed "the code could not be packed"
  [ ! -f "$CONF" ] || cp "$CONF" "$dir/hq-app.conf" || backup_failed "the supervisor program could not be copied"
  cat >"$dir/RESTORE.txt" <<EOF
Made by the Bot HQ installer before upgrading from $OLD_LABEL to $NEW_LABEL.

  hq.db         the database (a consistent SQLite copy, checked)
  app.env       the settings file (/opt/hq/app/.env)
  app-code.tgz  the code that was running (without node_modules)
  hq-app.conf   the supervisor program

To go back to this point by hand, as root:
  supervisorctl stop hq-app
  cp hq.db $DB && rm -f $DB-wal $DB-shm
  bash /opt/hq/app/scripts/install.sh --file app-code.tgz   (or put the code back in /opt/hq/app and run npm ci there)
  supervisorctl start hq-app
EOF
  : >"$dir/.made-by-installer"
  step_ok "Backed up, database checked" "$dir"
}

MADE_BACKUPS=0
backup_failed() {
  [ -z "$BACKUP" ] || rm -rf "$BACKUP"
  [ "$MADE_BACKUPS" = 0 ] || rmdir "$BACKUPS" 2>/dev/null || true
  stop "The backup failed: $1." "Bot HQ was not changed. Free some disk space or fix the problem, then run this again."
}

# The installer keeps its own last $KEEP_BACKUPS backups and deletes older ones it made.
# Backups made by hand (no .made-by-installer file) are never deleted, and neither is the one just made.
prune_backups() {
  local d
  { for d in "$BACKUPS"/*/; do [ -f "$d.made-by-installer" ] && printf '%s\n' "${d%/}"; done; true; } |
    sort -r | tail -n +"$((KEEP_BACKUPS + 1))" |
    while IFS= read -r d; do [ "$d" = "$BACKUP" ] || rm -rf "$d"; done
}

# ---------------------------------------------------------------- 6. settings (written once)

write_settings() {
  local env="$1"
  : "${PUBLIC:?}"
  # Keys given up front are written here; any that are not are asked for in the terminal or by the
  # setup wizard, and kept (encrypted) in the app. The Orgo key in Hermes's own settings is not taken:
  # it may be Orgo's key for this one computer, which Orgo replaces every 30 days.
  local K="${KEYS_FILE:-/dev/null}" orgo xk ck xm
  orgo="$(key ORGO_API_KEY "$K")"
  xk="$(key XAI_API_KEY "$K")"; ck="$(key COMPOSIO_API_KEY "$K")"; xm="$(key XAI_MODEL "$K")"
  {
    echo "PORT=$PORT"
    echo "APP_URL=$PUBLIC"
    echo "SERVER_URL=$PUBLIC"
    echo "SESSION_SECRET=$(openssl rand -hex 32)"
    echo "DEV_LOGIN=${DEV_LOGIN:-0}"
    echo "ALLOWED_EMAILS=${ALLOWED_EMAILS:-}"
    echo "DB_PATH=$DATA/hq.db"
    echo "ENGINES_DIR=$DATA/engines"
    echo "HERMES_BIN=$HERMES_BIN"
    echo "HERMES_URL=$HERMES_URL"
    echo "HERMES_HOME_PRIMARY=$HERMES_HOME_DIR"
    echo "HERMES_KEY=$(key API_SERVER_KEY "$HERMES_HOME_DIR/.env")"
    echo "HQ_LOCAL=1"
    echo "PRIMARY_CDP_URL=${PRIMARY_CDP_URL:-}"
    [ -z "${ORGO_COMPUTER_ID:-}" ] || echo "ORGO_COMPUTER_ID=$ORGO_COMPUTER_ID"
    [ -z "$orgo" ] || echo "ORGO_API_KEY=$orgo"
    [ -z "$xk" ] || echo "XAI_API_KEY=$xk"
    [ -z "$ck" ] || echo "COMPOSIO_API_KEY=$ck"
    [ -z "${T3_PROXY:-}" ] || echo "T3_PROXY=$T3_PROXY"
    [ -z "$xm" ] || echo "XAI_MODEL=$xm"
    [ -z "${PRIMARY_BOT_NAME:-}" ] || echo "PRIMARY_BOT_NAME=$PRIMARY_BOT_NAME"
    [ -z "${PRIMARY_BOT_LABEL:-}" ] || echo "PRIMARY_BOT_LABEL=$PRIMARY_BOT_LABEL"
  } >"$env"
  chmod 600 "$env"
}

# The names at the top of a folder, dot-files included.
top_level() {
  local e
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do [ ! -e "$e" ] && [ ! -L "$e" ] || printf '%s\n' "${e##*/}"; done
}

# Upgrade: the settings file, and anything else someone put at the top of the app folder, go along.
carry_over() {
  local name
  cp -p "$APP/.env" "$NEW/.env"
  while IFS= read -r name; do
    case "$name" in package.json|package-lock.json|.env.example|server|web|scripts|node_modules|.env) continue ;; esac
    [ -e "$NEW/$name" ] || cp -a "$APP/$name" "$NEW/$name"
  done < <(top_level "$APP")
}

# ---------------------------------------------------------------- 7. supervisor

write_conf() {
  cat >"$CONF.new" <<EOF
[program:hq-app]
command=$NODE_DIR/bin/node --env-file=$APP/.env $APP/server/dist/index.js
directory=$APP
autostart=true
autorestart=true
startsecs=3
stopasgroup=false
killasgroup=false
stdout_logfile=$LOGS/app.log
stdout_logfile_maxbytes=10MB
redirect_stderr=true
environment=HOME="$ROOT/root",PATH="$NODE_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
  chmod 644 "$CONF.new"
  CONF_CHANGED=1; ! cmp -s "$CONF.new" "$CONF" || CONF_CHANGED=0
  mv "$CONF.new" "$CONF"
}

# `status` exits non-zero for a program that is not running, so read what it says, not how it exits.
sv_known() {
  local out; out="$("$SUPERVISORCTL" status hq-app 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -qE 'RUNNING|STARTING|BACKOFF|FATAL|EXITED|STOPPED'
}
sv_stop() { "$SUPERVISORCTL" stop hq-app >/dev/null 2>&1 || true; }
# Start hq-app from what is on disk now. Only this one program is added or restarted; nothing else under supervisor is touched.
# Failures here are left to the health check, which decides what happens next.
sv_start() {
  "$SUPERVISORCTL" reread >/dev/null 2>&1 || true
  if sv_known; then
    # A changed program is re-read and started by `update`; an unchanged one just starts.
    [ "${CONF_CHANGED:-0}" = 0 ] || "$SUPERVISORCTL" update hq-app >/dev/null 2>&1 || true
    "$SUPERVISORCTL" start hq-app >/dev/null 2>&1 || true
  else
    "$SUPERVISORCTL" add hq-app >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- 8. switch over, and back if need be

switch_over() {
  if [ "$UPGRADE" = 1 ]; then
    step "Switching to $NEW_LABEL"
    STOPPED_APP=1
    sv_stop
    mv "$APP" "$PREV"
  else
    step "Starting Bot HQ $NEW_LABEL"
    rm -rf "$APP"   # a first install: whatever is here never ran (there are no settings)
  fi
  mv "$NEW" "$APP"
  SWAPPED=1
  sv_start
}

roll_back() {
  step_fail
  note "Bot HQ $NEW_LABEL did not start properly (its log is $LOGS/app.log)."
  step "Putting $OLD_LABEL back"
  sv_stop
  mv "$APP" "$FAILED"
  mv "$PREV" "$APP"
  if [ -f "$BACKUP/hq-app.conf" ] && ! cmp -s "$BACKUP/hq-app.conf" "$CONF"; then
    cp "$BACKUP/hq-app.conf" "$CONF"; CONF_CHANGED=1
  else CONF_CHANGED=0; fi
  sv_start
  rm -rf "$FAILED"
  if wait_healthy; then
    step_ok "$OLD_LABEL is back and running"
    stop "The upgrade did not work, so Bot HQ is back on $OLD_LABEL and running. Your data was not touched." \
         "The backup made before the upgrade is in $BACKUP. Send $LOGS/app.log to whoever publishes Bot HQ."
  fi
  stop "The upgrade did not work, and $OLD_LABEL did not come back up either. Your data was not touched." \
       "Look at $LOGS/app.log. The backup made before the upgrade is in $BACKUP; its RESTORE.txt says how to go back."
}

# ---------------------------------------------------------------- 9. the main agent's tools, and the end

write_mcp_entry() {
  local secret tok
  secret="$(key SESSION_SECRET "$APP/.env")"
  [ -n "$secret" ] || return 0
  tok="$(printf 'mcp:primary' | openssl dgst -sha256 -hmac "$secret" -r | cut -d' ' -f1)"
  cat >"$DATA/hermes-mcp-hq.yaml" <<EOF
# Add under mcp_servers: in $HERMES_HOME_DIR/config.yaml (Hermes picks it up without a restart).
  hq:
    url: http://127.0.0.1:$PORT/mcp/primary
    headers:
      Authorization: Bearer $tok
    timeout: 1800
    connect_timeout: 30
EOF
}

# The main agent gets Bot HQ's tools: the `hq` entry added to Hermes's config.yaml by
# add-hq-to-hermes.py, which checks its own edit (with PyYAML when Hermes's Python has it, else a
# stricter check of the text) and keeps a dated copy. Hermes notices the change without a restart.
hermes_python() {
  local s; s="$(head -1 "$HERMES_BIN" 2>/dev/null | sed 's/^#!//' | awk '{print $1}' || true)"
  case "$s" in */python*) if [ -x "$s" ]; then printf '%s\n' "$s"; return 0; fi ;; esac
  command -v python3 2>/dev/null || true
}
give_tools() {
  local cfg="$HERMES_HOME_DIR/config.yaml" entry="$DATA/hermes-mcp-hq.yaml" py out=""
  [ -f "$entry" ] || return 0
  ! grep -qE '^[[:space:]]+hq:' "$cfg" 2>/dev/null || return 0
  py="$(hermes_python)"
  if [ -f "$cfg" ] && [ -n "$py" ] && out="$("$py" -I "$APP/scripts/add-hq-to-hermes.py" --config "$cfg" --entry "$entry" 2>&1)"; then
    out="$(printf '%s' "$out" | tail -1)"
    # In a terminal, the copy's long path is left for the log; it sits beside config.yaml.
    [ "$FANCY" = 0 ] || out="${out%%; previous file kept as*}; the previous config.yaml is kept beside it"
    step_ok "The main Hermes agent now has Bot HQ's tools" "$out"
  else
    step_warn "The installer could not give the main Hermes agent Bot HQ's tools${out:+: $(printf '%s' "$out" | tail -1)}" \
              "To do it by hand (once): python3 /opt/hq/app/scripts/add-hq-to-hermes.py"
  fi
}

needs_setup() {
  local out; out="$("$CURL" -fsS -m 5 "http://127.0.0.1:$PORT/api/setup/state" 2>/dev/null || true)"
  case "$out" in *'"needsSetup":true'*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- 10. the questions (in a terminal, until the owner exists)

# Ask the app running on this computer, as the setup wizard in the browser does: the same routes and
# the same checks, so a key is refused here with the same words as there. The values go on standard
# input (name=value lines) to a small Node program that posts them to 127.0.0.1 as JSON; it works out
# the setup code (or, for /api/auth/owner, the owner key) from the settings file itself, as
# setup-link.sh does. What it prints back is the app's answer, as name=value lines, never a key.
api() {
  "$NODE_DIR/bin/node" "$TMP/hq-api.mjs" "$1" "$APP/.env" "$PORT"
}
write_api_helper() {
  cat >"$TMP/hq-api.mjs" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
const [route, envFile, port] = process.argv.slice(2);
const settings = {};
for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) { const m = /^([A-Z0-9_]+)=(.*)$/.exec(line); if (m) settings[m[1]] = m[2]; }
let secret = settings.SESSION_SECRET;
if (!secret) { try { secret = fs.readFileSync(path.join(path.dirname(settings.DB_PATH || '/opt/hq/data/hq.db'), 'session.secret'), 'utf8').trim(); } catch { secret = ''; } }
const hmac = (what) => crypto.createHmac('sha256', secret).update(what).digest('hex');
const body = {};
for (const line of fs.readFileSync(0, 'utf8').split('\n')) { const i = line.indexOf('='); if (i > 0) body[line.slice(0, i)] = line.slice(i + 1); }
const headers = { 'content-type': 'application/json' };
if (route === '/api/auth/owner') { headers.authorization = `Bearer ${hmac('owner-login')}`; body.link = body.link === 'true'; }
else { const h = hmac('setup-code').slice(0, 16).toUpperCase(); body.code = `${h.slice(0, 4)}-${h.slice(4, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}`; }
const one = (v) => String(v ?? '').replace(/\s+/g, ' ').trim();
const out = [];
try {
  const res = await fetch(`http://127.0.0.1:${port}${route}`, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(120_000) });
  let j = {};
  try { j = await res.json(); } catch { /* not JSON */ }
  out.push(`status=${res.status}`);
  for (const k of ['ok', 'error', 'running', 'name', 'privateUrl', 'serveProblem', 'url']) if (j[k] !== undefined && j[k] !== null) out.push(`${k}=${one(j[k])}`);
  const c = j.check;
  if (c) {
    out.push(`check_ok=${c.ok === true}`, `summary=${one(c.summary)}`);
    if (c.problem) out.push(`problem=${one(c.problem)}`);
    for (const x of c.choices ?? []) out.push(`choice=${one(x.id)} ${one(x.name)}`);
  }
} catch (e) {
  out.push('status=0', `error=Bot HQ did not answer on this computer (${one(e.message)}).`);
}
console.log(out.join('\n'));
NODE
}
# The value of name=value in the helper's answer.
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
# What the browser shows when a check fails, into TOLD: its summary, then what is wrong.
TOLD=()
tell() {
  local summary problem error
  summary="$(val "$1" summary)"; problem="$(val "$1" problem)"; error="$(val "$1" error)"
  TOLD=()
  if [ -n "$summary" ] && [ "$(val "$1" check_ok)" != true ]; then
    TOLD+=("$summary")
    [ -z "$problem" ] || TOLD+=("$problem")
  elif [ -n "$error" ]; then TOLD+=("$error")
  else TOLD+=("Bot HQ did not accept that (it answered $(val "$1" status)).")
  fi
}
# A refusal behind the red bar, with $1 after it when there is another try ($2 the tries so far).
refused() {
  if [ "$2" -lt 3 ]; then redbar 1 "${TOLD[@]}" "$1"; else redbar 0 "${TOLD[@]}"; fi
}

# Test a key with the check the wizard uses, then save it as the wizard does. $1: the check, $2: the
# setting, $3: the key. Succeeds when the key was saved, with its summary in SAVED; otherwise the
# app's words are in TOLD.
check_and_save() {
  local r
  r="$(printf 'what=%s\n%s=%s\n' "$1" "$2" "$3" | api /api/setup/check)"
  if [ "$(val "$r" check_ok)" = true ]; then
    SAVED="$(val "$r" summary)"
    r="$(printf '%s=%s\n' "$2" "$3" | api /api/setup/save)"
    if [ "$(val "$r" status)" = 200 ]; then return 0; fi
  fi
  tell "$r"
  return 1
}

# Orgo's id for this computer, when the computer says it: Orgo's identity service inside the computer
# (its answer names the computer as desktop_id; the token that comes with it is not kept), else an
# ORGO_COMPUTER_ID given to the installer or found in root's .env files, where Orgo writes a
# template's settings. Empty when there is none.
detect_computer_id() {
  local v out uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  local re='"desktop_id"[[:space:]]*:[[:space:]]*"([0-9a-fA-F-]{36})"'
  DETECTED_ID=""
  out="$("$CURL" -fsS -m 3 --noproxy '*' -H 'Metadata-Flavor: Orgo' "$METADATA/orgo/v1/identity/token" 2>/dev/null || true)"
  if [[ "$out" =~ $re ]]; then DETECTED_ID="${BASH_REMATCH[1]}"; fi
  out=""
  [ -z "$DETECTED_ID" ] || return 0
  for v in "${ORGO_COMPUTER_ID:-}" "$(key ORGO_COMPUTER_ID "$ROOT/root/.env")" "$(key ORGO_COMPUTER_ID "$ROOT/root/.orgo-secrets.env")"; do
    if [[ "$v" =~ $uuid ]]; then DETECTED_ID="$v"; return 0; fi
  done
}

ask_orgo() {
  local k="" id r tries=0 n line pick ids=()
  detect_computer_id
  q_head "[1/5]" "Orgo" "the computer your Bots work on"
  q_info "An Orgo API key that reaches this computer: one for this computer, or for your whole account."
  q_where "orgo.ai › Settings › API keys"
  [ -z "$DETECTED_ID" ] || q_info "This computer's ID in Orgo: $DETECTED_ID (found on the computer)."
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    if [ -z "$k" ]; then
      ask_secret "Orgo key" "Enter to skip"; k="$ANSWER"
      [ -n "$k" ] || { skipped Orgo; return 0; }
    fi
    id="$DETECTED_ID"
    if [ -z "$id" ]; then ask_line "This computer's ID in Orgo" "a long code with dashes; Enter to list your computers"; id="$ANSWER"; fi
    r="$(printf 'what=orgo\norgoKey=%s\norgoComputerId=%s\n' "$k" "$id" | api /api/setup/check)"
    if [ "$(val "$r" check_ok)" != true ] && printf '%s\n' "$r" | grep -q '^choice='; then
      q_more "$(val "$r" problem)"
      n=0; ids=()
      while IFS= read -r line; do
        n=$((n + 1)); ids+=("${line%% *}")
        printf '      %s%s.%s %s %s(%s)%s\n' "$c_o" "$n" "$c_n" "${line#* }" "$c_dim" "${line%% *}" "$c_n"
      done < <(printf '%s\n' "$r" | sed -n 's/^choice=//p')
      ask_line "Which one is this computer?" "its number; Enter to skip"; pick="$ANSWER"
      if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$n" ]; then k=""; skipped Orgo; return 0; fi
      id="${ids[$((pick - 1))]}"
      r="$(printf 'what=orgo\norgoKey=%s\norgoComputerId=%s\n' "$k" "$id" | api /api/setup/check)"
    fi
    if [ "$(val "$r" check_ok)" = true ]; then
      local summary; summary="$(val "$r" summary)"
      r="$(printf 'orgoKey=%s\norgoComputerId=%s\n' "$k" "$id" | api /api/setup/save)"
      if [ "$(val "$r" status)" = 200 ]; then k=""; q_ok "Saved. $summary."; answered Orgo; return 0; fi
    fi
    tell "$r"
    # The key works but cannot list computers (a key for one computer): keep it, ask for the ID.
    if [ "$(val "$r" summary)" = "Computer needed" ] && [ -z "$DETECTED_ID" ]; then redbar 0 "${TOLD[@]}"; continue; fi
    k=""
    refused "Try again, or press Enter to skip." "$tries"
  done
  k=""; skipped Orgo
}

ask_tailscale() {
  local k r p i tries=0
  q_head "[2/5]" "Tailscale" "your private network"
  q_info "An auth key joins this computer to it: a private address with no Orgo sign-in in front, and a way to reach your coding machines."
  q_where "login.tailscale.com › Settings › Keys"
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    ask_secret "Tailscale key" "starts with tskey-auth-; Enter to skip"; k="$ANSWER"
    [ -n "$k" ] || { skipped Tailscale; return 0; }
    r="$(printf 'authKey=%s\npurpose=address\n' "$k" | api /api/setup/network)"
    k=""; ANSWER=""
    if [ "$(val "$r" status)" = 202 ]; then
      step "Joining (Tailscale is downloaded first; this takes a few minutes)"
      i=0; p=""
      while [ $i -lt "$NET_POLLS" ]; do
        sleep "$POLL"; i=$((i + 1))
        p="$(printf '' | api /api/setup/network/progress)"
        [ "$(val "$p" running)" = true ] || break
      done
      step_end
      if [ "$(val "$p" ok)" = true ]; then
        q_ok "Joined the private network as $(val "$p" name)."
        if [ -n "$(val "$p" privateUrl)" ]; then q_more "Private address: $(val "$p" privateUrl)"
        else q_more "It has no private address yet: $(val "$p" serveProblem)"; fi
        answered Tailscale
        return 0
      fi
      if [ "$(val "$p" running)" = true ]; then q_more "Still joining. The browser shows how it went."; answered Tailscale; return 0; fi
      tell "$p"
    else
      tell "$r"
    fi
    refused "Try again with a new key, or press Enter to skip." "$tries"
  done
  skipped Tailscale
}

# $1 step, $2 name, $3 what it is for, $4 the check, $5 the setting, $6 what it is, $7 where to get one,
# $8 the hint at the prompt.
ask_key() {
  local tries=0
  q_head "$1" "$2" "$3"
  q_info "$6"
  q_where "$7"
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    ask_secret "$2 key" "$8"
    [ -n "$ANSWER" ] || { skipped "$2"; return 0; }
    if check_and_save "$4" "$5" "$ANSWER"; then ANSWER=""; q_ok "Saved. $SAVED."; answered "$2"; return 0; fi
    ANSWER=""
    refused "Try again, or press Enter to skip." "$tries"
  done
  skipped "$2"
}

OWNER_EMAIL=""
ask_owner() {
  local name email r tries=0
  q_head "[5/5]" "The owner" "who runs this Bot HQ"
  q_info "You invite people and manage this Bot HQ. You sign in with this email."
  ask_line "Name" "Enter to skip"; name="$ANSWER"
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    ask_line "Email" "the one you will sign in with; Enter to skip"; email="$ANSWER"
    [ -n "$email" ] || { skipped "Owner"; return 0; }
    r="$(printf 'email=%s\nname=%s\n' "$email" "$name" | api /api/setup/owner)"
    if [ "$(val "$r" status)" = 200 ]; then
      OWNER_EMAIL="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')"
      q_ok "You are the owner. Only people you invite can sign in."; answered "Owner"; return 0
    fi
    tell "$r"
    refused "Try again, or press Enter to skip." "$tries"
  done
  skipped "Owner"
}

ask_questions() {
  open_tty || return 0
  { [ -x "$NODE_DIR/bin/node" ] && [ -n "$TMP" ] && [ -d "$TMP" ]; } || return 0
  write_api_helper
  if [ "$FANCY" = 1 ]; then
    printf '\n'; rule
    printf '  %s%sFive questions%s  %sPress Enter to skip any; the browser asks for what you skip.%s\n' "$c_cream" "$c_b" "$c_n" "$c_dim" "$c_n"
    printf '  %sEach key is checked as you give it, with the same checks as in the browser.%s\n' "$c_dim" "$c_n"
    rule
  else
    say "" "Five questions. Press Enter to skip any; the browser asks for what you skip." \
        "Each key is checked as you give it, with the same checks as in the browser."
  fi
  ask_orgo
  ask_tailscale
  ask_key "[3/5]" Composio "your Bots' apps: Gmail, Slack, calendars…" composio composioKey \
    "A project API key. Composio connects apps such as Gmail and Slack, and powers Google sign-in." \
    "platform.composio.dev › your project › Settings › API Keys" "starts with ak_; Enter to skip"
  ask_key "[4/5]" xAI "voice, dictation and research on X · optional" xai xaiKey \
    "An API key. Bots think and reply without it." "console.x.ai › API Keys" "Enter to skip"
  ask_owner
}

# ---------------------------------------------------------------- 11. the end

# Whether the public address reaches this Bot HQ, when that can be seen from inside the computer. It
# is only said, never a reason to stop: an Orgo computer may not reach its own public address.
check_address() {
  [ "$UPGRADE" = 0 ] && [ -n "$PUBLIC" ] || return 0
  local code
  step "Checking the address answers"
  code="$("$CURL" -sS -m 10 -o "$TMP/public-health" -w '%{http_code}' "$PUBLIC/api/health" 2>/dev/null || true)"
  if [ "$code" = 200 ] && grep -q '"ok":true' "$TMP/public-health" 2>/dev/null; then
    step_ok "The address answers" "$PUBLIC"
  elif [[ "$code" =~ ^(30[1-8]|401|403)$ ]]; then
    step_ok "The address answers" "Orgo may ask you to sign in first"
  elif [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
    step_warn "The address answers, but not with Bot HQ (it said $code)" "check that its Public URL in Orgo is for port $PORT"
  else
    step_warn "The address could not be checked from this computer" "that can be normal; open it in your browser to check"
  fi
  rm -f "$TMP/public-health"
}

# After the questions: the link that opens the setup wizard (or, once the owner is made here, signs
# them in and carries on with it), in LINK, with what it does and how to get another.
LINK=""; LINK_CODE=""; LINK_NOTE=""; LINK_AGAIN=""
print_next_steps() {
  give_tools
  check_address
  needs_setup || return 0
  ask_questions
  if [ -n "$OWNER_EMAIL" ]; then
    # The owner exists now, so the setup code opens nothing any more: a one-time sign-in link takes
    # them on to the rest of the setup wizard instead.
    local r url
    r="$(printf 'email=%s\nlink=true\n' "$OWNER_EMAIL" | api /api/auth/owner)"
    url="$(val "$r" url)"
    if [ -n "$url" ]; then
      LINK="$url?then=setup"
      LINK_NOTE="It signs you in (once, within 15 minutes) and asks for whatever is not set up yet."
    else
      LINK_NOTE="The sign-in link could not be made ($(val "$r" error))."
    fi
    LINK_AGAIN="For a new link: bash /opt/hq/app/scripts/sign-in-link.sh $OWNER_EMAIL --setup"
    return 0
  fi
  local out
  out="$(ENV_FILE="$APP/.env" bash "$APP/scripts/setup-link.sh" 2>&1)" || out=""
  LINK="$(printf '%s\n' "$out" | sed -n 's/^Setup link: //p' | head -1)"
  LINK_CODE="$(printf '%s\n' "$out" | sed -n 's/^Setup code: //p' | head -1)"
  if [ -n "$LINK" ]; then LINK_NOTE="It asks for whatever is not set up yet and tests each one."
  else LINK_NOTE="(The link could not be printed. Run: bash /opt/hq/app/scripts/setup-link.sh)"; fi
  LINK_AGAIN="To see the link again later: bash /opt/hq/app/scripts/setup-link.sh"
}

# The finish: what was set up and what was skipped, then the link to open on a line of its own, so it
# is easy to select. $1 the headline, $2 a line under it, $3 the same in plain words (for a log), $4
# the address to open when there is no setup link.
finish() {
  local head="$1" sub="$2" plain="$3" open="$4" item done_here="" skipped_here="" row=""
  for item in ${Q_DONE[@]+"${Q_DONE[@]}"}; do
    case "$item" in
      +*) done_here="${done_here:+$done_here, }${item#+}"; row+="${c_ok}✓${c_n} ${item#+}    " ;;
      -*) skipped_here="${skipped_here:+$skipped_here, }${item#-}"; row+="${c_dim}– ${item#-} (skipped)${c_n}    " ;;
    esac
  done
  if [ "$FANCY" = 0 ]; then
    say "" "$plain"
    case "$plain" in *"$sub"*) ;; *) say "$sub" ;; esac
    if [ -n "$done_here$skipped_here" ]; then
      say "Answered here: ${done_here:-nothing}. Skipped, for the browser: ${skipped_here:-nothing}."
    fi
    if [ -n "$LINK" ]; then
      say "Next: open the setup link below in your browser. $LINK_NOTE"
      [ -z "$LINK_CODE" ] || say "Setup code: $LINK_CODE"
      say "Setup link: $LINK"
    elif [ -n "$LINK_NOTE" ]; then say "$LINK_NOTE"
    elif [ -n "$open" ]; then say "Open it at: $open"
    fi
    [ -z "$LINK_AGAIN" ] || say "$LINK_AGAIN"
    return 0
  fi
  printf '\n'; rule
  printf '  %s%s✓ %s%s\n' "$c_ok" "$c_b" "$head" "$c_n"
  [ -z "$sub" ] || wrapped "  " "  " 2 "$sub" "$c_dim"
  [ -z "$row" ] || printf '\n    %s\n' "$row"
  if [ -n "$LINK" ]; then
    printf '\n  Open this in your browser to finish the setup:\n\n    %s %s %s\n\n' "$c_hl" "$LINK" "$c_n"
    wrapped "  " "  " 2 "$LINK_NOTE" "$c_dim"
    [ -z "$LINK_CODE" ] || printf '  %sSetup code: %s%s\n' "$c_dim" "$LINK_CODE" "$c_n"
  elif [ -n "$LINK_NOTE" ]; then printf '\n'; redbar 0 "$LINK_NOTE"
  elif [ -n "$open" ]; then printf '\n  Open it in your browser:\n\n    %s %s %s\n' "$c_hl" "$open" "$c_n"
  fi
  [ -z "$LINK_AGAIN" ] || wrapped "  " "  " 2 "$LINK_AGAIN" "$c_dim"
  rule; printf '\n'
}

main() {
  set -E
  trap 'on_err $LINENO' ERR
  ui_init
  parse_args "$@"
  umask 077
  preflight
  if [ "$UPGRADE" = 1 ]; then
    banner "Updating Bot HQ on this computer" "Installed now: $(pkg_version "$APP/package.json" || true). Your settings and data are kept, with a backup first."
  else
    banner "Setting up Bot HQ$(coming_version) for this computer" "Your team of AI Bots, each with its own computer."
  fi
  ask_url
  lock
  trap cleanup EXIT
  recover
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-install.XXXXXX")"
  get_pack
  hermes_api_on

  OLD_VERSION=""; [ "$UPGRADE" = 0 ] || OLD_VERSION="$(pkg_version "$APP/package.json")"
  OLD_LABEL="${OLD_VERSION:-the version from before}"
  if [ "$UPGRADE" = 1 ] && [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" = "$NEW_VERSION" ] && healthy "$NEW_VERSION"; then
    step_ok "Bot HQ $NEW_VERSION is already installed and running. Nothing was changed."
    print_next_steps
    [ -z "${KEYS_FILE:-}" ] || rm -f "$KEYS_FILE"
    if [ "$FANCY" = 1 ] || [ -n "$LINK$LINK_NOTE" ]; then
      finish "Bot HQ $NEW_VERSION is up to date" "" "Bot HQ $NEW_VERSION is already installed and running." "$(key APP_URL "$APP/.env")"
    fi
    return 0
  fi

  mkdir -p "$DATA" "$NODE_DIR" "$LOGS"
  install_node
  export PATH="$NODE_DIR/bin:$PATH"
  stage
  if [ "$UPGRADE" = 1 ]; then
    backup
    carry_over
  else
    write_settings "$NEW/.env"
  fi
  [ -z "${KEYS_FILE:-}" ] || rm -f "$KEYS_FILE"
  write_conf
  switch_over

  # A pack with no version number (an old backup put back) cannot say which version it is.
  if ! wait_healthy "$NEW_VERSION"; then
    if [ "$UPGRADE" = 1 ]; then roll_back; fi
    stop "Bot HQ was installed but did not start (its log is $LOGS/app.log)." \
         "Run the same command again in a minute. If it still does not start, send that log to whoever publishes Bot HQ."
  fi
  if [ "$UPGRADE" = 1 ]; then step_ok "Switched to $NEW_LABEL and started"; else step_ok "Installed and started" "$PUBLIC"; fi
  FINISHED=1
  rm -rf "$PREV"
  write_mcp_entry
  [ "$UPGRADE" = 0 ] || prune_backups
  print_next_steps
  if [ "$UPGRADE" = 1 ]; then
    finish "Bot HQ is upgraded from ${OLD_VERSION:-an earlier version} to $NEW_LABEL" \
      "Your settings and data were kept. The backup from just before is in $BACKUP." \
      "Done. Bot HQ is upgraded from ${OLD_VERSION:-an earlier version} to $NEW_LABEL and running." "$(key APP_URL "$APP/.env")"
  else
    finish "Bot HQ is ready" "Bot HQ $NEW_LABEL is installed and running at $PUBLIC" \
      "Done. Bot HQ $NEW_LABEL is installed and running at $PUBLIC" "$PUBLIC"
  fi
}

# For the banner, in a terminal: the version this run is about to install, when it is quick to tell
# (" 0.4.0"), else nothing. Only the download itself decides what is installed.
coming_version() {
  [ "$FANCY" = 1 ] || return 0
  local v="$OPT_VERSION"
  if [ -z "$v" ] && [ -n "$OPT_FILE" ]; then
    v="$(tar -xzOf "$OPT_FILE" package.json 2>/dev/null | sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' | head -1 || true)"
  elif [ -z "$v" ]; then
    v="$("$CURL" -fsSL -m 5 "$RELEASES/latest" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
  fi
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ]] && printf ' %s' "$v" || true
}

main "$@"
