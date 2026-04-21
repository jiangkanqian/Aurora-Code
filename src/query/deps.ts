import { randomUUID } from 'crypto'
import {
  queryModelWithStreaming,
  queryModelWithoutStreaming,
} from '../services/api/claude.js'
import { autoCompactIfNeeded } from '../services/compact/autoCompact.js'
import { microcompactMessages } from '../services/compact/microCompact.js'

// -- deps

// I/O dependencies for query(). Passing a `deps` override into QueryParams
// lets tests inject fakes directly instead of spyOn-per-module — the most
// common mocks (callModel, autocompact) are each spied in 6-8 test files
// today with module-import-and-spy boilerplate.
//
// Using `typeof fn` keeps signatures in sync with the real implementations
// automatically. This file imports the real functions for both typing and
// the production factory — tests that import this file for typing are
// already importing query.ts (which imports everything), so there's no
// new module-graph cost.
//
// Scope is intentionally narrow (4 deps) to prove the pattern. Followup
// PRs can add runTools, handleStopHooks, logEvent, queue ops, etc.
export type QueryDeps = {
  // -- model
  callModel: typeof queryModelWithStreaming

  // -- compaction
  microcompact: typeof microcompactMessages
  autocompact: typeof autoCompactIfNeeded

  // -- platform
  uuid: () => string
}

function isEnvTruthy(value: string | undefined): boolean {
  if (!value) return false
  const normalized = value.trim().toLowerCase()
  return (
    normalized === '1' ||
    normalized === 'true' ||
    normalized === 'yes' ||
    normalized === 'on'
  )
}

async function* queryModelWithoutStreamingAdapter(
  params: Parameters<typeof queryModelWithStreaming>[0],
): ReturnType<typeof queryModelWithStreaming> {
  const assistant = await queryModelWithoutStreaming(params)
  yield assistant
}

export function productionDeps(): QueryDeps {
  const isCompatMode = isEnvTruthy(process.env.CLAUDE_CODE_USE_OPENAI_COMPAT)
  const allowCompatStreaming = isEnvTruthy(
    process.env.CLAUDE_CODE_OPENAI_COMPAT_ALLOW_STREAMING,
  )
  const forceNonStreaming = isEnvTruthy(
    process.env.CLAUDE_CODE_FORCE_NON_STREAMING,
  )
  const shouldUseNonStreamingModelPath =
    forceNonStreaming || (isCompatMode && !allowCompatStreaming)

  return {
    callModel: shouldUseNonStreamingModelPath
      ? queryModelWithoutStreamingAdapter
      : queryModelWithStreaming,
    microcompact: microcompactMessages,
    autocompact: autoCompactIfNeeded,
    uuid: randomUUID,
  }
}
