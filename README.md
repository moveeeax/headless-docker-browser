# headless-docker-browser

A long-running Chromium in a Docker container, with a real X display behind it — watchable over VNC or a browser, drivable from the shell by pixel and from the DOM over CDP.

Not a screenshot tool and not Puppeteer. It is a browser that stays open: it keeps a persistent profile, survives its own crashes, plays audio in real time, and lets you attach to the session at any moment and take over with a mouse.

## Why it exists

Headless automation breaks on the pages that matter most: the ones that check for a window manager, want a logged-in profile, play media, or notice that `element.click()` is not a trusted event. This image runs the browser the way a desktop runs it — `Xvfb` for the display, `fluxbox` so fullscreen and focus actually work, PulseAudio with a null sink so video plays at wall-clock speed instead of CPU speed — and exposes three ways in:

| Interface | Port | What it is for |
| --- | --- | --- |
| noVNC | `6080` | Watch and click from any browser: `http://host:6080/vnc.html` |
| VNC | `5900` | Same session from a native VNC client |
| CDP | `9222`, container-local | Chrome DevTools Protocol, for scripted control — reachable from inside the container only, see [Security notes](#security-notes) |

## Quick start

```bash
git clone https://github.com/moveeeax/headless-docker-browser.git
cd headless-docker-browser

# Set a VNC password — the compose file requires it, deliberately.
echo 'VNC_PASSWORD=pick-your-own' > .env

docker compose up --build -d
```

Open <http://127.0.0.1:6080/vnc.html> and you are looking at a live Chromium on `https://google.com/`. Both published ports are bound to `127.0.0.1` in `docker-compose.yml`; publishing them on `0.0.0.0` publishes a remote-controllable browser, so do that only behind something that authenticates. CDP is deliberately not published at all — drive it with `docker compose exec`.

Point it somewhere else:

```bash
docker compose run --rm -e URL=https://example.com browser
```

## Driving it

Two control surfaces, both installed inside the image.

### `ctl` — synthetic input into X

Events go into the X server, so the browser cannot tell them apart from a human at a keyboard. Addressing is in screen pixels.

```bash
docker compose exec browser ctl click 684 500      # move and click (1 left, 2 middle, 3 right)
docker compose exec browser ctl type "hello"       # type with a per-character delay
docker compose exec browser ctl key ctrl+l         # Return, Tab, ctrl+l, ctrl+shift+r
docker compose exec browser ctl scroll down 5      # scroll wheel, N notches
docker compose exec browser ctl drag 100 200 400 600
docker compose exec browser ctl shot page.png      # full screen into /screenshots
docker compose exec browser ctl where              # current cursor position
```

### `cdp` — control by DOM

A small CDP client with no Node.js in the image. Selectors survive a layout change; pixel coordinates do not. Clicks are dispatched as `Input.dispatchMouseEvent`, i.e. as trusted events rather than `element.click()`.

```bash
docker compose exec browser cdp goto https://example.com
docker compose exec browser cdp wait "#login"          # poll for an element, up to 15s
docker compose exec browser cdp click "#login"         # scrolls into view, then clicks its centre
docker compose exec browser cdp fill "input[name=q]" "search text"
docker compose exec browser cdp eval "document.title"
docker compose exec browser cdp text                   # document.body.innerText
docker compose exec browser cdp shot /screenshots/x.png
docker compose exec browser cdp ready 60               # block until the page is actually loaded
```

`cdp ready` is the one worth knowing: it waits until the tab has left `about:blank` **and** `document.readyState` is `complete`, which is what "the page is up" usually means in practice.

## The after-load hook

The entrypoint runs a hook in the background once the page has finished loading — useful for dismissing a consent dialog, clicking play, or signing in. It waits for CDP to answer, waits for `cdp ready`, sleeps `AFTER_LOAD_DELAY`, then runs whichever of these exists:

1. `HOOK_FILE` (default `/hooks/after-load.sh`) — mount your own over it;
2. otherwise the `AFTER_LOAD` environment variable, as a `bash -c` string.

The bundled hook waits `CLICK_DELAY` seconds, clicks `CLICK_XY`, and saves `/screenshots/after-click.png`. Replace it:

```yaml
volumes:
  - ./hooks/after-load.sh:/hooks/after-load.sh:ro
```

The hook runs detached, so a hook that hangs never blocks the supervisor loop watching the browser.

## Staying up

- `tini` as PID 1 (with `-s`, so it reaps even when it is not) — Chromium spawns a lot of children and orphans some of them.
- The entrypoint loop restarts Chromium when it dies (`RESTART_ON_EXIT=1`), clearing the `SingletonLock` an unclean shutdown leaves in the profile.
- `HEALTHCHECK` polls `/json/version` on the CDP port, so Docker's idea of healthy is "the browser answers", not "the process exists".
- `shm_size: 2gb` — the default 64 MB makes Chromium's renderers die under any real page.
- The profile lives on a named volume, so cookies and logins survive `docker compose down`.

## Configuration

Every knob is an environment variable with a default baked into the `Dockerfile`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `URL` | `https://example.com` | Page opened at start |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` / `SCREEN_DEPTH` | `1920` / `1080` / `24` | Xvfb geometry |
| `DISPLAY_NUM` | `99` | X display number |
| `VNC_PORT` / `NOVNC_PORT` / `CDP_PORT` | `5900` / `6080` / `9222` | Listening ports |
| `VNC_PASSWORD` | *(empty)* | Empty means **no password at all**; the entrypoint warns |
| `VNC_VIEW_ONLY` | `0` | `1` makes VNC watch-only |
| `CDP_BIND` | `127.0.0.1` | Passed as `--remote-debugging-address`. Current Chromium ignores anything but loopback; the entrypoint warns if you set something else |
| `CDP_ALLOW_ORIGINS` | *(empty)* | Empty leaves the DevTools origin check on. Setting it (e.g. `*`) passes `--remote-allow-origins` and lets any web page take over the browser — see below |
| `CDP_ALLOW_ANY_SCHEME` | *(empty)* | `1` lets `cdp goto` navigate to schemes other than `http`/`https`/`about`, including `file://` |
| `KIOSK` | `0` | `1` for `--kiosk`, otherwise `--start-fullscreen` |
| `WINDOW_MANAGER` | `1` | fluxbox; without it fullscreen and focus do not work |
| `AUDIO` | `pulse` | `pulse` loads a null sink with a real clock; anything else falls back to ALSA |
| `MUTE_AUDIO` | `1` | `--mute-audio` |
| `DISABLE_GPU` | `1` | `--disable-gpu` |
| `NO_SANDBOX` | `1` | `--no-sandbox`; see the note below |
| `PROFILE_DIR` | `/profile` | Chromium user data directory |
| `RESTART_ON_EXIT` | `1` | Restart the browser when it exits |
| `EXTRA_CHROME_FLAGS` | *(empty)* | Extra flags, space-separated |
| `AFTER_LOAD` / `HOOK_FILE` | *(empty)* / `/hooks/after-load.sh` | After-load hook, see above |
| `AFTER_LOAD_DELAY` | `0` | Extra sleep before the hook |
| `CLICK_DELAY` / `CLICK_XY` | `60` / `684 500` | Used by the bundled hook only |
| `READY_TIMEOUT` | `60` | How long the hook waits for the page |

## Security notes

Read these before exposing anything.

- **`NO_SANDBOX=1` is the default.** The Chromium sandbox needs privileges the container does not have by default. It is convenient and it is a weaker boundary — do not browse hostile pages this way. To harden it, set `NO_SANDBOX=0` and give the container what the sandbox needs: a `seccomp` profile that permits `user_namespaces` (or `--cap-add=SYS_ADMIN`), which means relaxing the `cap_drop`/`no-new-privileges` lines below.
- **An empty `VNC_PASSWORD` means an open VNC server.** `docker-compose.yml` deliberately has no default, so `docker compose up` fails loudly instead of starting an unauthenticated one.
- **VNC is unencrypted.** Across a network, tunnel it: `ssh -L 6080:127.0.0.1:6080 host`.
- **CDP is full control with no authentication.** Anyone who reaches port `9222` can read every cookie in the profile, drive the browser, and navigate it to `file://` to read the container's filesystem. There is no password on it and there cannot be. So it is not published: Chromium binds it to `127.0.0.1` inside the container, `docker-compose.yml` maps no host port for it, and the image no longer `EXPOSE`s it. Use `docker compose exec browser cdp …`. If you genuinely need it on the host, put your own authenticated relay in front of it — do not just map the port.
- **`CDP_BIND` cannot open that port up any more.** Chromium (checked on 150.0.7871.181) ignores `--remote-debugging-address` and binds loopback regardless, so the old `CDP_BIND=0.0.0.0` was a no-op that read like a working feature. The entrypoint now says so out loud.
- **The DevTools origin check is on, and should stay on.** It is the only thing stopping a page *loaded in this very browser* from opening `ws://127.0.0.1:9222` and taking the session over — cookies, keystrokes, local files. `CDP_ALLOW_ORIGINS` turns it off, and is only there for browser-based DevTools frontends. `cdp` does not need it: it sends no `Origin` header at all.
- **The container drops every capability.** `docker-compose.yml` runs it with `cap_drop: ALL` and `no-new-privileges`, on top of the non-root `browser` user baked into the image. Note that `no-new-privileges` also blocks Chromium's setuid sandbox helper, so if you set `NO_SANDBOX=0` you need a kernel that gives the container unprivileged user namespaces.
- The persistent profile holds real session cookies. Treat the `profile` volume as a credential.

## Layout

```
Dockerfile          debian:bookworm-slim + chromium, xvfb, fluxbox, x11vnc, novnc, pulseaudio
entrypoint.sh       brings up X, audio, WM, VNC, noVNC, then supervises Chromium
ctl.sh              -> /usr/local/bin/ctl   pixel-level input via xdotool/scrot
cdp.py              -> /usr/local/bin/cdp   DOM-level control over CDP
hooks/after-load.sh default post-load hook, baked in and overridable
docker-compose.yml  local setup, published ports bound to 127.0.0.1
tests/smoke.sh      container smoke test, run by CI on every push
```

## Tests

`tests/smoke.sh` builds nothing itself — it starts the image and asserts the things that break quietly: that CDP answers, that it is listening on loopback only, that DevTools rejects a foreign `Origin`, that `cdp` honours `CDP_PORT` and refuses `file://`, and that `ctl` rejects bad arguments instead of writing outside `/screenshots`.

```bash
docker build -t headless-docker-browser:test .
tests/smoke.sh
```

`.github/workflows/ci.yml` runs `shellcheck`, `python3 -m py_compile`, `docker compose config`, and that smoke test on every push and pull request.

## License

MIT — see [LICENSE](LICENSE).
