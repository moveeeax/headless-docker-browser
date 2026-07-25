#!/usr/bin/env bash
# Ввод в X-сервер напрямую: браузер не отличает эти события от настоящих.
# Работает в пиксельных координатах экрана.
set -euo pipefail

export DISPLAY=":${DISPLAY_NUM:-99}"
SHOTS="${SHOTS_DIR:-/screenshots}"

usage() {
    cat <<'EOF'
ctl shot [имя.png]        снимок всего экрана в /screenshots
ctl click X Y [кнопка]    переместить курсор и кликнуть (1 левая, 2 средняя, 3 правая)
ctl move X Y              только переместить курсор
ctl where                 текущие координаты курсора
ctl type "текст"          набрать текст с задержкой между символами
ctl key KEY               нажать клавишу: Return, Tab, ctrl+l, ctrl+shift+r
ctl scroll up|down [N]    прокрутить колесом N щелчков (по умолчанию 3)
ctl drag X1 Y1 X2 Y2      перетащить
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
    shot)
        out="${SHOTS}/${1:-shot-$(date +%Y%m%d-%H%M%S).png}"
        scrot -o "$out"
        echo "$out"
        ;;
    click)
        x="$1"; y="$2"; btn="${3:-1}"
        xdotool mousemove --sync "$x" "$y" click "$btn"
        ;;
    move)
        xdotool mousemove --sync "$1" "$2"
        ;;
    where)
        xdotool getmouselocation
        ;;
    type)
        xdotool type --delay "${TYPE_DELAY:-80}" -- "$1"
        ;;
    key)
        xdotool key -- "$1"
        ;;
    scroll)
        dir="$1"; n="${2:-3}"
        btn=4; [ "$dir" = "down" ] && btn=5
        for _ in $(seq 1 "$n"); do xdotool click "$btn"; sleep 0.05; done
        ;;
    drag)
        xdotool mousemove --sync "$1" "$2" mousedown 1
        sleep 0.1
        xdotool mousemove --sync "$3" "$4"
        sleep 0.1
        xdotool mouseup 1
        ;;
    *)
        usage
        exit 1
        ;;
esac
