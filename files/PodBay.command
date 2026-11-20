#!/bin/bash
# PodBay launcher (macOS; double-click in Finder, or run from a terminal). Also runs on Linux for testing.
#
# What it does:
#   1. finds llama-server (LLAMA_SERVER, then PATH, then Homebrew's /opt/homebrew/bin and /usr/local/bin)
#   2. finds the base model: the *.gguf in podbay/models/. With several, Olmo 3 7B Think is the default;
#      PODBAY_MODEL picks another (a path, a file name, or a word in the file name: PODBAY_MODEL=gemma).
#      When the only base there is a Gemma GGUF, it is used without asking.
#   3. finds the bricks: every *.gguf in podbay/bricks/ (LoRA adapter GGUFs made by convert_brick.sh). A brick made
#      for another base is left out (an Olmo adapter cannot be applied to a Gemma base, and the reverse): the base and
#      the brick are matched by their file names (olmo / gemma...26b / gemma...e4b). PODBAY_ALL_BRICKS=1 loads all.
#      With a Gemma base the server is started with thinking off in the chat template
#      (--chat-template-kwargs {"enable_thinking":false}), because that is the prompt the adapter was trained and
#      scored on; llama-server's default turns Gemma's thinking on, which is a different prompt. PODBAY_THINKING=1
#      keeps the server's default. `brick.py check-prompt` compares the running server's prompt with the training one.
#   4. checks free memory and refuses to start when it is clearly too small for the model
#   5. starts llama-server on 127.0.0.1 with every brick loaded at scale 0 (--lora-scaled <file>:0), so the base
#      answers as it would with no adapter. A brick is switched on PER REQUEST, no reload: the page server and
#      brick.py send "lora": [{"id": 0, "scale": s}] and "cache_prompt": false with every request.
#      Why not the server-wide switch (POST /lora-adapters) alone: measured on build b12110 with the real brick, a
#      prompt already in the prompt cache kept its old answer after it (0 of 6 scenes), while the per-request field,
#      or "cache_prompt": false, followed the scale (6 of 6): podbay/results/rlvr/run16/gguf/README.md.
#      So the launcher also turns the server's prompt cache off (--no-cache-prompt, when the build has the flag),
#      which makes llama-ui and a plain curl follow a server-wide switch too; PODBAY_PROMPT_CACHE=1 keeps the cache.
#   6. starts podbay/web/local_server.py if it exists, checks that it is really the one answering on the web port
#      (GET /health says "server": "podbay-local"), and opens the simulator page. If the page server does not come
#      up (no working python3, the port taken, a crash), it says so, shows the page server's log, stops
#      llama-server and exits with an error. python3 and the web port are checked before llama-server starts.
#   7. prints the llama-ui address (llama.cpp's own chat page) for plain chat; Ctrl-C stops everything
#
# Settings (environment variables, all optional):
#   LLAMA_SERVER       path to llama-server
#   PODBAY_MODEL       the base GGUF: a path, a file name in podbay/models, or a word in the file name (gemma, olmo,
#                      Q4_K_XL; the largest match). Default: the only *.gguf in podbay/models; with several, the
#                      largest Olmo file, or the largest file when there is no Olmo
#   PODBAY_ALL_BRICKS=1  load every brick, also those named for another base (llama-server may then refuse to start)
#   PODBAY_THINKING=1  Gemma only: leave thinking as llama-server sets it (on). The adapter was not trained that way
#   PODBAY_MODELS_DIR  default podbay/models          PODBAY_BRICKS_DIR  default podbay/bricks
#   LLAMA_PORT         default 8080                   PODBAY_WEB_PORT    default 8765
#   PODBAY_CTX         context length, default 4096   PODBAY_THREADS     default: llama-server's choice
#   PODBAY_EXTRA_ARGS  extra llama-server arguments (split on spaces)
#   PODBAY_FORCE=1     start even when the memory check fails      PODBAY_NO_OPEN=1  do not open a browser
#   PODBAY_PROMPT_CACHE=1  keep llama-server's prompt cache on (faster long chats in llama-ui; a server-wide brick
#                      switch may then answer a repeated prompt with the old scale)
#   PODBAY_PYTHON      python for local_server.py (default python3)
#   PODBAY_BRICK_ID    which loaded brick (llama-server adapter id) the page's switch drives, default 0; the others
#                      are held at 0, so bricks are never stacked

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PODBAY="$(cd "$HERE/.." && pwd)"
MODELS_DIR="${PODBAY_MODELS_DIR:-$PODBAY/models}"
BRICKS_DIR="${PODBAY_BRICKS_DIR:-$PODBAY/bricks}"
PORT="${LLAMA_PORT:-8080}"
WEB_PORT="${PODBAY_WEB_PORT:-8765}"
CTX="${PODBAY_CTX:-4096}"
PY="${PODBAY_PYTHON:-python3}"
LOG_DIR="${TMPDIR:-/tmp}/podbay-$$"
mkdir -p "$LOG_DIR"

say()  { printf '%s\n' "$*"; }
fail() { printf '\nPodBay cannot start: %s\n' "$*" >&2; pause_if_finder; exit 1; }
# When double-clicked, Terminal closes the window's process at exit; keep the message readable.
pause_if_finder() { if [ -t 0 ] && [ -z "${PODBAY_NO_PAUSE:-}" ]; then printf 'Press Return to close. '; read -r _ || true; fi; }

# ---------- 1. llama-server ----------
LS=""
if [ -n "${LLAMA_SERVER:-}" ]; then
  [ -x "$LLAMA_SERVER" ] || fail "LLAMA_SERVER=$LLAMA_SERVER is not an executable file."
  LS="$LLAMA_SERVER"
else
  for c in "$(command -v llama-server 2>/dev/null)" /opt/homebrew/bin/llama-server /usr/local/bin/llama-server; do
    if [ -n "$c" ] && [ -x "$c" ]; then LS="$c"; break; fi
  done
fi
[ -n "$LS" ] || fail "llama-server was not found.
  Install it with Homebrew:   brew install llama.cpp
  or point to your own build: LLAMA_SERVER=/path/to/llama-server \"$0\""
LS_HELP="$("$LS" --help 2>&1)"
has_flag() { printf '%s\n' "$LS_HELP" | grep -q -- "$1"; }
if ! has_flag "--lora-scaled"; then
  fail "$LS is too old (no --lora-scaled). Update it: brew upgrade llama.cpp"
fi

# ---------- 2. base model ----------
# Which base a file is, from its name (lower-cased): olmo, gemma-26b, gemma-e4b, gemma (another size), or nothing.
family_of() {
  case "$(basename "$1" | tr '[:upper:]' '[:lower:]')" in
    *olmo*) echo olmo ;;
    *gemma*26b*) echo gemma-26b ;;
    *gemma*e4b*) echo gemma-e4b ;;
    *gemma*) echo gemma ;;
    *) echo "" ;;
  esac
}
# The largest base GGUF in $MODELS_DIR whose lower-cased file name contains $1 ("" = any); sets PICK and PICK_N.
pick_base() {
  PICK=""; PICK_N=0; picksize=0
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for f in "$MODELS_DIR"/*.gguf; do
    [ -f "$f" ] || continue
    low="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    case "$low" in *mmproj*) continue ;; esac                       # vision projectors are not base models
    case "$low" in *"$want"*) ;; *) continue ;; esac
    PICK_N=$((PICK_N + 1))
    s=$(wc -c < "$f" | tr -d ' ')
    if [ "$s" -gt "$picksize" ]; then PICK="$f"; picksize="$s"; fi
  done
}
MODEL=""
if [ -n "${PODBAY_MODEL:-}" ]; then
  if [ -f "$PODBAY_MODEL" ]; then MODEL="$PODBAY_MODEL"; elif [ -f "$MODELS_DIR/$PODBAY_MODEL" ]; then MODEL="$MODELS_DIR/$PODBAY_MODEL"
  else
    pick_base "$PODBAY_MODEL"
    [ -n "$PICK" ] || fail "PODBAY_MODEL=$PODBAY_MODEL is neither a file, nor a file in $MODELS_DIR, nor a word in the name of a *.gguf there."
    MODEL="$PICK"
    [ "$PICK_N" -gt 1 ] && say "$PICK_N base models in $MODELS_DIR match PODBAY_MODEL=$PODBAY_MODEL; using the largest, $(basename "$MODEL")."
  fi
else
  pick_base ""
  n="$PICK_N"; best="$PICK"
  if [ "$n" -eq 0 ]; then
    fail "no base model (*.gguf) in $MODELS_DIR.
  Get the base the brick was trained for (Olmo 3 7B Think, Q4_K_M is about 4.5 GB):
    brew install huggingface-cli
    hf download unsloth/Olmo-3-7B-Think-GGUF Olmo-3-7B-Think-Q4_K_M.gguf --local-dir \"$MODELS_DIR\"
  (older installs: huggingface-cli download ... with the same arguments)
  or, for the Gemma 4 26B-A4B brick (UD-Q4_K_XL is about 17 GB):
    hf download unsloth/gemma-4-26B-A4B-it-GGUF gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf --local-dir \"$MODELS_DIR\"
  A base GGUF you already have elsewhere works too: PODBAY_MODEL=/path/to/file.gguf \"$0\""
  fi
  MODEL="$best"
  if [ "$n" -gt 1 ]; then
    pick_base olmo                                                   # Olmo 3 7B Think stays the default
    if [ -n "$PICK" ]; then
      MODEL="$PICK"
      say "Several base models in $MODELS_DIR; using the default, $(basename "$MODEL")."
    else
      say "Several base models in $MODELS_DIR; using the largest, $(basename "$MODEL")."
    fi
    say "  (choose another with PODBAY_MODEL=<file name, or a word in it such as gemma>)"
  fi
fi
FAMILY="$(family_of "$MODEL")"

# ---------- 3. bricks ----------
LORA_ARGS=()
BRICKS=""
BRICK_MB=0
SKIPPED=""
for f in "$BRICKS_DIR"/*.gguf; do
  [ -f "$f" ] || continue
  # A brick fits one base. When both file names say which, and they differ, leave the brick out.
  bf="$(family_of "$f")"
  if [ -z "${PODBAY_ALL_BRICKS:-}" ] && [ -n "$bf" ] && [ -n "$FAMILY" ] && [ "$bf" != "$FAMILY" ]; then
    SKIPPED="$SKIPPED $(basename "$f" .gguf)"
    continue
  fi
  # --lora-scaled <file>:0 is what starts a brick switched off. --lora with --lora-init-without-apply did not: with
  # llama-server built 19 Nov 2026 (76f186d) it still reported scale 1 and answered with the brick on
  # (podbay/run/README.md). A file name with a comma or a colon would confuse the FNAME:SCALE,... syntax.
  case "$f" in *,*|*:*) fail "the brick's path has a comma or a colon, which llama-server's --lora-scaled cannot take: $f" ;; esac
  LORA_ARGS+=(--lora-scaled "$f:0")
  BRICKS="$BRICKS $(basename "$f" .gguf)"
  BRICK_MB=$(( BRICK_MB + $(wc -c < "$f" | tr -d ' ') / 1048576 ))
done
[ -n "$SKIPPED" ] && say "Bricks left out (made for another base than $(basename "$MODEL")):$SKIPPED"
if [ ${#LORA_ARGS[@]} -eq 0 ]; then
  say "No bricks (*.gguf) for this base in $BRICKS_DIR: the model runs without an adapter."
  say "  Make one from a PEFT adapter directory:  podbay/run/convert_brick.sh <adapter dir> <name>"
fi

# ---------- 4. memory ----------
# Free memory in MB: macOS counts free + inactive + speculative pages (memory the system hands out on demand);
# Linux uses MemAvailable. The model file is memory-mapped, so it needs about its own size, plus the KV cache
# and compute buffers (a few hundred MB to a few GB depending on context).
free_mb() {
  if command -v vm_stat >/dev/null 2>&1; then
    vm_stat | awk '/page size of/ {ps=$8} /Pages free/ {f=$3} /Pages inactive/ {i=$3} /Pages speculative/ {s=$3}
      END {gsub(/\./,"",f); gsub(/\./,"",i); gsub(/\./,"",s); if (ps==0) ps=16384; printf "%d\n", (f+i+s)*ps/1048576}'
  elif [ -r /proc/meminfo ]; then
    awk '/MemAvailable/ {printf "%d\n", $2/1024}' /proc/meminfo
  else
    echo 0
  fi
}
MODEL_MB=$(( $(wc -c < "$MODEL" | tr -d ' ') / 1048576 ))
# KV cache: about 0.5 MB per token for a 7B model with full multi-head attention (32 layers x 4096 x K and V x f16);
# models with grouped-query attention need less: Gemma 4 26B-A4B has 30 layers x 8 key-value heads x 256 x K and V
# x f16 = 240 KB per token (its config.json). PODBAY_KV_KB_PER_TOKEN overrides the estimate.
KV_DEFAULT=512; [ "$FAMILY" = "gemma-26b" ] && KV_DEFAULT=240
KV_MB=$(( CTX * ${PODBAY_KV_KB_PER_TOKEN:-$KV_DEFAULT} / 1024 ))
NEED_MB=$(( MODEL_MB + BRICK_MB + 512 + KV_MB ))   # weights + bricks + compute buffers + KV cache
FREE_MB=$(free_mb)
say "Base model:  $(basename "$MODEL") (${MODEL_MB} MB)"
say "Bricks:     ${BRICKS:- none} (${BRICK_MB} MB)"
say "Memory:      about ${FREE_MB} MB free, about ${NEED_MB} MB needed (KV cache for ${CTX} tokens: about ${KV_MB} MB)"
if [ "$FREE_MB" -gt 0 ] && [ "$FREE_MB" -lt "$NEED_MB" ]; then
  if [ -z "${PODBAY_FORCE:-}" ]; then
    fail "not enough free memory: about ${FREE_MB} MB free, the model needs about ${NEED_MB} MB.
  Close some apps (browsers with many tabs are the usual culprit), or use a smaller quantisation
  (for example a Q4_K_M instead of a Q8_0), or a shorter context (PODBAY_CTX=2048).
  To start anyway: PODBAY_FORCE=1 \"$0\""
  fi
  say "Memory looks too small, starting anyway because PODBAY_FORCE is set."
elif [ "$FREE_MB" -gt 0 ] && [ "$FREE_MB" -lt $(( NEED_MB * 3 / 2 )) ]; then
  say "Memory is tight; the Mac may swap and answers may be slow."
fi

# ---------- 5. llama-server ----------
if curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  fail "something already answers on port $PORT (another llama-server?). Stop it, or pick another port: LLAMA_PORT=8081 \"$0\""
fi
LOCAL_SERVER="$PODBAY/web/local_server.py"
if [ -f "$LOCAL_SERVER" ]; then
  # The page server needs a python3 that runs. On a Mac without the Xcode command-line tools, /usr/bin/python3 is
  # only a stub that asks to install them, so run it rather than just look for it.
  if ! command -v "$PY" >/dev/null 2>&1 || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    fail "the simulator's page server needs Python 3.8 or newer, and $PY does not run here.
  On a Mac, install it with:  xcode-select --install
  or point to another one:    PODBAY_PYTHON=/path/to/python3 \"$0\""
  fi
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:$WEB_PORT/" 2>/dev/null; then
    fail "something already answers on port $WEB_PORT, which the simulator page needs (another PodBay still running?).
  Stop it, or pick another port: PODBAY_WEB_PORT=8766 \"$0\""
  fi
fi
PIDS=""
cleanup() {
  trap - INT TERM EXIT
  if [ -n "$PIDS" ]; then
    say ""
    say "Stopping PodBay ..."
    kill $PIDS 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      alive=0; for p in $PIDS; do kill -0 "$p" 2>/dev/null && alive=1; done
      [ "$alive" -eq 0 ] && break
      sleep 0.5
    done
    kill -9 $PIDS 2>/dev/null
    say "Stopped. Logs are in $LOG_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

EXTRA=()
# The run16 evaluation started the server with --lora-scaled <file>:0 AND --lora-init-without-apply; the second flag
# changes nothing we rely on (it did not start a brick off by itself), so it is passed only where the build has it.
if [ ${#LORA_ARGS[@]} -gt 0 ] && has_flag "--lora-init-without-apply"; then EXTRA+=(--lora-init-without-apply); fi
if [ -z "${PODBAY_PROMPT_CACHE:-}" ] && has_flag "--no-cache-prompt"; then EXTRA+=(--no-cache-prompt); fi
# Gemma: llama-server renders the chat template with thinking ON unless told otherwise (a "<|think|>" line in the
# system turn, and the model then writes a thought channel first). The adapter was trained and scored with thinking
# off, where the prompt ends with an empty thought channel. enable_thinking=false gives that prompt: checked with
# llama-server 76f186d and Gemma 4 26B-A4B's chat_template.jinja against the evaluation's recorded prompt
# (podbay/run/README.md, "Gemma 4 26B-A4B").
case "$FAMILY" in gemma*)
  if [ -n "${PODBAY_THINKING:-}" ]; then
    say "PODBAY_THINKING is set: Gemma's thinking stays as llama-server sets it. The adapter was not trained on that prompt."
  elif has_flag "--chat-template-kwargs"; then
    EXTRA+=(--chat-template-kwargs '{"enable_thinking":false}')
  else
    say "This llama-server has no --chat-template-kwargs, so Gemma's thinking stays on: not the prompt the adapter"
    say "  was trained on. Update it: brew upgrade llama.cpp"
  fi ;;
esac
[ -n "${PODBAY_THREADS:-}" ] && EXTRA+=(-t "$PODBAY_THREADS")
# shellcheck disable=SC2206
[ -n "${PODBAY_EXTRA_ARGS:-}" ] && EXTRA+=($PODBAY_EXTRA_ARGS)

say ""
say "Starting llama-server on 127.0.0.1:$PORT (log: $LOG_DIR/llama-server.log) ..."
"$LS" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -c "$CTX" --jinja --reasoning-format deepseek \
  ${LORA_ARGS[@]+"${LORA_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} \
  > "$LOG_DIR/llama-server.log" 2>&1 &
LS_PID=$!
PIDS="$LS_PID"

ok=0
for _ in $(seq 1 600); do      # up to 5 minutes: a 7B model can take a while to map the first time
  if ! kill -0 "$LS_PID" 2>/dev/null; then break; fi
  if curl -s -m 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok"'; then ok=1; break; fi
  sleep 0.5
done
if [ "$ok" -ne 1 ]; then
  say "--- last lines of the llama-server log ---"
  tail -n 25 "$LOG_DIR/llama-server.log"
  fail "llama-server did not come up (see the log above)."
fi
say "llama-server is ready."
if [ ${#LORA_ARGS[@]} -gt 0 ]; then
  # belt and braces: set every brick to scale 0 explicitly, then show what the server reports
  OFF=$(curl -s "http://127.0.0.1:$PORT/lora-adapters" | tr '{' '\n' | sed -n 's/.*"id": *\([0-9][0-9]*\).*/{"id":\1,"scale":0}/p' | paste -sd, -)
  [ -n "$OFF" ] && curl -s -X POST "http://127.0.0.1:$PORT/lora-adapters" -H 'Content-Type: application/json' -d "[$OFF]" >/dev/null
  say "Bricks loaded, all off:"
  curl -s "http://127.0.0.1:$PORT/lora-adapters" | tr '{' '\n' | sed -n 's/.*"id": *\([0-9]*\),"path": *"\([^"]*\)","scale": *\([0-9.]*\).*/  id \1  scale \3  \2/p'
  echo
fi

# ---------- 6. page server and the simulator ----------
PAGE=""
FILE_PAGE=""
[ -f "$PODBAY/web/podbay_sim.html" ] && FILE_PAGE="file://$PODBAY/web/podbay_sim.html?llama=http://127.0.0.1:$PORT"
if [ -f "$LOCAL_SERVER" ]; then
  WS_ARGS=()
  HELP=$("$PY" "$LOCAL_SERVER" --help 2>&1 || true)
  case "$HELP" in *--port*) WS_ARGS+=(--port "$WEB_PORT") ;; esac
  case "$HELP" in *--llama-url*) WS_ARGS+=(--llama-url "http://127.0.0.1:$PORT") ;; esac
  say "Starting the page server $LOCAL_SERVER (log: $LOG_DIR/local_server.log) ..."
  PODBAY_LLAMA_URL="http://127.0.0.1:$PORT" PODBAY_WEB_PORT="$WEB_PORT" \
    "$PY" "$LOCAL_SERVER" ${WS_ARGS[@]+"${WS_ARGS[@]}"} > "$LOG_DIR/local_server.log" 2>&1 &
  WS_PID=$!
  PIDS="$PIDS $WS_PID"
  # Up means: our process is alive AND the one answering on the port says it is the PodBay page server. A port
  # that merely answers is not enough (another program may hold it while ours has already died).
  ws_ok=0
  for _ in $(seq 1 40); do
    if ! kill -0 "$WS_PID" 2>/dev/null; then break; fi
    if curl -s -m 1 "http://127.0.0.1:$WEB_PORT/health" 2>/dev/null | grep -q '"podbay-local"'; then ws_ok=1; break; fi
    sleep 0.25
  done
  if [ "$ws_ok" -eq 1 ] && kill -0 "$WS_PID" 2>/dev/null; then
    PAGE="http://127.0.0.1:$WEB_PORT/"
  else
    why="it did not answer on port $WEB_PORT within 10 seconds."
    if curl -s -m 1 -o /dev/null "http://127.0.0.1:$WEB_PORT/" 2>/dev/null; then
      why="another program answers on port $WEB_PORT. Pick another port: PODBAY_WEB_PORT=8766 \"$0\""
    elif ! kill -0 "$WS_PID" 2>/dev/null; then
      why="it stopped (see its log above)."
    fi
    say "--- last lines of the page server log ($LOG_DIR/local_server.log) ---"
    tail -n 15 "$LOG_DIR/local_server.log"
    say "---"
    fail "the simulator's page server did not come up: $why
  PodBay stops here (llama-server too). Fix the cause and start PodBay again."
  fi
elif [ -n "$FILE_PAGE" ]; then
  PAGE="$FILE_PAGE"
else
  say "No simulator page yet (podbay/web/podbay_sim.html is missing); plain chat still works."
fi

open_url() {
  [ -n "${PODBAY_NO_OPEN:-}" ] && return 0
  if command -v open >/dev/null 2>&1; then open "$1"; elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1; fi
}
[ -n "$PAGE" ] && open_url "$PAGE"

say ""
say "PodBay is running."
[ -n "$PAGE" ] && say "  Simulator:              $PAGE"
say "  Plain chat (llama-ui):  http://127.0.0.1:$PORT/"
[ ${#LORA_ARGS[@]} -gt 1 ] && say "  Brick switch:           drives adapter id ${PODBAY_BRICK_ID:-0} only; the other bricks stay at scale 0 (PODBAY_BRICK_ID picks another)"
say "  Bricks:                 the page's brick switch (sent with every request), or"
say "                          python3 $HERE/brick.py --url http://127.0.0.1:$PORT compare \"Open the pod bay door.\""
say "                          (list | on <name> | off set the server-wide scale that llama-ui uses)"
case "$FAMILY" in gemma-26b) say "  Prompt check (Gemma):   python3 $HERE/brick.py --url http://127.0.0.1:$PORT check-prompt" ;; esac
say "Press Ctrl-C to stop."

# Stay in the foreground until llama-server exits or Ctrl-C.
while kill -0 "$LS_PID" 2>/dev/null; do sleep 1; done
say "llama-server exited; last lines of its log:"
tail -n 15 "$LOG_DIR/llama-server.log"
