#!/usr/bin/env bash
# 1B — DNS resolution: musl (Alpine) vs glibc (Ubuntu).
# Spec note: in the docx the docker run commands use en-dash "–" due to Word
# autoformat — replace every "–" with "--" when copying. This script uses
# proper double-hyphens.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/logs"

cleanup() {
    docker rm -f dns-server >/dev/null 2>&1 || true
    docker network rm dns-lab >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
docker network create dns-lab >/dev/null

# Start dnsmasq server in the background, route output to logs/dnsmasq.log
docker run -d --name dns-server --network dns-lab alpine sh -c \
    "apk add dnsmasq >/dev/null 2>&1 && \
     echo 'address=/myservice.internal.corp/10.0.0.50' > /etc/dnsmasq.conf && \
     dnsmasq -k --log-queries --log-facility=-" >/dev/null

# Wait for dnsmasq to be ready (apk add takes a few seconds)
for i in $(seq 1 30); do
    if docker logs dns-server 2>&1 | grep -q "started"; then break; fi
    sleep 1
done

DNS_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dns-server)
echo "dnsmasq server at $DNS_IP" | tee "$HERE/logs/setup.log"

run_resolve() {
    local image="$1" tag="$2"
    {
        echo "=== client image=$image  query=myservice.internal  search=corp ==="
        docker run --rm --network dns-lab \
            --dns="$DNS_IP" --dns-search="corp" \
            "$image" getent hosts myservice.internal
        echo "exit=$?"
        echo
    } | tee "$HERE/logs/client-${tag}.log"
}

# ubuntu (glibc)
run_resolve "ubuntu:latest" "ubuntu-glibc" || true
# alpine (musl)
run_resolve "alpine:latest" "alpine-musl" || true

# Capture the dnsmasq query log
docker logs dns-server > "$HERE/logs/dnsmasq.log" 2>&1

echo
echo "=== dnsmasq queries observed ==="
grep -E "query|reply|forwarded" "$HERE/logs/dnsmasq.log" | head -40
