#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
CLI_DIST="${REPO_ROOT}/dist/cli.js"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing .env file at ${ENV_FILE}"
  echo "Create it from .env.example first."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ ! -f "${CLI_DIST}" ]]; then
  echo "Missing dist/cli.js. Build first: npm run build"
  exit 1
fi

# Disable broken proxy/offline settings for this process only.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export npm_config_offline=false

echo "Starting Claude Code with OpenAI-compatible backend..."

patch_jsonc_parser_esm_imports() {
  local main_js="${REPO_ROOT}/node_modules/jsonc-parser/lib/esm/main.js"
  if [[ ! -f "${main_js}" ]]; then
    return 1
  fi

  # Node.js ESM (especially newer runtimes) requires explicit file extensions.
  # Some jsonc-parser builds ship extensionless relative imports in lib/esm/main.js.
  node -e "
const fs = require('fs');
const p = process.argv[1];
let s = fs.readFileSync(p, 'utf8');
const before = s;
s = s
  .replace(/from '\\.\\/impl\\/format'/g, \"from './impl/format.js'\")
  .replace(/from '\\.\\/impl\\/parser'/g, \"from './impl/parser.js'\")
  .replace(/from '\\.\\/impl\\/scanner'/g, \"from './impl/scanner.js'\")
  .replace(/from '\\.\\/impl\\/edit'/g, \"from './impl/edit.js'\");
if (s !== before) {
  fs.writeFileSync(p, s, 'utf8');
  process.exit(0);
}
process.exit(2);
" "${main_js}" >/dev/null 2>&1
  local code=$?

  if [[ ${code} -eq 0 ]]; then
    echo "Patched jsonc-parser ESM imports for Node compatibility, retrying startup..."
    return 0
  fi

  return 1
}

install_missing_package() {
  local pkg="$1"
  if [[ -z "${pkg}" ]]; then
    return 1
  fi
  echo "Detected missing package: ${pkg}"
  echo "Installing in project scope..."
  local output
  set +e
  output="$(
    HTTP_PROXY="" \
  HTTPS_PROXY="" \
  ALL_PROXY="" \
  npm_config_proxy="" \
  npm_config_https_proxy="" \
  npm_config_offline=false \
  npm_config_cache="${REPO_ROOT}/.npm-cache" \
  npm install "${pkg}" --save --prefer-online --offline=false 2>&1
  )"
  local code=$?
  set -e

  if [[ ${code} -eq 0 ]]; then
    return 0
  fi

  if [[ "${pkg}" == "@ant/claude-for-chrome-mcp" ]]; then
    echo "Package ${pkg} is not publicly available. Creating local stub package..."
    local pkg_dir="${REPO_ROOT}/node_modules/@ant/claude-for-chrome-mcp"
    mkdir -p "${pkg_dir}"
    cat > "${pkg_dir}/package.json" <<'JSON'
{
  "name": "@ant/claude-for-chrome-mcp",
  "version": "0.0.0-local-stub",
  "type": "module",
  "main": "./index.js"
}
JSON
    cat > "${pkg_dir}/index.js" <<'JS'
export const BROWSER_TOOLS = []
export function createClaudeForChromeMcpServer() {
  return {
    connect() {},
    close() {}
  }
}
export default {
  BROWSER_TOOLS,
  createClaudeForChromeMcpServer
}
JS
    return 0
  fi

  printf '%s\n' "${output}"
  return 1
}

max_attempts=60
attempt=1
while [[ ${attempt} -le ${max_attempts} ]]; do
  echo "Startup attempt ${attempt}/${max_attempts}..."
  set +e
  output="$(node "${CLI_DIST}" "$@" 2>&1)"
  code=$?
  set -e

  if [[ ${code} -eq 0 ]]; then
    printf '%s\n' "${output}"
    exit 0
  fi

  pkg="$(printf '%s' "${output}" | sed -n "s/.*Cannot find package '\([^']*\)'.*/\1/p" | head -n 1)"
  if [[ -z "${pkg}" ]]; then
    if printf '%s' "${output}" | grep -q "jsonc-parser/lib/esm/impl/format"; then
      patch_jsonc_parser_esm_imports && {
        attempt=$((attempt + 1))
        continue
      }
    fi
    printf '%s\n' "${output}"
    exit "${code}"
  fi

  install_missing_package "${pkg}" || {
    echo "Auto-install failed for package: ${pkg}"
    printf '%s\n' "${output}"
    exit 1
  }
  echo "Installed ${pkg}, retrying startup..."
  attempt=$((attempt + 1))
done

echo "Reached maximum auto-install attempts (${max_attempts})."
printf '%s\n' "${output}"
exit 1
