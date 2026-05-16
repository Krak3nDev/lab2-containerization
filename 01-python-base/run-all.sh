#!/usr/bin/env bash
# Runs all five 1A sub-experiments and writes results.txt entries.
# Source of truth for the starter:
#   commit hash recorded in /Users/nazar./PycharmProjects/lab2-containerization/.starter-hashes
set -euo pipefail

SRC=/tmp/lab2-python-starter
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$SRC/spaceship" ]]; then
    echo "starter not found at $SRC" >&2
    exit 1
fi

# numpy variant uses requirements.txt with numpy + matrix endpoint
NUMPY_REQ=$'fastapi\npydantic>=2.0\npydantic-settings\nstarlette\nuvicorn[standard]\nnumpy\n'

# Patched api.py with matrix endpoint, for e-numpy/* experiments. Tmp file —
# regenerated on every run, never committed to the repo.
MATRIX_API_PATCH="$(mktemp -t lab2-matrix-api.XXXXXX.py)"
trap 'rm -f "$MATRIX_API_PATCH"' EXIT
cat > "$MATRIX_API_PATCH" <<'PY'
import numpy as np
from fastapi import APIRouter

router = APIRouter()


@router.get('')
def hello_world() -> dict:
    return {'msg': 'Hello, World!'}


@router.get('/matrix')
def matrix() -> dict:
    a = np.random.rand(10, 10)
    b = np.random.rand(10, 10)
    p = a @ b
    return {
        'matrix_a': a.tolist(),
        'matrix_b': b.tolist(),
        'product': p.tolist(),
    }
PY

measure() {
    local name="$1" ctx="$2" tag="$3" no_cache="${4:-1}"
    local t0 t1
    t0=$(python3 -c 'import time; print(time.time())')
    if (( no_cache )); then
        docker build --no-cache -t "$tag" "$ctx" > /tmp/build.log 2>&1
    else
        docker build -t "$tag" "$ctx" > /tmp/build.log 2>&1
    fi
    t1=$(python3 -c 'import time; print(time.time())')
    local secs=$(python3 -c "print(f'{$t1 - $t0:.2f}')")
    local size=$(docker image inspect "$tag" --format '{{.Size}}' | python3 -c "import sys; print(f'{int(sys.stdin.read())/1024/1024:.1f}MB')")
    printf '%-30s  size=%-10s  build=%ss  (%s)\n' "$name" "$size" "$secs" "$(if (( no_cache )); then echo cold; else echo warm; fi)"
}

prep_basic() {
    local exp_dir="$1"
    rm -rf "$exp_dir/_src"
    mkdir -p "$exp_dir/_src/requirements"
    cp -a "$SRC/spaceship" "$exp_dir/_src/spaceship"
    cp -a "$SRC/build"     "$exp_dir/_src/build"
    cp    "$SRC/requirements/backend.in" "$exp_dir/_src/requirements/backend.in"
    cp    "$exp_dir/Dockerfile" "$exp_dir/_src/Dockerfile"
}

prep_numpy() {
    local exp_dir="$1"
    rm -rf "$exp_dir/_src"
    mkdir -p "$exp_dir/_src"
    cp -a "$SRC/spaceship" "$exp_dir/_src/spaceship"
    cp -a "$SRC/build"     "$exp_dir/_src/build"
    cp "$MATRIX_API_PATCH" "$exp_dir/_src/spaceship/routers/api.py"
    printf '%s' "$NUMPY_REQ" > "$exp_dir/_src/requirements.txt"
    cp "$exp_dir/Dockerfile" "$exp_dir/_src/Dockerfile"
}

RESULTS="$HERE/results.txt"
echo "# 1A results (run on $(date))" > "$RESULTS"
echo >> "$RESULTS"

# (a) naive initial
prep_basic "$HERE/a-initial"
measure "1A-a: naive (cold)" "$HERE/a-initial/_src" lab2-py-a 1 | tee -a "$RESULTS"

# (b) code edit + rebuild (warm — relies on existing cache from a)
echo '# unchanged' >> "$HERE/a-initial/_src/spaceship/main.py"
measure "1A-b: post-edit rebuild" "$HERE/a-initial/_src" lab2-py-b 0 | tee -a "$RESULTS"

# (c) cache-optimized — first cold, then warm-after-code-edit
prep_basic "$HERE/c-cache-optimized"
measure "1A-c: cache-opt (cold)" "$HERE/c-cache-optimized/_src" lab2-py-c 1 | tee -a "$RESULTS"
echo '# unchanged' >> "$HERE/c-cache-optimized/_src/spaceship/main.py"
measure "1A-c: cache-opt (post-edit)" "$HERE/c-cache-optimized/_src" lab2-py-c2 0 | tee -a "$RESULTS"

# (d) alpine
prep_basic "$HERE/d-alpine"
measure "1A-d: alpine (cold)" "$HERE/d-alpine/_src" lab2-py-d 1 | tee -a "$RESULTS"

# (e) numpy debian
prep_numpy "$HERE/e-numpy/debian"
measure "1A-e: numpy/debian (cold)" "$HERE/e-numpy/debian/_src" lab2-py-e-deb 1 | tee -a "$RESULTS"

# (e) numpy alpine
prep_numpy "$HERE/e-numpy/alpine"
measure "1A-e: numpy/alpine (cold)" "$HERE/e-numpy/alpine/_src" lab2-py-e-alp 1 | tee -a "$RESULTS"

echo
echo "=== summary ==="
cat "$RESULTS"
