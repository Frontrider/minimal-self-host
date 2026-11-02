#!/bin/sh
set -eu

case "$(uname -m)" in
    x86_64|amd64) target_arch=amd64 ;;
    aarch64|arm64) target_arch=arm64 ;;
    *) printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

cd -- "$(dirname -- "$0")"
export DOCKER_DEFAULT_PLATFORM="linux/$target_arch"

docker compose build --build-arg "TARGETARCH=$target_arch" --no-cache
exec docker compose up -d
