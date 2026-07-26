#!/usr/bin/env bash
# Смоук-тест образа: поднимает контейнер и проверяет то, что ломается
# незаметно — доступность CDP, origin-проверку DevTools, адрес прослушивания,
# оба управляющих скрипта.
#
#   docker build -t headless-docker-browser:test .
#   tests/smoke.sh
#
# Проверки-помощники вызываются косвенно, через check.
# shellcheck disable=SC2329
set -uo pipefail

IMAGE="${IMAGE:-headless-docker-browser:test}"
FAILED=0

pass() { echo "ok   — $*"; }
fail() { echo "FAIL — $*" >&2; FAILED=1; }

check() {  # check ОПИСАНИЕ команда...
    local what="$1"; shift
    if "$@" > /dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}

# Вывод сначала складываем в строку: grep -q закрывает канал на первом
# совпадении, отправляя писателю SIGPIPE, а с pipefail это провал конвейера.
eq()        { [ "$1" = "$2" ]; }
not()       { ! "$@"; }
logs_have() { grep -q -- "$2" <<< "$(docker logs "$1" 2>&1)"; }
out_has()   { local pat="$1"; shift; grep -q -- "$pat" <<< "$("$@" 2>&1)"; }
out_lacks() { local pat="$1"; shift; ! grep -qi -- "$pat" <<< "$("$@" 2>&1)"; }

CONTAINERS=()
# shellcheck disable=SC2329  # вызывается через trap
cleanup() {
    local c
    for c in "${CONTAINERS[@]:-}"; do
        [ -n "$c" ] && docker rm -f "$c" > /dev/null 2>&1
    done
    return 0
}
trap cleanup EXIT

# Хук по умолчанию спит CLICK_DELAY секунд и кликает — тесту он только мешает.
start() {  # start ИМЯ ПОРТ [-e ...]
    local name="$1" port="$2"; shift 2
    CONTAINERS+=("$name")
    docker rm -f "$name" > /dev/null 2>&1
    docker run -d --name "$name" --shm-size=1g \
        --cap-drop=ALL --security-opt no-new-privileges:true \
        -e VNC_PASSWORD=smoke-test \
        -e URL=https://example.com \
        -e HOOK_FILE=/nonexistent \
        "$@" "$IMAGE" > /dev/null || return 1

    local _
    for _ in $(seq 1 90); do
        docker exec "$name" curl -fsS --max-time 2 \
            "http://127.0.0.1:${port}/json/version" > /dev/null 2>&1 && return 0
        if [ -z "$(docker ps --filter "name=^${name}$" --format '{{.ID}}')" ]; then
            echo "контейнер $name умер:" >&2
            docker logs "$name" 2>&1 | tail -20 >&2
            return 1
        fi
        sleep 1
    done
    echo "CDP на порту $port не ответил за 90 секунд" >&2
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
}

page_id() {  # page_id ИМЯ ПОРТ
    docker exec "$1" python3 -c "
import json, urllib.request
with urllib.request.urlopen('http://127.0.0.1:$2/json', timeout=5) as r:
    print(next(t['id'] for t in json.load(r) if t['type'] == 'page'))
"
}

# Рукопожатие DevTools от имени постороннего origin. 403 — проверка работает,
# 101 — любая открытая страница может забрать браузер себе.
handshake_code() {  # handshake_code ИМЯ ПОРТ ID
    docker exec "$1" curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H 'Origin: http://evil.example' \
        "http://127.0.0.1:$2/devtools/page/$3"
}

shot_ok() {
    docker exec smoke-default ctl shot smoke.png > /dev/null &&
        docker exec smoke-default test -s /screenshots/smoke.png
}

# fill раньше дописывал текст к тому, что уже было в поле, вместо замены —
# второй fill на то же поле удваивал значение.
fill_replaces() {
    docker exec smoke-default \
        cdp eval "document.body.innerHTML = '<input id=probe value=old>'; 1" > /dev/null &&
    docker exec smoke-default cdp fill "#probe" "new" > /dev/null &&
    eq "$(docker exec smoke-default cdp eval "document.querySelector('#probe').value")" '"new"'
}

# --- образ по умолчанию -----------------------------------------------------
echo "== образ по умолчанию =="
if ! start smoke-default 9222; then
    echo "FAIL — контейнер не поднялся" >&2
    exit 1
fi
pass "контейнер поднялся и CDP отвечает"

check "процесс не root" eq "$(docker exec smoke-default id -u)" 1000
check "CDP слушает только 127.0.0.1" \
    logs_have smoke-default "DevTools listening on ws://127.0.0.1:9222"
check "cdp ready дожидается страницы" \
    eq "$(docker exec smoke-default cdp ready 60)" "https://example.com/"
check "cdp text читает страницу" \
    out_has "Example Domain" docker exec smoke-default cdp text

code="$(handshake_code smoke-default 9222 "$(page_id smoke-default 9222)")"
if [ "$code" = "403" ]; then
    pass "DevTools отклоняет посторонний Origin (403)"
else
    fail "DevTools ответил $code вместо 403 — origin-проверка выключена"
fi

check "cdp goto file:// отклоняется" \
    not docker exec smoke-default cdp goto file:///etc/passwd
check "cdp goto https:// проходит" \
    docker exec smoke-default cdp goto https://example.com/
check "неизвестная команда cdp отвергается" \
    not docker exec smoke-default cdp такой-команды-нет
check "cdp click без селектора не падает трейсбеком" \
    out_lacks traceback docker exec smoke-default cdp click
check "cdp fill заменяет содержимое поля, а не дописывает к нему" \
    fill_replaces

check "ctl shot пишет снимок" shot_ok
check "ctl shot не выходит за пределы каталога" \
    not docker exec smoke-default ctl shot ../escape.png
check "ctl scroll отвергает мусорное направление" \
    not docker exec smoke-default ctl scroll вбок
check "ctl click без Y не падает unbound variable" \
    out_lacks "unbound variable" docker exec smoke-default ctl click 10

# --- нестандартный порт и снятая origin-проверка ----------------------------
echo
echo "== CDP_PORT=9333, CDP_ALLOW_ORIGINS='*' =="
if start smoke-alt 9333 -e CDP_PORT=9333 -e CDP_ALLOW_ORIGINS='*'; then
    pass "контейнер поднялся с CDP_PORT=9333"

    check "cdp учитывает CDP_PORT" \
        eq "$(docker exec smoke-alt cdp ready 60)" "https://example.com/"

    code="$(handshake_code smoke-alt 9333 "$(page_id smoke-alt 9333)")"
    if [ "$code" = "101" ]; then
        pass "CDP_ALLOW_ORIGINS возвращает прежнее поведение (101)"
    else
        fail "с CDP_ALLOW_ORIGINS='*' ждали 101, получили $code"
    fi

    check "entrypoint предупреждает о снятой проверке" \
        logs_have smoke-alt "origin-проверка DevTools ослаблена"
else
    fail "контейнер с CDP_PORT=9333 не поднялся"
fi

# --- хук не остаётся сиротой после падения Chromium -------------------------
# run_after_load уходит в фон и сама порождает дерево процессов (curl, cdp,
# сам хук). При рестарте Chromium цикл в entrypoint раньше убивал только эту
# обёртку — хук, если он ещё спал или работал, оставался жить осиротевшим и
# копился с каждым падением страницы. Долгий фиктивный хук (sleep 300)
# делает это дерево видимым и переживающим один цикл падение/рестарт.
echo
echo "== хук не остаётся сиротой после рестарта Chromium =="
if start smoke-hook 9222 -e HOOK_FILE=/nonexistent -e AFTER_LOAD='sleep 300' -e AFTER_LOAD_DELAY=0; then
    hook_up=0
    for _ in $(seq 1 30); do
        if docker exec smoke-hook pgrep -f 'sleep 300' > /dev/null 2>&1; then
            hook_up=1
            break
        fi
        sleep 1
    done
    if [ "$hook_up" = "1" ]; then
        pass "фиктивный хук (sleep 300) запустился"
        docker exec smoke-hook pkill -x chromium > /dev/null 2>&1 || true
        # entrypoint замечает падение, чистит Singleton-локи и перезапускает
        # Chromium через 2 секунды — даём вдвое больше и хуку время подняться.
        sleep 8
        left="$(docker exec smoke-hook pgrep -c -f 'sleep 300' 2>/dev/null || echo 0)"
        check "старый хук не остаётся висеть после рестарта Chromium (осталось: $left)" \
            eq "$left" 1
    else
        fail "фиктивный хук не запустился за 30с"
    fi
else
    fail "контейнер с фиктивным хуком не поднялся"
fi

echo
if [ "$FAILED" = "0" ]; then
    echo "все проверки прошли"
else
    echo "есть провалившиеся проверки" >&2
fi
exit "$FAILED"
