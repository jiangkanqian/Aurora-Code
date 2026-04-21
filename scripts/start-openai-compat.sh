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

# Force OpenAI-compatible runtime mode for this launcher.
export CLAUDE_CODE_USE_OPENAI_COMPAT=1
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL="${OPENAI_BASE_URL}"
fi
if [[ -z "${OPENAI_API_KEY:-}" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  export OPENAI_API_KEY="${ANTHROPIC_API_KEY}"
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
  export ANTHROPIC_API_KEY="${OPENAI_API_KEY}"
fi

if [[ ! -f "${CLI_DIST}" ]]; then
  echo "Missing dist/cli.js. Build first: npm run build"
  exit 1
fi

# Proxy handling:
# - default: keep current proxy env (many users need it to reach API)
# - opt-in clear: set OPENAI_COMPAT_CLEAR_PROXY=1/true/yes/on in .env
should_clear_proxy=false
case "${OPENAI_COMPAT_CLEAR_PROXY:-0}" in
  1|true|TRUE|yes|YES|on|ON) should_clear_proxy=true ;;
esac

if [[ "${should_clear_proxy}" == "true" ]]; then
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
  echo "Cleared proxy env vars for this run (OPENAI_COMPAT_CLEAR_PROXY enabled)."
fi

export npm_config_offline=false

apply_macos_system_proxy_if_needed() {
  if [[ "${should_clear_proxy}" == "true" ]]; then
    return 1
  fi
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 1
  fi
  if [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]]; then
    return 1
  fi
  if ! command -v scutil >/dev/null 2>&1; then
    return 1
  fi

  local proxy_info
  proxy_info="$(scutil --proxy 2>/dev/null || true)"
  if [[ -z "${proxy_info}" ]]; then
    return 1
  fi

  local https_enable https_host https_port http_enable http_host http_port proxy
  https_enable="$(printf '%s\n' "${proxy_info}" | awk '/HTTPSEnable :/ {print $3; exit}')"
  https_host="$(printf '%s\n' "${proxy_info}" | awk '/HTTPSProxy :/ {print $3; exit}')"
  https_port="$(printf '%s\n' "${proxy_info}" | awk '/HTTPSPort :/ {print $3; exit}')"
  http_enable="$(printf '%s\n' "${proxy_info}" | awk '/HTTPEnable :/ {print $3; exit}')"
  http_host="$(printf '%s\n' "${proxy_info}" | awk '/HTTPProxy :/ {print $3; exit}')"
  http_port="$(printf '%s\n' "${proxy_info}" | awk '/HTTPPort :/ {print $3; exit}')"

  if [[ "${https_enable}" == "1" && -n "${https_host}" && -n "${https_port}" ]]; then
    proxy="http://${https_host}:${https_port}"
  elif [[ "${http_enable}" == "1" && -n "${http_host}" && -n "${http_port}" ]]; then
    proxy="http://${http_host}:${http_port}"
  else
    return 1
  fi

  export HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" http_proxy="${proxy}" https_proxy="${proxy}"
  echo "Enabled proxy from macOS system settings for this run: ${proxy}"
  return 0
}

apply_macos_system_proxy_if_needed || true

echo "Starting Claude Code with OpenAI-compatible backend..."

patch_jsonc_parser_esm_imports() {
  local esm_dir="${REPO_ROOT}/node_modules/jsonc-parser/lib/esm"
  if [[ ! -d "${esm_dir}" ]]; then
    return 1
  fi

  # Node.js ESM (especially newer runtimes) requires explicit file extensions.
  # Some jsonc-parser builds ship extensionless relative imports in lib/esm/*.js.
  # Patch all JS files in that directory tree.
  node -e "
const fs = require('fs');
const path = require('path');
const root = process.argv[1];

function walk(dir) {
  const out = [];
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) out.push(...walk(p));
    else if (ent.isFile() && p.endsWith('.js')) out.push(p);
  }
  return out;
}

function patchOneFile(filePath) {
  let src = fs.readFileSync(filePath, 'utf8');
  const before = src;

  // Patch:
  //   import ... from './x'
  //   export ... from '../y'
  // -> add .js only when target file exists.
  src = src.replace(
    /\\b(from\\s+['\"])(\\.{1,2}\\/[^'\"\\n]+)(['\"])/g,
    (m, p1, spec, p3) => {
      if (/\\.(mjs|cjs|js|json|node)$/i.test(spec)) return m;
      const target = path.resolve(path.dirname(filePath), spec + '.js');
      if (fs.existsSync(target)) return p1 + spec + '.js' + p3;
      return m;
    }
  );

  if (src !== before) {
    fs.writeFileSync(filePath, src, 'utf8');
    return 1;
  }
  return 0;
}

let changed = 0;
for (const f of walk(root)) {
  changed += patchOneFile(f);
}
if (changed > 0) {
  process.exit(0);
}
process.exit(2);
" "${esm_dir}" >/dev/null 2>&1
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

# Interactive mode (no args): run directly so TUI/output is streamed in real time.
# The retry/auto-install loop below is intended for one-shot invocations (e.g. --print).
if [[ $# -eq 0 ]]; then
  echo "Launching interactive mode..."
  exec node "${CLI_DIST}"
fi

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
