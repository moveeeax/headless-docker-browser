FROM debian:bookworm-slim

# Chromium из Debian это настоящий deb, а не snap-обёртка как chromium-browser в Ubuntu.
# novnc + python3-websockify дают веб-клиент, tini пожинает зомби-процессы Chromium.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium \
        xvfb \
        fluxbox \
        pulseaudio \
        pulseaudio-utils \
        x11vnc \
        novnc \
        python3-websockify \
        tini \
        xdotool \
        scrot \
        python3-websocket \
        procps \
        curl \
        ca-certificates \
        fonts-liberation \
        fonts-noto-core \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -s /bin/bash browser \
    && mkdir -p /profile /screenshots /hooks \
    && chown browser:browser /profile /screenshots /hooks

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 ctl.sh /usr/local/bin/ctl
COPY --chmod=0755 cdp.py /usr/local/bin/cdp
COPY --chmod=0755 hooks/after-load.sh /hooks/after-load.sh

USER browser
WORKDIR /home/browser

ENV URL="https://example.com" \
    DISPLAY_NUM="99" \
    SCREEN_WIDTH="1920" \
    SCREEN_HEIGHT="1080" \
    SCREEN_DEPTH="24" \
    VNC_PORT="5900" \
    NOVNC_PORT="6080" \
    CDP_PORT="9222" \
    CDP_BIND="127.0.0.1" \
    CDP_ALLOW_ORIGINS="" \
    VNC_VIEW_ONLY="0" \
    PROFILE_DIR="/profile" \
    NO_SANDBOX="1" \
    KIOSK="0" \
    RESTART_ON_EXIT="1" \
    EXTRA_CHROME_FLAGS="" \
    AFTER_LOAD="" \
    HOOK_FILE="/hooks/after-load.sh" \
    AFTER_LOAD_DELAY="0" \
    CLICK_DELAY="60" \
    CLICK_XY="684 500" \
    READY_TIMEOUT="60" \
    WINDOW_MANAGER="1" \
    DISABLE_GPU="1" \
    AUDIO="pulse" \
    MUTE_AUDIO="1"

# VNC_PASSWORD намеренно не объявлен через ENV: пароль в метаданных образа
# виден любому, кто сделает docker history. Пустое значение обрабатывает
# entrypoint, задавать пароль нужно при запуске.
EXPOSE 5900 6080

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" > /dev/null || exit 1

# Скрипт запускается через bash, а не по пути: так exec-бит не нужен вовсе.
# -s регистрирует tini как child subreaper, если он вдруг окажется не PID 1.
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/bin/bash", "/usr/local/bin/entrypoint.sh"]
