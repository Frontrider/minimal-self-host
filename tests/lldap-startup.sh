#!/bin/sh
set -eu

if [ "${1:-}" != "--inside" ]; then
    root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    exec docker run --rm --network none --entrypoint /bin/sh \
        -v "$root:/source:ro" \
        -v "$root/rootfs/etc/lldap/provision-service-account.sh:/etc/lldap/provision-service-account.sh:ro" \
        "${1:-minimal-self-host-core}" /source/tests/lldap-startup.sh --inside
fi

export LLDAP_LDAP_USER_PASS=test-password
export CORE_INTERNAL_IP=127.0.0.2
unset LDAP_HOST
mkdir -p /var/environment/global-env
startup=/source/rootfs/etc/s6-overlay/s6-rc.d/lldap/run
server_pid=
auth_pid=
cleanup() {
    for pid in "$server_pid" "$auth_pid"; do
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT
trap 'exit 1' TERM INT

sh "$startup" >/tmp/lldap.log 2>&1 &
server_pid=$!
python3 /source/rootfs/etc/basic-forward-auth/server.py >/tmp/auth.log 2>&1 &
auth_pid=$!
tries=0
until [ "$(curl -sS -o /dev/null -w '%{http_code}' -u admin:test-password \
    http://127.0.0.1:9091/auth/api/authz/forward-auth 2>/dev/null)" = 200 ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ] || ! kill -0 "$server_pid" 2>/dev/null; then
        cat /tmp/lldap.log /tmp/auth.log >&2
        exit 1
    fi
    sleep 1
done
curl -fsS -o /dev/null http://127.0.0.1:17180/
kill "$server_pid"
wait "$server_pid"
server_pid=
if curl -fsS -o /dev/null --max-time 1 http://127.0.0.1:17180/ 2>/dev/null; then
    echo "LLDAP survived service shutdown" >&2
    exit 1
fi

export CORE_INTERNAL_IP=192.0.2.1
if sh "$startup" >/tmp/lldap-failure.log 2>&1; then
    echo "LLDAP startup unexpectedly succeeded on an unavailable address" >&2
    exit 1
fi
if ps -o args | grep -q '[s]h /etc/lldap/provision-service-account.sh'; then
    echo "Service-account provisioning survived LLDAP shutdown" >&2
    exit 1
fi
if CORE_INTERNAL_IP= sh "$startup" >/tmp/lldap-missing-ip.log 2>&1; then
    echo "LLDAP startup unexpectedly succeeded without CORE_INTERNAL_IP" >&2
    exit 1
fi
grep -q 'CORE_INTERNAL_IP must be set' /tmp/lldap-missing-ip.log
echo "LLDAP configured address, forward authentication, and shutdown passed"
