#!/usr/bin/env bash
# Keep the host page cache small while the 184 GiB of shards load.
#
# The GB10 driver does not reclaim page cache by itself: once Cached has grown past ~40 GiB the
# allocation after the load fails with NV_ERR_NO_MEMORY (NVIDIA Developer Forums 381429), which is
# why tonyd2wild's recipe runs a cache_flusher alongside the boot.
#
# Dropping caches needs root. `sudo -n` is the fast path, but a node without a passwordless sudo
# rule for it writes nothing and fails silently — the boot then dies 15 minutes in with no clue.
# So fall back to a privileged container, which writes the host's /proc/sys/vm/drop_caches just as
# well (/proc/meminfo inside a container is the host's too). Needs docker access, which every node
# running this recipe has by definition.
#
#   cache-flusher.sh once             one sync + drop_caches now
#   cache-flusher.sh watch [SECS]     keep Cached < THRESHOLD_GIB for SECS (default 1500, backgrounded)
#   cache-flusher.sh stop             stop a running watcher
#   cache-flusher.sh status           which backend is available, and whether a watcher is up
set -uo pipefail

THRESHOLD_GIB="${CACHE_FLUSH_THRESHOLD_GIB:-40}"
IMAGE="${CACHE_FLUSH_IMAGE:-alpine:3.20}"
NAME=glm53-cache-flusher
LOG="$HOME/glm53-cluster/logs/cache-flusher.log"

have_sudo() { sudo -n true 2>/dev/null; }
have_docker() { docker info >/dev/null 2>&1; }

log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; echo "[$(date -Is)] $*" | tee -a "$LOG"; }

flush_once() {
  if have_sudo; then
    sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' && return 0
  fi
  if have_docker; then
    docker run --rm --privileged "$IMAGE" sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' && return 0
  fi
  return 1
}

case "${1:-status}" in
  once)
    if flush_once; then log "flushed via $(have_sudo && echo sudo || echo container); $(free -g | sed -n 2p)"
    else log "FAILED: neither passwordless sudo nor docker can drop caches"; exit 1; fi
    ;;

  watch)
    SECS="${2:-1500}"
    if have_sudo; then
      # Host-side loop; same shape as the recipe's original inline flusher.
      nohup bash -c "end=\$((SECONDS+$SECS)); while [ \$SECONDS -lt \$end ]; do \
        c=\$(awk '/^Cached:/{print int(\$2/1048576)}' /proc/meminfo); \
        [ \"\${c:-0}\" -gt $THRESHOLD_GIB ] && { sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; }; \
        sleep 5; done" >>"$LOG" 2>&1 &
      log "watching ${SECS}s via sudo (threshold ${THRESHOLD_GIB} GiB)"
    elif have_docker; then
      docker rm -f "$NAME" >/dev/null 2>&1
      docker run -d --rm --privileged --name "$NAME" "$IMAGE" sh -c "
        end=\$((\$(cut -d. -f1 /proc/uptime) + $SECS))
        while [ \$(cut -d. -f1 /proc/uptime) -lt \$end ]; do
          c=\$(awk '/^Cached:/{print int(\$2/1048576)}' /proc/meminfo)
          if [ \"\${c:-0}\" -gt $THRESHOLD_GIB ]; then sync; echo 3 > /proc/sys/vm/drop_caches; fi
          sleep 5
        done" >/dev/null
      log "watching ${SECS}s via container $NAME (threshold ${THRESHOLD_GIB} GiB) — no passwordless sudo on this node"
    else
      log "FAILED: neither passwordless sudo nor docker can drop caches — boot may hit NV_ERR_NO_MEMORY"
      exit 1
    fi
    ;;

  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 && log "container watcher stopped"
    pkill -f 'drop_caches' >/dev/null 2>&1 && log "host watcher stopped"
    exit 0
    ;;

  status)
    echo "$(hostname): sudo=$(have_sudo && echo yes || echo no) docker=$(have_docker && echo yes || echo no)"
    docker ps --format '{{.Names}} {{.Status}}' --filter "name=$NAME" 2>/dev/null | grep . || echo "no container watcher"
    free -g | sed -n 2p
    ;;

  *) echo "usage: cache-flusher.sh [once|watch [secs]|stop|status]" >&2; exit 2 ;;
esac
