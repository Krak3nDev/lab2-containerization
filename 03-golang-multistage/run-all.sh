#!/usr/bin/env bash
set -euo pipefail

SRC=/tmp/lab2-go-starter
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$SRC" ]]; then
    echo "Go starter not found at $SRC" >&2; exit 1
fi

RESULTS="$HERE/results.txt"
echo "# 1C Go multi-stage results (run $(date))" > "$RESULTS"

measure() {
    local name="$1" exp_dir="$2" tag="$3"
    rm -rf "$exp_dir/_src"
    mkdir -p "$exp_dir/_src"
    cp -a "$SRC"/. "$exp_dir/_src/"
    cp "$exp_dir/Dockerfile" "$exp_dir/_src/Dockerfile"
    local t0 t1
    t0=$(python3 -c 'import time; print(time.time())')
    docker build --no-cache -t "$tag" "$exp_dir/_src" > /tmp/build.log 2>&1
    t1=$(python3 -c 'import time; print(time.time())')
    local secs=$(python3 -c "print(f'{$t1 - $t0:.2f}')")
    local size_bytes=$(docker image inspect "$tag" --format '{{.Size}}')
    local size=$(python3 -c "print(f'{$size_bytes/1024/1024:.1f}MB')")
    printf '%-35s  size=%-10s  build=%ss\n' "$name" "$size" "$secs" | tee -a "$RESULTS"
}

measure "1C-a: single-stage golang"  "$HERE/a-single-stage"  lab2-go-a
measure "1C-b: multi-stage FROM scratch" "$HERE/b-scratch"   lab2-go-b
measure "1C-c: multi-stage distroless"   "$HERE/c-distroless" lab2-go-c

echo
echo "=== contents analysis ==="
{
    echo "## 1C-a single-stage — relevant size hogs"
    docker run --rm --entrypoint='' lab2-go-a sh -c 'du -sh /usr/local/go 2>/dev/null; du -sh /root 2>/dev/null; du -sh /app 2>/dev/null'
    echo
    echo "## 1C-b scratch — root contents (everything that ships)"
    docker run --rm --entrypoint='' lab2-go-b /app/fizzbuzz --help 2>/dev/null || true
    docker save lab2-go-b | tar -tf - 2>/dev/null | head -5
    echo
    echo "## 1C-c distroless — root contents"
    docker save lab2-go-c | tar -tf - 2>/dev/null | head -10
} | tee -a "$RESULTS"
