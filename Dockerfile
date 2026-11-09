# Released service binaries, downloaded from GitHub releases.
ARG LLDAP_VERSION=v0.6.3
ARG AWL_VERSION=v0.20.0

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

# Build stage: downloads the released LLDAP binaries for the target architecture.
FROM alpine:3.22 AS auth-build
ARG LLDAP_VERSION
ARG TARGETARCH=amd64

RUN set -eux; \
    apk add --no-cache curl tar; \
    case "$TARGETARCH" in \
        amd64) lldap_arch=amd64 ;; \
        arm64) lldap_arch=aarch64 ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /authroot/opt; \
    curl -fsSL "https://github.com/lldap/lldap/releases/download/${LLDAP_VERSION}/${lldap_arch}-lldap.tar.gz" \
        | tar -C /authroot/opt -xz; \
    mv "/authroot/opt/${lldap_arch}-lldap" /authroot/opt/lldap; \
    chmod +x /authroot/opt/lldap/lldap /authroot/opt/lldap/lldap_set_password

FROM alpine:3.22 AS awl-build
ARG AWL_VERSION
ARG TARGETARCH=amd64

RUN set -eux; \
    apk add --no-cache ca-certificates curl tar; \
    case "$TARGETARCH" in \
        amd64) awl_arch=amd64 ;; \
        arm64) awl_arch=arm64 ;; \
        *) echo "Unsupported AWL architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /awlroot; \
    curl --retry 5 --retry-all-errors -fsSL \
        "https://github.com/anywherelan/awl/releases/download/${AWL_VERSION}/awl-linux-${awl_arch}-${AWL_VERSION}.tar.gz" \
        -o /tmp/awl.tar.gz; \
    tar -C /awlroot -xzf /tmp/awl.tar.gz; \
    test -x /awlroot/awl; \
    rm /tmp/awl.tar.gz

FROM alpine:3.22 AS core
LABEL authors="frontrider"
RUN apk add --no-cache ca-certificates cyrus-sasl curl fail2ban inotify-tools jq logrotate openssl py3-ldap3 rsyslog tzdata unzip
RUN addgroup -S -g 1000 files && adduser -S -u 1000 -G files -h /data files
COPY --from=base-build /s6root/ /

# Pi-hole's FTL resolver and web UI run in core; the installer is run unattended and its services are started by s6.
RUN apk add --no-cache bash curl openrc \
    && mkdir -p /etc/pihole \
    && printf '[dns]\nupstreams = ["1.1.1.1", "1.0.0.1"]\n[webserver]\nport = "127.0.0.2:8082"\n' > /etc/pihole/pihole.toml \
    && curl -fsSL https://install.pi-hole.net -o /tmp/pihole-install.sh \
    && bash -ec ' \
        SKIP_INSTALL=true source /tmp/pihole-install.sh --unattended; \
        enable_service() { printf "Service enable deferred to s6: %s\n" "$1"; }; \
        restart_service() { printf "Service startup deferred to s6: %s\n" "$1"; }; \
        main --unattended' \
    && rm /tmp/pihole-install.sh \
    && install -m 644 /etc/.pihole/advanced/Templates/logrotate /etc/logrotate.d/pihole \
    && setcap 'cap_net_bind_service,cap_net_raw,cap_chown+ep' /usr/bin/pihole-FTL
COPY --from=base-build /usr/bin/tailscale /usr/bin/tailscale
COPY --from=base-build /usr/sbin/tailscaled /usr/sbin/tailscaled
COPY --from=build /bin/caddy /bin/caddy
COPY --from=auth-build /authroot/ /
COPY --from=awl-build /awlroot/awl /usr/local/bin/awl
COPY rootfs/ /
RUN chmod +x /etc/s6-overlay/s6-rc.d/*/run \
    && mkdir -p /config /var/lib/tailscale /var/log/tailscale /var/environment/global-env
EXPOSE 53/tcp 53/udp 80 443 22000/tcp 22000/udp
ENTRYPOINT ["/init"]
