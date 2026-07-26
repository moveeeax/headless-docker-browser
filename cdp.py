#!/usr/bin/env python3
"""Управление уже запущенным Chromium через CDP.

Адресация по DOM, а не по пикселям: селектор переживает изменение вёрстки,
координаты нет. Клик отправляется как Input.dispatchMouseEvent, то есть
доверенным событием, а не element.click().
"""
import base64
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import websocket  # пакет python3-websocket (websocket-client)


def _port():
    raw = os.environ.get("CDP_PORT", "9222")
    try:
        return int(raw)
    except ValueError:
        sys.exit(f"CDP_PORT должен быть числом, а не {raw!r}")


# Порт берём из окружения: entrypoint запускает Chromium с тем же CDP_PORT,
# и зашитая константа ломала всё, кроме значения по умолчанию.
PORT = _port()
TIMEOUT = 20

COMMANDS = ("goto", "click", "fill", "eval", "text", "wait", "ready", "shot")

# Page.navigate ходит куда угодно: file:// прочитает файловую систему
# контейнера, javascript: выполнится в контексте открытой страницы. Команды
# cdp вызываются в том числе из хуков, поэтому схему проверяем.
SAFE_SCHEMES = ("http", "https", "about")


def check_url(url):
    if os.environ.get("CDP_ALLOW_ANY_SCHEME") == "1":
        return url
    scheme = urllib.parse.urlsplit(url).scheme.lower()
    if not scheme:
        sys.exit(f"URL без схемы: {url}")
    if scheme not in SAFE_SCHEMES:
        sys.exit(
            f"схема {scheme}: не разрешена, только {'/'.join(SAFE_SCHEMES)} "
            "(снять проверку: CDP_ALLOW_ANY_SCHEME=1)"
        )
    return url


def arg(args, i, what):
    if len(args) <= i:
        sys.exit(f"не хватает аргумента: {what}")
    return args[i]


def page_socket():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=5) as r:
        targets = json.load(r)
    pages = [t for t in targets if t.get("type") == "page"]
    if not pages:
        sys.exit("нет открытых вкладок")
    return pages[0]["webSocketDebuggerUrl"]


class CDP:
    def __init__(self):
        # Без suppress_origin клиент шлёт Origin: http://127.0.0.1:9222,
        # и Chromium отвечает 403 Forbidden на рукопожатие.
        self.ws = websocket.create_connection(
            page_socket(), timeout=TIMEOUT, suppress_origin=True
        )
        self.n = 0

    def send(self, method, **params):
        self.n += 1
        self.ws.send(json.dumps({"id": self.n, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.n:
                if "error" in msg:
                    sys.exit(f"CDP: {msg['error'].get('message')}")
                return msg.get("result", {})

    def js(self, expression):
        res = self.send(
            "Runtime.evaluate",
            expression=expression,
            returnByValue=True,
            awaitPromise=True,
        )
        if res.get("exceptionDetails"):
            sys.exit(res["exceptionDetails"].get("text", "ошибка в JS"))
        return res.get("result", {}).get("value")

    def box(self, selector):
        """Центр элемента в координатах вьюпорта, после прокрутки к нему."""
        raw = self.js(
            """
            (() => {
              const el = document.querySelector(%s);
              if (!el) return null;
              el.scrollIntoView({block: 'center', inline: 'center'});
              const r = el.getBoundingClientRect();
              if (r.width === 0 && r.height === 0) return null;
              return {x: r.left + r.width / 2, y: r.top + r.height / 2};
            })()
            """
            % json.dumps(selector)
        )
        if not raw:
            sys.exit(f"элемент не найден или невидим: {selector}")
        return raw["x"], raw["y"]

    def click_at(self, x, y):
        for kind in ("mousePressed", "mouseReleased"):
            self.send(
                "Input.dispatchMouseEvent",
                type=kind,
                x=x,
                y=y,
                button="left",
                buttons=1,
                clickCount=1,
            )

    def clear_field(self):
        """Ctrl+A, затем Backspace: стираем то, что уже было в поле.

        Без этого fill дописывал текст к существующему значению вместо
        замены — расхождение с тем, что обычно ждут от "fill" в любом
        другом инструменте автоматизации, и оно било по идемпотентности:
        повторный fill на непустое поле удваивал текст.
        """
        ctrl = 2  # EventModifiers: Alt=1, Ctrl=2, Meta=4, Shift=8
        for kind in ("keyDown", "keyUp"):
            self.send(
                "Input.dispatchKeyEvent",
                type=kind,
                modifiers=ctrl,
                code="KeyA",
                key="a",
                windowsVirtualKeyCode=65,
            )
        for kind in ("keyDown", "keyUp"):
            self.send(
                "Input.dispatchKeyEvent",
                type=kind,
                code="Backspace",
                key="Backspace",
                windowsVirtualKeyCode=8,
            )

    def close(self):
        self.ws.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("команды: goto URL | click SELECTOR | fill SELECTOR ТЕКСТ | "
              "eval JS | text | shot ФАЙЛ | wait SELECTOR | ready [СЕК]")
        sys.exit(1)

    cmd, args = sys.argv[1], sys.argv[2:]
    # Всё, что можно проверить без браузера, проверяем до подключения:
    # иначе `cdp опечатка` сначала падает на «нет открытых вкладок».
    if cmd not in COMMANDS:
        sys.exit(f"неизвестная команда: {cmd}")
    if cmd == "goto":
        check_url(arg(args, 0, "goto URL"))

    c = CDP()

    if cmd == "goto":
        c.send("Page.navigate", url=args[0])

    elif cmd == "click":
        selector = arg(args, 0, "click SELECTOR")
        x, y = c.box(selector)
        c.click_at(x, y)
        print(f"клик по {selector} в ({x:.0f}, {y:.0f})")

    elif cmd == "fill":
        selector = arg(args, 0, "fill SELECTOR ТЕКСТ")
        value = arg(args, 1, "fill SELECTOR ТЕКСТ")
        x, y = c.box(selector)
        c.click_at(x, y)
        c.clear_field()
        for ch in value:
            c.send("Input.dispatchKeyEvent", type="char", text=ch)

    elif cmd == "eval":
        print(json.dumps(c.js(arg(args, 0, "eval JS")), ensure_ascii=False))

    elif cmd == "text":
        print(c.js("document.body.innerText"))

    elif cmd == "wait":
        # ждём появления элемента, до 15 секунд
        arg(args, 0, "wait SELECTOR")
        ok = c.js(
            """
            (async () => {
              const sel = %s;
              for (let i = 0; i < 150; i++) {
                if (document.querySelector(sel)) return true;
                await new Promise(r => setTimeout(r, 100));
              }
              return false;
            })()
            """
            % json.dumps(args[0])
        )
        if not ok:
            sys.exit(f"не дождался: {args[0]}")

    elif cmd == "ready":
        # ждём, пока вкладка уйдёт с about:blank и добьёт readyState до complete
        try:
            timeout = float(args[0]) if args else 60.0
        except ValueError:
            sys.exit(f"ready ждёт число секунд, а не {args[0]!r}")
        deadline = time.time() + timeout
        while time.time() < deadline:
            state = c.js("document.readyState")
            url = c.js("location.href")
            if state == "complete" and url and not url.startswith("about:"):
                print(url)
                break
            time.sleep(0.3)
        else:
            sys.exit("страница не догрузилась за отведённое время")

    elif cmd == "shot":
        data = c.send("Page.captureScreenshot", format="png")["data"]
        out = args[0] if args else "/screenshots/cdp.png"
        with open(out, "wb") as f:
            f.write(base64.b64decode(data))
        print(out)

    c.close()


if __name__ == "__main__":
    main()
