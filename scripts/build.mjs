#!/usr/bin/env node
/**
 * Best-effort build script for decompiled source.
 *
 * Steps:
 * 1. Copy src/ -> build-src/
 * 2. Replace feature('X') -> false
 * 3. Replace MACRO.* constants
 * 4. Remove bun:bundle imports
 * 5. Bundle with esbuild (iterative stub fallback)
 */

import {
  readdir,
  readFile,
  writeFile,
  mkdir,
  cp,
  rm,
  stat,
} from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { execSync, execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = join(__dirname, '..')
const VERSION = '2.1.88'
const BUILD = join(ROOT, 'build-src')
const ENTRY = join(BUILD, 'entry.ts')
const BUILD_TSCONFIG = join(BUILD, 'tsconfig.build.json')
const DIST = join(ROOT, 'dist')
const OUT_FILE = join(DIST, 'cli.js')
const LOCAL_NPM_CACHE = join(ROOT, '.npm-cache')

function getNpmCommand() {
  return process.platform === 'win32' ? 'npm.cmd' : 'npm'
}

function getEsbuildEntry() {
  const base = join(ROOT, 'node_modules', 'esbuild', 'bin', 'esbuild')
  if (process.platform === 'win32') {
    const exe = `${base}.exe`
    if (existsSync(exe)) return exe
  }
  return base
}

function runEsbuild(args, options = {}) {
  const esbuildEntry = getEsbuildEntry()
  return execFileSync(esbuildEntry, args, {
    cwd: ROOT,
    ...options,
  })
}

function npmEnv() {
  return {
    ...process.env,
    npm_config_cache: LOCAL_NPM_CACHE,
    npm_config_prefer_online: 'true',
    npm_config_offline: 'false',
  }
}

async function exists(path) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name)
    if (entry.isDirectory() && entry.name !== 'node_modules') {
      yield* walk(p)
    } else {
      yield p
    }
  }
}

async function ensureEsbuild() {
  try {
    runEsbuild(['--version'], { stdio: 'pipe' })
    return
  } catch {
    // fall through to install
  }

  console.log('Installing esbuild with project-local npm cache...')
  await mkdir(LOCAL_NPM_CACHE, { recursive: true })
  execSync(
    `${getNpmCommand()} install --save-dev esbuild --cache "${LOCAL_NPM_CACHE}"`,
    {
      cwd: ROOT,
      stdio: 'inherit',
      shell: true,
      env: npmEnv(),
    },
  )

  runEsbuild(['--version'], { stdio: 'pipe' })
}

function bundleOnce() {
  return runEsbuild(
    [
      ENTRY,
      `--tsconfig=${BUILD_TSCONFIG}`,
      '--bundle',
      '--platform=node',
      '--target=node18',
      '--format=esm',
      "--banner:js=import { createRequire as __ccCreateRequire } from 'node:module';const require = __ccCreateRequire(import.meta.url);",
      `--outfile=${OUT_FILE}`,
      '--packages=external',
      '--external:bun:*',
      '--allow-overwrite',
      '--log-level=error',
      '--log-limit=0',
      '--loader:.md=text',
      '--loader:.txt=text',
      '--sourcemap',
    ],
    {
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  )
}

function parseMissingModules(outputText) {
  const missing = new Set()
  const re = /Could not resolve "([^"]+)"/g
  let match = null
  while ((match = re.exec(outputText)) !== null) {
    const mod = match[1]
    if (!mod.startsWith('node:') && !mod.startsWith('bun:') && !mod.startsWith('/')) {
      missing.add(mod)
    }
  }
  return missing
}

async function createStubForModule(mod) {
  const clean = mod.replace(/^\.\//, '')
  const normalized = clean.replace(/^(\.\.\/)+/, '')

  if (/\.(txt|md|json)$/i.test(clean)) {
    let created = 0
    for (const rel of [clean, normalized]) {
      const p = join(BUILD, 'src', rel)
      await mkdir(dirname(p), { recursive: true }).catch(() => {})
      if (!(await exists(p))) {
        await writeFile(p, rel.endsWith('.json') ? '{}' : '', 'utf8')
        created++
      }
    }
    return created
  }

  if (/\.[tj]sx?$/i.test(clean)) {
    let created = 0
    for (const rel of [clean, normalized]) {
      for (const base of [join(BUILD, 'src'), join(BUILD, 'src', 'src')]) {
        const p = join(base, rel)
        await mkdir(dirname(p), { recursive: true }).catch(() => {})
        if (!(await exists(p))) {
          await writeFile(
            p,
            `// Auto-generated stub\nexport default function __stub_default() {}\nexport const __stub = () => {}\n`,
            'utf8',
          )
          created++
        }
      }
    }
    return created
  }

  return 0
}

async function writeStubFile(relPath, content) {
  const p = join(BUILD, 'src', relPath)
  await mkdir(dirname(p), { recursive: true })
  if (!(await exists(p))) {
    await writeFile(p, content, 'utf8')
  }
}

// Phase 1: copy source
await rm(BUILD, { recursive: true, force: true })
await mkdir(BUILD, { recursive: true })
await cp(join(ROOT, 'src'), join(BUILD, 'src'), { recursive: true })
// Some decompiled files import runtime JS from non-src roots in this repo.
// Mirror them into build-src/src so relative imports can resolve.
for (const dirName of ['tools', 'types', 'utils']) {
  const from = join(ROOT, dirName)
  const to = join(BUILD, 'src', dirName)
  if (await exists(from)) {
    await cp(from, to, { recursive: true })
  }
}
await mkdir(join(BUILD, 'src', 'stubs'), { recursive: true })
await writeFile(
  join(BUILD, 'src', 'stubs', 'bun-bundle.js'),
  `export function feature() { return false }\n`,
  'utf8',
)
// Some files import ../stubs from nested folders (e.g. src/utils/permissions/*)
await writeStubFile('utils/stubs/bun-bundle.js', `export function feature() { return false }\n`)
await writeStubFile('utils/protectedNamespace.js', `export default {}\n`)
await writeStubFile(
  'entrypoints/sdk/runtimeTypes.js',
  `export {}\n`,
)
await writeStubFile(
  'entrypoints/sdk/toolTypes.js',
  `export {}\n`,
)
await writeStubFile(
  'entrypoints/sdk/coreTypes.generated.js',
  `export {}\n`,
)
await writeStubFile(
  'services/compact/cachedMicrocompact.js',
  `export function consumePendingCacheEdits() { return null }\nexport function getPinnedCacheEdits() { return [] }\nexport function markToolsSentToAPIState() {}\nexport function pinCacheEdits() {}\n`,
)
await writeStubFile('ink/devtools.js', `export {}\n`)
await writeStubFile(
  'utils/filePersistence/types.js',
  `export const DEFAULT_UPLOAD_CONCURRENCY = 4\nexport const FILE_COUNT_LIMIT = 1000\nexport const OUTPUTS_SUBDIR = 'outputs'\n`,
)
await writeStubFile('skills/bundled/verify/examples/cli.md', '')
await writeStubFile('skills/bundled/verify/examples/server.md', '')
await writeStubFile('skills/bundled/verify/SKILL.md', '')
await mkdir(join(BUILD, 'stubs'), { recursive: true })
await writeFile(
  join(BUILD, 'stubs', 'bun-bundle.ts'),
  `export function feature(_flag?: string): boolean { return false }\n`,
  'utf8',
)
console.log('Phase 1: copied src/ -> build-src/')

// Phase 2: transform source
const MACROS = {
  'MACRO.VERSION': `'${VERSION}'`,
  'MACRO.BUILD_TIME': `''`,
  'MACRO.FEEDBACK_CHANNEL': `'https://github.com/anthropics/claude-code/issues'`,
  'MACRO.ISSUES_EXPLAINER': `'https://github.com/anthropics/claude-code/issues/new/choose'`,
  'MACRO.FEEDBACK_CHANNEL_URL': `'https://github.com/anthropics/claude-code/issues'`,
  'MACRO.ISSUES_EXPLAINER_URL': `'https://github.com/anthropics/claude-code/issues/new/choose'`,
  'MACRO.NATIVE_PACKAGE_URL': `'@anthropic-ai/claude-code'`,
  'MACRO.PACKAGE_URL': `'@anthropic-ai/claude-code'`,
  'MACRO.VERSION_CHANGELOG': `''`,
}

let transformCount = 0
for await (const file of walk(join(BUILD, 'src'))) {
  if (!/\.[tj]sx?$/i.test(file)) continue

  let src = await readFile(file, 'utf8')
  let changed = false

  if (/\bfeature\s*\(\s*['"][A-Z_]+['"]\s*\)/.test(src)) {
    src = src.replace(/\bfeature\s*\(\s*['"][A-Z_]+['"]\s*\)/g, 'false')
    changed = true
  }

  for (const [k, v] of Object.entries(MACROS)) {
    if (src.includes(k)) {
      src = src.replaceAll(k, v)
      changed = true
    }
  }

  if (src.includes("from 'bun:bundle'") || src.includes('from "bun:bundle"')) {
    src = src.replace(
      /import\s*\{\s*feature\s*\}\s*from\s*['"]bun:bundle['"];?\n?/g,
      '// feature() replaced with false at build time\n',
    )
    changed = true
  }

  if (src.includes('global.d.ts')) {
    src = src.replace(/import\s*['"][^'"]*global\.d\.ts['"];?\n?/g, '')
    changed = true
  }

  // Some decompiled snapshots have a malformed SHADE_ALPHA literal in
  // src/utils/ansiToPng.ts where multiple entries collapse into one commented
  // line and break parsing. Normalize it to a valid object.
  if (
    src.includes('const SHADE_ALPHA: Record<number, number> = {') &&
    src.includes('0x2591')
  ) {
    const fixedShade = `const SHADE_ALPHA: Record<number, number> = {\n  0x2591: 0.25,\n  0x2592: 0.5,\n  0x2593: 0.75,\n  0x2588: 1.0,\n}`
    const nextFnIndex = src.indexOf('function blitShade(')
    const shadeStart = src.indexOf(
      'const SHADE_ALPHA: Record<number, number> = {',
    )
    if (shadeStart !== -1 && nextFnIndex !== -1 && nextFnIndex > shadeStart) {
      const before = src.slice(0, shadeStart)
      const after = src.slice(nextFnIndex)
      src = `${before}${fixedShade}\n\n${after}`
      changed = true
    }
  }

  // Normalize potentially garbled full-width digit regex in string utils.
  if (
    src.includes('export function normalizeFullWidthDigits(input: string): string') &&
    src.includes('0xfee0')
  ) {
    const fnStart = src.indexOf(
      'export function normalizeFullWidthDigits(input: string): string',
    )
    const nextFn = src.indexOf(
      'export function normalizeFullWidthSpace(input: string): string',
      fnStart,
    )
    if (fnStart !== -1 && nextFn !== -1 && nextFn > fnStart) {
      const before = src.slice(0, fnStart)
      const after = src.slice(nextFn)
      const fixedDigitsFn = `export function normalizeFullWidthDigits(input: string): string {\n  return input.replace(/[０-９]/g, ch =>\n    String.fromCharCode(ch.charCodeAt(0) - 0xfee0),\n  )\n}\n\n`
      src = `${before}export function normalizeFullWidthDigits(input: string): string {\n  return input.replace(/[\\uFF10-\\uFF19]/g, ch =>\n    String.fromCharCode(ch.charCodeAt(0) - 0xfee0),\n  )\n}\n\n${after}`
      changed = true
    }
  }

  // Fix old auto-stub pattern that declares the same symbol twice:
  // export default function X() {}
  // export const X = () => {}
  const duplicateStubPattern =
    /export default function ([A-Za-z_$][\w$]*)\(\)\s*\{\}\s*;?\s*[\r\n]+\s*export const \1 = \(\) => \{\}\s*;?/g
  if (duplicateStubPattern.test(src)) {
    src = src.replace(
      duplicateStubPattern,
      'const $1 = () => {}\nexport { $1 }\nexport default $1',
    )
    changed = true
  }

  if (changed) {
    await writeFile(file, src, 'utf8')
    transformCount++
  }
}
console.log(`Phase 2: transformed ${transformCount} files`)

// Phase 3: entry wrapper
await writeFile(
  ENTRY,
  `#!/usr/bin/env node\n// Claude Code v${VERSION} built from source\nimport './src/entrypoints/cli.tsx'\n`,
  'utf8',
)
await writeFile(
  BUILD_TSCONFIG,
  JSON.stringify(
    {
      compilerOptions: {
        target: 'ES2022',
        module: 'ESNext',
        moduleResolution: 'bundler',
        baseUrl: '.',
        paths: {
          'src/*': ['src/*'],
          'bun:bundle': ['stubs/bun-bundle.ts'],
        },
      },
      include: ['src/**/*', 'stubs/**/*'],
    },
    null,
    2,
  ) + '\n',
  'utf8',
)
console.log('Phase 3: created entry wrapper')

// Phase 4: bundle + iterative stubs
await ensureEsbuild()
await mkdir(DIST, { recursive: true })

const MAX_ROUNDS = 5
let success = false

for (let round = 1; round <= MAX_ROUNDS; round++) {
  console.log(`Phase 4: bundling round ${round}/${MAX_ROUNDS}...`)
  try {
    bundleOnce()
    success = true
    break
  } catch (error) {
    const stderr = error?.stderr?.toString?.() || ''
    const stdout = error?.stdout?.toString?.() || ''
    const output = `${stderr}${stdout}`
    const missing = parseMissingModules(output)

    if (missing.size === 0) {
      const errLines = output
        .split('\n')
        .filter(line => line.includes('ERROR'))
        .slice(0, 8)
      console.log('No resolvable missing-module errors left. Sample errors:')
      for (const line of errLines) {
        console.log(`  ${line}`)
      }
      break
    }

    let created = 0
    for (const mod of missing) {
      created += await createStubForModule(mod)
    }
    console.log(`Created ${created} stubs for ${missing.size} missing modules.`)
  }
}

if (!success) {
  console.error('Build failed after all rounds.')
  process.exit(1)
}

const size = (await stat(OUT_FILE)).size
console.log(`Build succeeded: ${OUT_FILE}`)
console.log(`Output size: ${(size / 1024 / 1024).toFixed(1)} MB`)
