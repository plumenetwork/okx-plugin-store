#!/usr/bin/env bash
# OKOne MR build job — multi-language detector + compiler.
#
# Detects the changed plugin from the commit diff, reads `build.lang` from
# its plugin.yaml, and dispatches to the matching toolchain inside a single
# Docker image that ships all 5 stacks (Rust/Go/Bun/Node/Python).
#
# Mirrors the per-plugin loop inside the `Build plugins` step of GitHub's
# .github/workflows/plugin-publish.yml, scoped to Linux only and one plugin
# per run.
#
# Phases:
#   0. runtime info — dump versions so we can confirm the image has every stack
#   1. detect       — diff against base ref → find the changed plugin
#   2. prepare      — copy or clone the source workspace
#   3. compile      — language-specific case
#   4. verify       — sha256, list output/
set -euo pipefail

# ════════════════════════════════════════════════════════════════════
# Phase 0: runtime info
# ════════════════════════════════════════════════════════════════════
echo "=== runtime info ==="
uname -a 2>&1 | head -1 || true
echo "--- toolchains ---"
{
  echo "rustc:   $(rustc --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "cargo:   $(cargo --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "rustup:  $(rustup --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "go:      $(go version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "node:    $(node --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "bun:     $(bun --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "python3: $(python3 --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "pip:     $(pip --version 2>&1 | head -1 | awk '{print $1,$2}' || echo 'NOT FOUND')"
}
echo

# ════════════════════════════════════════════════════════════════════
# Phase 1: detect changed plugin + parse plugin.yaml
# ════════════════════════════════════════════════════════════════════
ROOT="${CI_PROJECT_DIR:-$(pwd)}"
TARGET_BRANCH="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}"
if [ -n "${TARGET_BRANCH}" ]; then
  git fetch --depth=50 origin "${TARGET_BRANCH}" 2>/dev/null || true
  BASE_SHA="$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null || true)"
else
  BASE_SHA="$(git rev-parse HEAD^1 2>/dev/null || true)"
fi
[ -z "${BASE_SHA}" ] && { echo "ERROR: cannot resolve diff base"; exit 1; }

CHANGED="$(git diff --name-only "${BASE_SHA}...HEAD" -- 'plugin-store/skills/' | head -100)"
PLUGIN_NAME="$(echo "${CHANGED}" | head -1 | cut -d'/' -f3)"
[ -n "${PLUGIN_NAME}" ] || { echo "no plugin changed under plugin-store/skills/, skipping"; exit 0; }
[[ "${PLUGIN_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "ERROR: invalid plugin name '${PLUGIN_NAME}'"; exit 1; }

PLUGIN_DIR="plugin-store/skills/${PLUGIN_NAME}"
YAML="${PLUGIN_DIR}/plugin.yaml"
[ -f "${YAML}" ] || { echo "no plugin.yaml in ${PLUGIN_DIR}, skipping"; exit 0; }

read_yaml() {
  awk -v key="$1" '
    /^build:[ \t]*$/ { in_build=1; next }
    /^[^ \t#]/        { in_build=0 }
    in_build && $0 ~ "^[ \t]+"key"[ \t]*:" {
      sub(/^[^:]*:[ \t]*/, "")
      sub(/^"/, ""); sub(/"$/, "")
      print; exit
    }
  ' "${YAML}"
}

LANG="$(read_yaml lang)"
SOURCE_DIR="$(read_yaml source_dir)"
SOURCE_REPO="$(read_yaml source_repo)"
SOURCE_COMMIT="$(read_yaml source_commit)"
BINARY_NAME="$(read_yaml binary_name)"
BUILD_MAIN="$(read_yaml main)"
[ -z "${SOURCE_DIR}" ] && SOURCE_DIR="."
if [ -z "${LANG}" ]; then
  echo "plugin '${PLUGIN_NAME}' has no build.lang — skill-only, nothing to compile"
  exit 0
fi

echo "=== plugin: ${PLUGIN_NAME}"
echo "    lang:        ${LANG}"
echo "    binary_name: ${BINARY_NAME:-(none)}"
echo "    source_dir:  ${SOURCE_DIR}"
echo "    source_repo: ${SOURCE_REPO:-(local)}"

# ════════════════════════════════════════════════════════════════════
# Phase 2: prepare source workspace
# ════════════════════════════════════════════════════════════════════
WORK="${ROOT}/_build/${PLUGIN_NAME}"
rm -rf "${WORK}"; mkdir -p "${WORK}"
if [ -n "${SOURCE_REPO}" ] && [ -n "${SOURCE_COMMIT}" ]; then
  echo "external source: ${SOURCE_REPO}@${SOURCE_COMMIT}"
  git clone "https://github.com/${SOURCE_REPO}.git" "${WORK}/source"
  git -C "${WORK}/source" checkout "${SOURCE_COMMIT}"
else
  echo "local source: ${PLUGIN_DIR}"
  cp -r "${PLUGIN_DIR}" "${WORK}/source"
fi
SRC="${WORK}/source/${SOURCE_DIR}"
cd "${SRC}"

OUT="${ROOT}/output"
mkdir -p "${OUT}"

# ════════════════════════════════════════════════════════════════════
# Phase 3: language-specific compile
# ════════════════════════════════════════════════════════════════════
BIN=""   # gets set by each branch that produces a single binary
case "${LANG}" in
  rust)
    [ -n "${BINARY_NAME}" ] || { echo "ERROR: build.binary_name required for rust"; exit 1; }
    echo "--- compiling Rust ---"
    if command -v rustup >/dev/null 2>&1; then
      rustup update stable 2>&1 | tail -3 || true
      rustup default stable 2>&1 || true
      echo "active toolchain: $(rustc --version)"
    fi
    cargo fetch
    ( cargo install cargo-audit 2>&1 && cargo audit 2>&1 ) || true
    cargo build --release
    BIN="${SRC}/target/release/${BINARY_NAME}"
    ;;

  go)
    [ -n "${BINARY_NAME}" ] || { echo "ERROR: build.binary_name required for go"; exit 1; }
    echo "--- compiling Go ---"
    go mod download
    ( go install golang.org/x/vuln/cmd/govulncheck@latest 2>&1 && govulncheck ./... 2>&1 ) || true
    CGO_ENABLED=0 go build -o "${BINARY_NAME}" -ldflags="-s -w" .
    BIN="${SRC}/${BINARY_NAME}"
    ;;

  typescript|node)
    [ -n "${BINARY_NAME}" ] || { echo "ERROR: build.binary_name required for ${LANG}"; exit 1; }
    [ -n "${BUILD_MAIN}" ]  || { echo "ERROR: build.main required for ${LANG}";        exit 1; }
    echo "--- compiling ${LANG} via Bun ---"
    if ! command -v bun >/dev/null 2>&1; then
      echo "bun not in image, installing at runtime..."
      curl -fsSL https://bun.sh/install | bash
      export PATH="${HOME}/.bun/bin:${PATH}"
    fi
    bun --version
    bun install
    bun build --compile "${BUILD_MAIN}" --outfile "${BINARY_NAME}"
    BIN="${SRC}/${BINARY_NAME}"
    ;;

  python)
    echo "--- validating Python package ---"
    pip install pip-audit 2>&1 | tail -3 || true
    if ! pip install -e . 2>/dev/null && \
       ! pip install -r requirements.txt 2>/dev/null && \
       ! pip install . ; then
      echo "ERROR: pip install failed"
      exit 1
    fi
    pip-audit 2>&1 | tail -10 || true
    if [ -n "${BUILD_MAIN}" ] && python3 "${BUILD_MAIN}" --help >/dev/null 2>&1; then
      echo "entry point ${BUILD_MAIN} responds to --help"
    elif [ -n "${BINARY_NAME}" ] && command -v "${BINARY_NAME}" >/dev/null 2>&1; then
      echo "installed command ${BINARY_NAME} found on PATH"
    else
      echo "WARNING: could not verify entry point, but pip install succeeded"
    fi
    # Python plugins distribute as pip packages, not single binaries.
    # Write a marker file so output/ is non-empty for downstream OSS upload.
    PKG_INFO="${OUT}/${PLUGIN_NAME}.python-pkg.txt"
    {
      echo "Python package: ${PLUGIN_NAME}"
      [ -n "${BUILD_MAIN}" ]  && echo "Entry point: ${BUILD_MAIN}"
      [ -n "${BINARY_NAME}" ] && echo "CLI command: ${BINARY_NAME}"
      pip show "${PLUGIN_NAME}" 2>/dev/null || true
    } > "${PKG_INFO}"
    echo "python marker → ${PKG_INFO}"
    BIN=""
    ;;

  *)
    echo "ERROR: unknown lang '${LANG}' (expected: rust | go | typescript | node | python)"
    exit 1
    ;;
esac

# ════════════════════════════════════════════════════════════════════
# Phase 4: verify + stage artifact
# ════════════════════════════════════════════════════════════════════
if [ -n "${BIN}" ]; then
  [ -f "${BIN}" ] || { echo "ERROR: binary not found at ${BIN}"; exit 1; }
  chmod +x "${BIN}" 2>/dev/null || true
  cp "${BIN}" "${OUT}/${BINARY_NAME}"
  sha256sum "${OUT}/${BINARY_NAME}"
  echo "OK: ${LANG} build → ${OUT}/${BINARY_NAME}"
fi

echo
echo "=== output/ contents ==="
ls -la "${OUT}/" || true
