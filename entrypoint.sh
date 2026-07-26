#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

XVFB_PID=""
WM_PID=""
VNC_PID=""
WEB_PID=""
CHROME_PID=""
HOOK_PID=""
RUNNING=1

cleanup() {
    RUNNING=0
    log "shutting down"
    # HOOK_PID is a whole process group (see setsid below): kill it by
    # its negative PID or its children survive the wrapper.
    [ -n "$HOOK_PID" ] && kill -- -"$HOOK_PID" 2>/dev/null || true
    for pid in "$CHROME_PID" "$WEB_PID" "$VNC_PID" "$WM_PID" "$XVFB_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# --- виртуальный дисплей ---------------------------------------------------
Xvfb "$DISPLAY" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" -nolisten tcp &
XVFB_PID=$!

for _ in $(seq 1 50); do
    [ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
    sleep 0.2
done
if [ ! -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
    log "Xvfb не поднялся за 10 секунд"
    exit 1
fi
log "Xvfb на ${DISPLAY}, ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}"

# --- звук -------------------------------------------------------------------
# Пустой sink в PulseAudio: устройства нет, но часы настоящие, и видео
# играет в реальном времени. ALSA с type null часов не имеет и разгоняет
# воспроизведение до скорости процессора.
if [ "${AUDIO}" = "pulse" ]; then
    pulseaudio -D --exit-idle-time=-1 --disallow-exit > /tmp/pulse.log 2>&1 || \
        log "pulseaudio не стартовал, звук уйдёт в ALSA"
    sleep 1
    pactl load-module module-null-sink sink_name=dummy > /dev/null 2>&1 || true
    pactl set-default-sink dummy > /dev/null 2>&1 || true
    log "аудио: null-sink в pulseaudio"
fi

# --- оконный менеджер -------------------------------------------------------
# Без WM окно Chromium не получает фокус, а --start-fullscreen и --kiosk
# не работают вовсе: и то и другое делает менеджер, а не браузер.
if [ "${WINDOW_MANAGER}" = "1" ]; then
    fluxbox > /tmp/fluxbox.log 2>&1 &
    WM_PID=$!
    sleep 1
    log "fluxbox запущен"
fi

# --- VNC -------------------------------------------------------------------
vnc_args=(-display "$DISPLAY" -rfbport "$VNC_PORT" -forever -shared -quiet -bg)

if [ -n "${VNC_PASSWORD:-}" ]; then
    x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vncpass > /dev/null 2>&1
    vnc_args+=(-rfbauth /tmp/vncpass)
else
    log "ВНИМАНИЕ: VNC_PASSWORD пуст, сервер поднят без пароля. Не публикуйте порты наружу."
    vnc_args+=(-nopw)
fi

[ "${VNC_VIEW_ONLY}" = "1" ] && vnc_args+=(-viewonly)

x11vnc "${vnc_args[@]}"
sleep 1
VNC_PID="$(pgrep -n -u "$(id -u)" x11vnc || true)"
log "x11vnc на порту ${VNC_PORT}"

# --- noVNC -----------------------------------------------------------------
websockify --web=/usr/share/novnc "0.0.0.0:${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" \
    > /tmp/websockify.log 2>&1 &
WEB_PID=$!
log "noVNC на http://<host>:${NOVNC_PORT}/vnc.html"

# --- Chromium --------------------------------------------------------------
# Современный Chromium (проверено на 150.0.7871.181) игнорирует
# --remote-debugging-address и в любом случае слушает 127.0.0.1. Флаг оставлен
# для старых сборок, но обещать доступ к CDP с хоста мы больше не можем.
case "${CDP_BIND}" in
    127.*|localhost|::1|"") ;;
    *) log "ВНИМАНИЕ: CDP_BIND=${CDP_BIND} игнорируется современным Chromium, CDP останется на 127.0.0.1" ;;
esac

chrome_flags=(
    --user-data-dir="${PROFILE_DIR}"
    --remote-debugging-port="${CDP_PORT}"
    --remote-debugging-address="${CDP_BIND}"
    --window-position="0,0"
    --window-size="${SCREEN_WIDTH},${SCREEN_HEIGHT}"
    --no-first-run
    --no-default-browser-check
    --disable-features="Translate,InfobarsUI"
    --disable-session-crashed-bubble
    --hide-crash-restore-bubble
    --password-store=basic
    --disable-background-networking
    --disable-sync
    --disable-component-update
    --disable-breakpad
    --no-service-autorun
)

[ "${DISABLE_GPU}" = "1" ] && chrome_flags+=(--disable-gpu)
[ "${MUTE_AUDIO}" = "1" ] && chrome_flags+=(--mute-audio)

# Origin-проверка DevTools — единственное, что мешает произвольной странице,
# открытой в этом же браузере, постучаться в ws://127.0.0.1:${CDP_PORT} и
# получить полный контроль: куки всего профиля, ввод, чтение локальных файлов
# через file://. cdp(1) ходит без заголовка Origin (suppress_origin), так что
# ослаблять проверку ему не нужно; отсюда пустое значение по умолчанию.
if [ -n "${CDP_ALLOW_ORIGINS:-}" ]; then
    log "ВНИМАНИЕ: CDP_ALLOW_ORIGINS=${CDP_ALLOW_ORIGINS}, origin-проверка DevTools ослаблена"
    chrome_flags+=(--remote-allow-origins="${CDP_ALLOW_ORIGINS}")
fi

[ "${NO_SANDBOX}" = "1" ] && chrome_flags+=(--no-sandbox)
if [ "${KIOSK}" = "1" ]; then
    chrome_flags+=(--kiosk)
else
    chrome_flags+=(--start-fullscreen)
fi

if [ -n "${EXTRA_CHROME_FLAGS}" ]; then
    # shellcheck disable=SC2206
    extra=(${EXTRA_CHROME_FLAGS})
    chrome_flags+=("${extra[@]}")
fi

# После нечистого выключения в профиле остаётся лок, иначе Chromium не стартует.
# Чистим все три файла и на старте, и перед каждым перезапуском: одного
# SingletonLock мало, повисший Socket или Cookie точно так же держат профиль.
clear_singleton_locks() {
    rm -f "${PROFILE_DIR}/SingletonLock" "${PROFILE_DIR}/SingletonSocket" \
          "${PROFILE_DIR}/SingletonCookie" 2>/dev/null || true
}
clear_singleton_locks

# --- хук после загрузки страницы -------------------------------------------
run_after_load() {
    local deadline=$((SECONDS + READY_TIMEOUT))

    until curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" > /dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            log "хук: CDP не отвечает, пропускаю"
            return 1
        fi
        sleep 0.5
    done

    if ! cdp ready "$READY_TIMEOUT"; then
        log "хук: страница не догрузилась, пропускаю"
        return 1
    fi

    [ "${AFTER_LOAD_DELAY}" != "0" ] && sleep "${AFTER_LOAD_DELAY}"

    if [ -f "${HOOK_FILE}" ]; then
        log "хук: выполняю ${HOOK_FILE}"
        bash "${HOOK_FILE}" || log "хук завершился с ошибкой (код $?)"
    elif [ -n "${AFTER_LOAD}" ]; then
        log "хук: выполняю AFTER_LOAD"
        bash -c "${AFTER_LOAD}" || log "хук завершился с ошибкой (код $?)"
    fi
}
export -f log run_after_load

while [ "$RUNNING" = "1" ]; do
    log "запускаю Chromium: ${URL}"
    chromium "${chrome_flags[@]}" "${URL}" &
    CHROME_PID=$!

    # run_after_load порождает curl, cdp и в итоге сам хук (сон, клик,
    # снимок) — процессы, которые запросто переживают саму обёртку.
    # setsid делает её лидером новой сессии/группы, так что "kill" по
    # отрицательному PID ниже убивает всё дерево разом; раньше
    # "kill $HOOK_PID" убивал только обёртку, а хук, всё ещё спящий или
    # работающий, осиротевшим уходил под tini и копился с каждым падением
    # или рестартом Chromium.
    setsid bash -c run_after_load &
    HOOK_PID=$!

    wait "$CHROME_PID" || true
    CHROME_PID=""
    kill -- -"$HOOK_PID" 2>/dev/null || true
    HOOK_PID=""

    [ "$RUNNING" = "1" ] || break
    if [ "${RESTART_ON_EXIT}" != "1" ]; then
        log "Chromium завершился, RESTART_ON_EXIT=0, выхожу"
        cleanup
    fi
    log "Chromium упал или был закрыт, перезапуск через 2 секунды"
    clear_singleton_locks
    sleep 2
done
