# Build stage: fetches the s6-overlay and Tailscale runtime, copied into the image below.
FROM alpine:3.22 AS base-build
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG TARGETARCH=amd64

RUN apk add --no-cache curl xz tailscale

RUN set -eux; \
    mkdir -p /s6root; \
    curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
        -o /tmp/s6-overlay-noarch.tar.xz; \
    tar -C /s6root -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    case "$TARGETARCH" in \
        amd64) s6_arch=x86_64 ;; \
        arm64) s6_arch=aarch64 ;; \
        *) echo "Unsupported s6 architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz" \
        -o /tmp/s6-overlay-arch.tar.xz; \
    tar -C /s6root -Jxpf /tmp/s6-overlay-arch.tar.xz; \
    rm /tmp/s6-overlay-arch.tar.xz /tmp/s6-overlay-noarch.tar.xz

# Build stage: xcaddy compiles Caddy with the plugins, then only the binary is copied out.
FROM caddy:2-builder-alpine AS build

RUN xcaddy build --output /bin/caddy \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2 \
    --with github.com/ueffel/caddy-imagefilter/v2/smartcrop \
    --with github.com/mholt/caddy-l4 \
    --with github.com/caddyserver/replace-response

FROM alpine:3.22
LABEL authors="frontrider"
ARG COPYPARTY_VERSION=1.20.26
ARG JELLYFIN_VERSION=12.4
ARG JELLYFIN_REMOTEAUTH_PLUGIN_VERSION=2.0.0.0
ARG TARGETARCH=amd64

# Packages used by the s6 services: fail2ban (fail2ban), openssl (Jellyfin's Remote Auth secret),
# python3 (syncthing config merge and copyparty), syncthing.
# The syncthing package creates its user. ffmpeg and icu-libs are needed by Jellyfin.
# ca-certificates, curl and tzdata come from the base layer; curl is also used by the Tailscale service.
RUN apk add --no-cache ca-certificates cyrus-sasl curl fail2ban ffmpeg gcompat icu-libs jq logrotate openssl py3-jinja2 python3 rsyslog syncthing tzdata unzip

COPY --from=base-build /s6root/ /
COPY --from=base-build /usr/bin/tailscale /usr/bin/tailscale
COPY --from=base-build /usr/sbin/tailscaled /usr/sbin/tailscaled
COPY --from=build /bin/caddy /bin/caddy

# copyparty is pure Python and has no Alpine package. The source tarball's copyparty package is
# unpacked to /opt/copyparty and run with the system python3 (see s6-rc.d/copyparty/run).
RUN set -eux; \
    curl -fsSL "https://github.com/9001/copyparty/releases/download/v${COPYPARTY_VERSION}/copyparty-${COPYPARTY_VERSION}.tar.gz" \
        -o /tmp/copyparty.tar.gz; \
    echo "ac7ea05bde8d431b32cc2ff618f2754e46bd967bf10deaa6654dac9a449a6ff9  /tmp/copyparty.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/copyparty; \
    tar -C /opt/copyparty -xzf /tmp/copyparty.tar.gz --strip-components=1 "copyparty-${COPYPARTY_VERSION}/copyparty"; \
    rm /tmp/copyparty.tar.gz

# Jellyfin's musl server build runs on Alpine directly. The install dir holds the binary and
# jellyfin-web. The Remote Auth plugin is kept in plugins-default and copied into the jellyfin volume at start.
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) jellyfin_arch=amd64; jellyfin_sha256=3f072c923cf831246edf9336ecd8daee0b425575246e1b2e9d0ac5deb21f2726 ;; \
        arm64) jellyfin_arch=arm64; jellyfin_sha256=2e7194ba67416589dd7a9387078fd46d806fcd4e1c85f15b472320455147c2f8 ;; \
        *) echo "Unsupported Jellyfin architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://repo.jellyfin.org/files/server/linux/latest-stable/${jellyfin_arch}-musl/jellyfin_${JELLYFIN_VERSION}-${jellyfin_arch}-musl.tar.gz" \
        -o /tmp/jellyfin.tar.gz; \
    echo "${jellyfin_sha256}  /tmp/jellyfin.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/jellyfin; \
    tar -C /opt/jellyfin -xzf /tmp/jellyfin.tar.gz --strip-components=1; \
    rm /tmp/jellyfin.tar.gz; \
    curl -fsSL "https://github.com/BlackDark/jellyfin-plugin-remoteauth/releases/download/v2.0.0/remote-auth_${JELLYFIN_REMOTEAUTH_PLUGIN_VERSION}.zip" \
        -o /tmp/remoteauth-plugin.zip; \
    echo "32215973915cfd5ca1295e1e76f3169ed8aaebd99592843e8f067c684bec0915  /tmp/remoteauth-plugin.zip" | sha256sum -c -; \
    mkdir -p /opt/jellyfin/plugins-default/RemoteAuth_${JELLYFIN_REMOTEAUTH_PLUGIN_VERSION}; \
    unzip -q /tmp/remoteauth-plugin.zip -d /opt/jellyfin/plugins-default/RemoteAuth_${JELLYFIN_REMOTEAUTH_PLUGIN_VERSION}; \
    rm /tmp/remoteauth-plugin.zip

COPY rootfs/ /
RUN chmod +x \
       /etc/s6-overlay/s6-rc.d/caddy/run \
       /etc/s6-overlay/s6-rc.d/fail2ban/run \
       /etc/s6-overlay/s6-rc.d/fail2ban-log/run \
       /etc/s6-overlay/s6-rc.d/syncthing/run \
       /etc/s6-overlay/s6-rc.d/syncthing-log/run \
       /etc/s6-overlay/s6-rc.d/copyparty/run \
       /etc/s6-overlay/s6-rc.d/copyparty-log/run \
       /etc/s6-overlay/s6-rc.d/jellyfin/run \
       /etc/s6-overlay/s6-rc.d/jellyfin-log/run \
       /etc/s6-overlay/s6-rc.d/tailscale/run \
       /etc/s6-overlay/s6-rc.d/tailscale-log/run \
       /etc/s6-overlay/s6-rc.d/rsyslog/run \
       /etc/s6-overlay/s6-rc.d/logrotate/run \
    && mkdir -p /data /config /var/syncthing /var/lib/tailscale /var/log/tailscale /var/environment/global-env \
    && chown syncthing:syncthing /var/syncthing

EXPOSE 80 443

ENTRYPOINT ["/init"]
