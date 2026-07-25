#!/usr/bin/env bash
# Ввод в X-сервер напрямую: браузер не отличает эти события от настоящих.
# Работает в пиксельных координатах экрана.
set -euo pipefail

export DISPLAY=":${DISPLAY_NUM:-99}"
SHOTS="${SHOTS_DIR:-/screenshots}"

die() { echo "ctl: $*" >&2; exit 1; }

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
        # Имя файла, а не путь: хук не должен уметь писать за пределы SHOTS.
        name="${1:-shot-$(date +%Y%m%d-%H%M%S).png}"
        case "$name" in
            ""|.|..|*/*) die "имя снимка не должно быть путём: '$name'" ;;
        esac
        out="${SHOTS}/${name}"
        scrot -o "$out"
        echo "$out"
        ;;
    click)
        [ "$#" -ge 2 ] || die "нужно: ctl click X Y [кнопка]"
        xdotool mousemove --sync "$1" "$2" click "${3:-1}"
        ;;
    move)
        [ "$#" -ge 2 ] || die "нужно: ctl move X Y"
        xdotool mousemove --sync "$1" "$2"
        ;;
    where)
        xdotool getmouselocation
        ;;
    type)
        [ "$#" -ge 1 ] || die "нужно: ctl type ТЕКСТ"
        xdotool type --delay "${TYPE_DELAY:-80}" -- "$1"
        ;;
    key)
        [ "$#" -ge 1 ] || die "нужно: ctl key KEY"
        xdotool key -- "$1"
        ;;
    scroll)
        [ "$#" -ge 1 ] || die "нужно: ctl scroll up|down [N]"
        # Раньше любое непонятное направление молча прокручивало вверх.
        case "$1" in
            up)   btn=4 ;;
            down) btn=5 ;;
            *)    die "направление должно быть up или down, а не '$1'" ;;
        esac
        n="${2:-3}"
        case "$n" in
            ""|*[!0-9]*) die "число щелчков должно быть целым: '$n'" ;;
        esac
        for _ in $(seq 1 "$n"); do xdotool click "$btn"; sleep 0.05; done
        ;;
    drag)
        [ "$#" -ge 4 ] || die "нужно: ctl drag X1 Y1 X2 Y2"
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
