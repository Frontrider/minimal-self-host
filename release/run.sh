#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    exec sudo -- "$BASH" "$0" "$@"
fi

curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

docker compose up -d