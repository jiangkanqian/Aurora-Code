import colorDiffNapi, { type SyntaxTheme } from 'color-diff-napi'
import { isEnvDefinedFalsy } from '../../utils/envUtils.js'

const colorDiffModule = ((colorDiffNapi as any)?.default ?? colorDiffNapi ?? {}) as {
  ColorDiff?: any
  ColorFile?: any
  getSyntaxTheme?: (themeName: string) => SyntaxTheme
}

const ColorDiff = colorDiffModule.ColorDiff
const ColorFile = colorDiffModule.ColorFile
const nativeGetSyntaxTheme = colorDiffModule.getSyntaxTheme

export type ColorModuleUnavailableReason = 'env' | 'missing'

/**
 * Returns a static reason why the color-diff module is unavailable, or null if available.
 * 'env' = disabled via CLAUDE_CODE_SYNTAX_HIGHLIGHT
 *
 * The TS port of color-diff works in all build modes, so the only way to
 * disable it is via the env var.
 */
export function getColorModuleUnavailableReason(): ColorModuleUnavailableReason | null {
  if (isEnvDefinedFalsy(process.env.CLAUDE_CODE_SYNTAX_HIGHLIGHT)) {
    return 'env'
  }
  if (!ColorDiff || !ColorFile || typeof nativeGetSyntaxTheme !== 'function') {
    return 'missing'
  }
  return null
}

export function expectColorDiff(): typeof ColorDiff | null {
  return getColorModuleUnavailableReason() === null ? ColorDiff : null
}

export function expectColorFile(): typeof ColorFile | null {
  return getColorModuleUnavailableReason() === null ? ColorFile : null
}

export function getSyntaxTheme(themeName: string): SyntaxTheme | null {
  return getColorModuleUnavailableReason() === null
    ? nativeGetSyntaxTheme(themeName)
    : null
}
