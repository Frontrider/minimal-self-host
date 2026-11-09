#!/bin/sh
set -eu

if [ "${1:-}" != "--inside" ] && [ "${1:-}" != "--inside-awl" ] && [ "${1:-}" != "--inside-auth" ] && [ "${1:-}" != "--inside-app" ]; then
    root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    image=${1:-minimal-self-host-core}
    for mode in false true; do
        docker run --rm --network none --entrypoint /bin/sh \
            -e CADDY_HTTPS_MODE_ENABLED="$mode" \
            -v "$root:/source:ro" \
            -v "$root/rootfs/etc/s6-overlay/s6-rc.d/anywherelan-enabled:/etc/s6-overlay/s6-rc.d/anywherelan-enabled:ro" \
            -v "$root/rootfs/etc/s6-overlay/s6-rc.d/tailscale-enabled:/etc/s6-overlay/s6-rc.d/tailscale-enabled:ro" \
            "$image" /source/tests/network-mode.sh --inside
    done
    docker run --rm --network none --cap-add NET_ADMIN --device /dev/net/tun \
        --entrypoint /bin/sh -e AWL_DATA_DIR=/tmp/awl \
        -v "$root:/source:ro" "$image" /source/tests/network-mode.sh --inside-awl
    docker run --rm --entrypoint /bin/sh -v "$root:/source:ro" "$image" -ec \
        'apk add --no-cache -q py3-ldap3 && exec /bin/sh /source/tests/network-mode.sh --inside-auth'
    for mode in off on; do
        docker run --rm --network none --entrypoint /bin/sh -e TEST_MODE="$mode" \
            -v "$root:/source:ro" -v /var/run/docker.sock:/var/run/docker.sock:ro \
            ghcr.io/frontrider/app-manager:0.0.7 /source/tests/network-mode.sh --inside-app
    done
    exit
fi

PATH="/command:$PATH"
export PATH
if [ "$1" = "--inside-app" ]; then
    mkdir -p /var/environment/global-env
    printf '%s' "$TEST_MODE" > /var/environment/global-env/HTTPS_ENABLED
    printf '%s' local-host.awl > /var/environment/global-env/DOMAIN
    export DOMAIN_DIRECTORY=/var/environment/global-env APP_SCHEME=https cookie_secure=true
    export CADDY_PROXY_HOST=127.0.0.1 app_indexPage=
    /bin/sh /source/rootfs/etc/app-manager-mode-entrypoint.sh php-fpm >/tmp/app.log 2>&1 &
    unset APP_SCHEME cookie_secure
    tries=0
    until SCRIPT_NAME=/index.php SCRIPT_FILENAME=/var/www/html/public/index.php REQUEST_METHOD=GET \
        REQUEST_URI=/ SERVER_NAME=local-host.awl SERVER_PORT=80 HTTP_HOST=local-host.awl \
        HTTPS="$TEST_MODE" cgi-fcgi -bind -connect 127.0.0.1:9000 > /tmp/response 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            cat /tmp/app.log >&2
            exit 1
        fi
        sleep 1
    done
    if [ "$TEST_MODE" = off ]; then
        if ! grep -qi '^Location: http://local-host.awl/login' /tmp/response; then
            cat /tmp/response >&2
            exit 1
        fi
        if grep -qi '^Set-Cookie:.*; secure' /tmp/response; then
            echo "HTTP session cookie is marked secure" >&2
            exit 1
        fi
    else
        if ! grep -qi '^Location: https://local-host.awl/login' /tmp/response; then
            cat /tmp/response >&2
            exit 1
        fi
        grep -qi '^Set-Cookie:.*; secure' /tmp/response
    fi
    echo "App-manager mode $TEST_MODE passed"
    exit
fi
if [ "$1" = "--inside-auth" ]; then
    export LLDAP_LDAP_HOST=127.0.0.1 LLDAP_HTTP_HOST=127.0.0.1
    export LLDAP_LDAP_USER_PASS=test-password LLDAP_JWT_SECRET=test-jwt-secret
    export LLDAP_KEY_SEED=test-key-seed LLDAP_DATABASE_URL=sqlite:///tmp/lldap.db?mode=rwc
    (cd /opt/lldap && exec ./lldap run) >/tmp/lldap.log 2>&1 &
    ldap_pid=$!
    LDAP_HOST=127.0.0.1 python3 /source/rootfs/etc/basic-forward-auth/server.py >/tmp/auth.log 2>&1 &
    tries=0
    until [ "$(curl -sS -o /dev/null -w '%{http_code}' -u admin:test-password \
        http://127.0.0.1:9091/auth/api/authz/forward-auth 2>/dev/null)" = 200 ]; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            cat /tmp/lldap.log /tmp/auth.log >&2
            exit 1
        fi
        sleep 1
    done
    curl -fsS -D /tmp/headers -o /dev/null -u admin:test-password \
        http://127.0.0.1:9091/auth/api/authz/forward-auth
    for pattern in '^Remote-User: admin' '^Remote-Groups: .*lldap_admin' '^Remote-Name:' '^Remote-Email:'; do
        if ! grep -qi "$pattern" /tmp/headers; then
            echo "Missing expected header: $pattern" >&2
            cat /tmp/headers >&2
            exit 1
        fi
    done
    status=$(curl -sS -o /dev/null -w '%{http_code}' -u admin:wrong \
        http://127.0.0.1:9091/auth/api/authz/forward-auth)
    if [ "$status" != 401 ]; then
        echo "Invalid credentials returned $status instead of 401" >&2
        cat /tmp/auth.log >&2
        exit 1
    fi
    [ "$(curl -sS -o /dev/null -w '%{http_code}' \
        http://127.0.0.1:9091/auth/api/authz/forward-auth)" = 401 ]
    /bin/caddy run --config /source/tests/forward-auth.Caddyfile --adapter caddyfile >/tmp/caddy-auth.log 2>&1 &
    tries=0
    until [ "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18888/ 2>/dev/null)" = 401 ]; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            cat /tmp/caddy-auth.log >&2
            exit 1
        fi
        sleep 1
    done
    result=$(curl -fsS -u admin:test-password -H 'Remote-User: forged' http://127.0.0.1:18888/)
    case "$result" in
        admin\|*lldap_admin*\|*\|*) ;;
        *) echo "Unexpected forwarded identity: $result" >&2; exit 1 ;;
    esac
    kill "$ldap_pid"
    wait "$ldap_pid" || true
    [ "$(curl -sS -o /dev/null -w '%{http_code}' -u admin:test-password \
        http://127.0.0.1:9091/auth/api/authz/forward-auth)" = 503 ]
    echo "LDAP forward authentication passed"
    exit
fi
if [ "$1" = "--inside-awl" ]; then
    /bin/sh /source/rootfs/etc/s6-overlay/s6-rc.d/anywherelan/run >/tmp/awl.log 2>&1 &
    awl_pid=$!
    tries=0
    until curl -fsS -o /dev/null http://127.0.0.1:8639/ 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ] || ! kill -0 "$awl_pid" 2>/dev/null; then
            cat /tmp/awl.log >&2
            exit 1
        fi
        sleep 1
    done
    jq -e '.httpListenAddress == "127.0.0.1:8639" and .httpListenOnAdminHost == false and .p2pNode.name == "local-host" and (.p2pNode.peerId | length > 0)' \
        /tmp/awl/config_awl.json >/dev/null
    if curl -sS -o /dev/null --max-time 1 http://127.0.0.66:80/ 2>/dev/null; then
        echo "Anywherelan unexpectedly bound port 80" >&2
        exit 1
    fi
    peer_id=$(jq -r '.p2pNode.peerId' /tmp/awl/config_awl.json)
    kill "$awl_pid"
    wait "$awl_pid"
    jq '.p2pNode.name = "custom-name"' /tmp/awl/config_awl.json > /tmp/awl/config.new
    mv /tmp/awl/config.new /tmp/awl/config_awl.json
    /bin/sh /source/rootfs/etc/s6-overlay/s6-rc.d/anywherelan/run >/tmp/awl.log 2>&1 &
    awl_pid=$!
    tries=0
    until curl -fsS -o /dev/null http://127.0.0.1:8639/ 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ] || ! kill -0 "$awl_pid" 2>/dev/null; then
            cat /tmp/awl.log >&2
            exit 1
        fi
        sleep 1
    done
    jq -e --arg peer_id "$peer_id" '.p2pNode.name == "custom-name" and .p2pNode.peerId == $peer_id' \
        /tmp/awl/config_awl.json >/dev/null
    echo "Anywherelan admin listener and peer name passed"
    exit
fi

mkdir -p /var/environment/global-env /run/s6/container_environment
printf '%s' test.example > /var/environment/global-env/DOMAIN

if [ "$CADDY_HTTPS_MODE_ENABLED" = true ]; then
    printf '%s' test-key > /run/s6/container_environment/TS_AUTH_KEY
    enabled=tailscale-enabled
    disabled=anywherelan-enabled
else
    rm -f /run/s6/container_environment/TS_AUTH_KEY
    enabled=anywherelan-enabled
    disabled=tailscale-enabled
fi
/command/execlineb -c "$(cat "/source/rootfs/etc/s6-overlay/s6-rc.d/$enabled/up")"
if /command/execlineb -c "$(cat "/source/rootfs/etc/s6-overlay/s6-rc.d/$disabled/up")"; then
    echo "Disabled network mode unexpectedly started" >&2
    exit 1
fi

/bin/caddy respond --listen 127.0.0.1:90 --body main >/dev/null 2>&1 &
/bin/caddy respond --listen 127.0.0.1:8639 --body admin >/dev/null 2>&1 &
/bin/caddy run --config /source/rootfs/etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 &

tries=0
until curl -sS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
        echo "Caddy did not start" >&2
        exit 1
    fi
    sleep 1
done

[ "$(curl -fsS http://127.0.0.1:8080/)" = admin ]
if [ "$CADDY_HTTPS_MODE_ENABLED" = true ]; then
    [ "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1/path)" = \
        "301 https://test.example/path" ]
else
    [ "$(curl -fsS http://127.0.0.1/)" = main ]
fi
echo "Network mode $CADDY_HTTPS_MODE_ENABLED passed"
