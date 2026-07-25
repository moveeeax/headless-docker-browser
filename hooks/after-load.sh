#!/usr/bin/env bash
# Зашит в образ на этапе сборки: /hooks/after-load.sh
# Запускается entrypoint'ом в фоне сразу после старта Chromium.
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] хук: $*"; }

DELAY="${CLICK_DELAY:-60}"
XY="${CLICK_XY:-684 500}"

log "жду ${DELAY} с"
sleep "$DELAY"

log "клик по ${XY}"
# shellcheck disable=SC2086
ctl click $XY

# Снимок сразу после клика остаётся внутри контейнера,
# забрать: docker cp <контейнер>:/screenshots/after-click.png .
ctl shot after-click.png > /dev/null
log "готово"
