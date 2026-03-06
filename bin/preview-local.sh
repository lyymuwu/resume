#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-4173}"
HOST="${HOST:-127.0.0.1}"
URL="http://${HOST}:${PORT}/resume/cv/"
LOG_FILE="/tmp/resume_preview_${PORT}.log"
PID_FILE="/tmp/resume_preview_${PORT}.pid"
BUILD_LOG_FILE="/tmp/resume_jekyll_build.log"
HEALTH_HTML="/tmp/resume_preview_health.html"

export PATH="${HOME}/.local/bin:/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

has_pattern() {
  local pattern="${1:-}"
  local file="${2:-}"
  if [[ -z "$pattern" || -z "$file" || ! -f "$file" ]]; then
    return 1
  fi

  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

is_running() {
  local pid
  pid="${1:-}"
  if [[ -z "$pid" ]]; then
    return 1
  fi
  ps -p "$pid" >/dev/null 2>&1
}

pid_cmdline() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    echo ""
    return 0
  fi
  ps -p "$pid" -o command= 2>/dev/null || true
}

is_our_server_pid() {
  local pid="${1:-}"
  local cmdline=""
  if ! is_running "$pid"; then
    return 1
  fi
  cmdline="$(pid_cmdline "$pid")"
  [[ "$cmdline" == *"python3 -m http.server"* && "$cmdline" == *"${PORT}"* ]]
}

find_listener_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | head -n1 || true
    return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    # Fallback: detect listener existence; PID unavailable with netstat on some systems.
    if netstat -an 2>/dev/null | grep -Eiq "[\\.:]${PORT}[[:space:]].*LISTEN"; then
      echo "unknown"
    fi
    return 0
  fi
  echo ""
}

normalize_pid_file() {
  local pid=""
  local listener_pid=""
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ! is_our_server_pid "$pid"; then
      rm -f "$PID_FILE"
    fi
  fi

  listener_pid="$(find_listener_pid)"
  if [[ -n "$listener_pid" && "$listener_pid" != "unknown" ]]; then
    echo "$listener_pid" > "$PID_FILE"
  fi
}

stop_server() {
  local pid=""
  local listener_pid=""

  normalize_pid_file
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi

  if is_our_server_pid "$pid"; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 0.8
    if is_running "$pid"; then
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  fi

  listener_pid="$(find_listener_pid)"
  if [[ -n "$listener_pid" ]]; then
    kill -9 "$listener_pid" >/dev/null 2>&1 || true
  fi

  rm -f "$PID_FILE"
}

build_site() {
  cd "$ROOT_DIR"
  bundle exec jekyll build >"$BUILD_LOG_FILE" 2>&1
}

start_server() {
  cd "$ROOT_DIR/_site"
  [[ -e resume ]] || ln -s . resume

  nohup python3 -m http.server "$PORT" --bind "$HOST" >"$LOG_FILE" 2>&1 < /dev/null &
  sleep 0.2
  local pid="$!"
  if is_running "$pid"; then
    echo "$pid" > "$PID_FILE"
  fi
}

wait_healthy() {
  local i code
  for i in $(seq 1 40); do
    code="$(curl -s -o "$HEALTH_HTML" -w '%{http_code}' "$URL" || true)"
    if [[ "$code" == "200" ]] && has_pattern "post-title|Honors and Awards|Projects|Education" "$HEALTH_HTML"; then
      return 0
    fi
    sleep 0.4
  done
  return 1
}

print_status() {
  local pid=""
  local listener_pid=""
  local cmdline=""
  local code=""

  normalize_pid_file
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi
  listener_pid="$(find_listener_pid)"
  cmdline="$(pid_cmdline "$pid" || true)"

  code="$(curl -s -o "$HEALTH_HTML" -w '%{http_code}' "$URL" || true)"

  echo "ROOT=${ROOT_DIR}"
  echo "HOST=${HOST}"
  echo "PORT=${PORT}"
  echo "URL=${URL}"
  echo "PID_FILE=${PID_FILE}"
  echo "LOG_FILE=${LOG_FILE}"
  echo "BUILD_LOG_FILE=${BUILD_LOG_FILE}"
  echo "PID=${pid:-none}"
  echo "LISTENER_PID=${listener_pid:-none}"
  echo "CMD=${cmdline:-none}"
  echo "HTTP_STATUS=${code:-000}"

  if [[ "$code" == "200" && -n "$listener_pid" ]] && has_pattern "post-title|Honors and Awards|Projects|Education" "$HEALTH_HTML"; then
    if [[ -n "$listener_pid" && "$listener_pid" != "unknown" ]]; then
      echo "$listener_pid" > "$PID_FILE"
    fi
    echo "STATUS=healthy"
    return 0
  fi

  echo "STATUS=down"
  return 1
}

open_browser() {
  if command -v open >/dev/null 2>&1; then
    open "$URL" >/dev/null 2>&1 || true
  fi
}

cmd="${1:-start}"

case "$cmd" in
  start)
    stop_server
    build_site || {
      echo "Build failed. Check: $BUILD_LOG_FILE" >&2
      tail -n 120 "$BUILD_LOG_FILE" >&2 || true
      exit 1
    }
    start_server
    if wait_healthy; then
      echo "Preview is ready: $URL"
      open_browser
      exit 0
    else
      echo "Preview failed to become healthy. Check: $LOG_FILE" >&2
      tail -n 80 "$LOG_FILE" >&2 || true
      exit 1
    fi
    ;;
  stop)
    stop_server
    echo "Preview server stopped (port $PORT)."
    ;;
  restart)
    stop_server
    build_site || {
      echo "Build failed. Check: $BUILD_LOG_FILE" >&2
      tail -n 120 "$BUILD_LOG_FILE" >&2 || true
      exit 1
    }
    start_server
    if wait_healthy; then
      echo "Preview restarted: $URL"
      open_browser
      exit 0
    else
      echo "Preview failed to become healthy. Check: $LOG_FILE" >&2
      tail -n 80 "$LOG_FILE" >&2 || true
      exit 1
    fi
    ;;
  up)
    if print_status >/dev/null 2>&1; then
      echo "Preview already healthy: $URL"
      open_browser
      exit 0
    fi
    stop_server
    if [[ -d "$ROOT_DIR/_site" ]]; then
      start_server
      if wait_healthy; then
        echo "Preview recovered without rebuild: $URL"
        open_browser
        exit 0
      fi
      stop_server
    fi
    build_site || {
      echo "Build failed. Check: $BUILD_LOG_FILE" >&2
      tail -n 120 "$BUILD_LOG_FILE" >&2 || true
      exit 1
    }
    start_server
    if wait_healthy; then
      echo "Preview recovered with rebuild: $URL"
      open_browser
      exit 0
    fi
    echo "Preview failed to recover. Check: $LOG_FILE" >&2
    tail -n 120 "$LOG_FILE" >&2 || true
    exit 1
    ;;
  status)
    print_status
    ;;
  logs)
    tail -n 120 "$LOG_FILE"
    ;;
  *)
    echo "Usage: bin/preview-local.sh {start|stop|restart|up|status|logs}" >&2
    exit 2
    ;;
esac
has_pattern() {
  local pattern="${1:-}"
  local file="${2:-}"
  if [[ -z "$pattern" || -z "$file" || ! -f "$file" ]]; then
    return 1
  fi

  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}
