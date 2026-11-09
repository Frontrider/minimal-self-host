#!/bin/sh
set -eu

mode=/var/environment/global-env/HTTPS_ENABLED
until [ -s "$mode" ]; do sleep 1; done
case "$(cat "$mode")" in
    on) ;;
    off)
        export APP_SCHEME=http
        export app_baseURL=
        export cookie_secure=false
        ;;
    *) echo "Invalid HTTPS_ENABLED value" >&2; exit 1 ;;
esac
exec app-manager-entrypoint "$@"
