import type Anthropic from '@anthropic-ai/sdk'
import type {
  BetaMessage,
  BetaMessageDeltaUsage,
  BetaMessageParam,
  BetaMessageStreamParams,
  BetaRawMessageStreamEvent,
  BetaToolChoiceAuto,
  BetaToolChoiceTool,
  BetaToolUnion,
} from '@anthropic-ai/sdk/resources/beta/messages/messages.mjs'
import type { ClientOptions } from '@anthropic-ai/sdk'
import { randomUUID } from 'crypto'
import axios from 'axios'
import {
  createAxiosInstance,
  getProxyFetchOptions,
  getProxyUrl,
} from 'src/utils/proxy.js'

type OpenAICompatClientOptions = {
  fetchFn: ClientOptions['fetch']
  defaultHeaders?: Record<string, string>
  maxRetries?: number
}

type CompatRequestOptions = {
  signal?: AbortSignal
  headers?: Record<string, string>
}

type OpenAIChatMessage = {
  role: 'system' | 'user' | 'assistant' | 'tool'
  content?: string | null
  tool_call_id?: string
  tool_calls?: Array<{
    id: string
    type: 'function'
    function: { name: string; arguments: string }
  }>
}

function compatDebugEnabled(): boolean {
  const raw = process.env.OPENAI_COMPAT_DEBUG || ''
  return ['1', 'true', 'yes', 'on'].includes(raw.toLowerCase())
}

function compatDebug(message: string, extra?: unknown): void {
  if (!compatDebugEnabled()) return
  if (extra === undefined) {
    // eslint-disable-next-line no-console
    console.error(`[openai-compat] ${message}`)
    return
  }
  try {
    // eslint-disable-next-line no-console
    console.error(
      `[openai-compat] ${message}: ${JSON.stringify(extra).slice(0, 1000)}`,
    )
  } catch {
    // eslint-disable-next-line no-console
    console.error(`[openai-compat] ${message}`)
  }
}

function getOpenAIBaseUrl(): string {
  const raw =
    process.env.OPENAI_BASE_URL ||
    process.env.OPENAI_COMPAT_BASE_URL ||
    process.env.ANTHROPIC_BASE_URL ||
    'https://api.openai.com/v1'
  return raw.replace(/\/+$/, '')
}

function getOpenAIApiKey(): string | undefined {
  return process.env.OPENAI_API_KEY || process.env.ANTHROPIC_API_KEY
}

function getOpenAICompatRequestTimeoutMs(): number {
  const raw =
    process.env.OPENAI_COMPAT_REQUEST_TIMEOUT_MS ||
    process.env.API_TIMEOUT_MS ||
    '45000'
  const parsed = Number.parseInt(raw, 10)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return 45000
  }
  return parsed
}

function safeParseJsonObject(input: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(input)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    // Fall through.
  }
  return {}
}

function blockToText(block: unknown): string {
  if (typeof block === 'string') {
    return block
  }
  if (!block || typeof block !== 'object') {
    return ''
  }
  const maybeBlock = block as Record<string, unknown>
  if (typeof maybeBlock.text === 'string') {
    return maybeBlock.text
  }
  if (typeof maybeBlock.content === 'string') {
    return maybeBlock.content
  }
  return ''
}

function toolResultContentToText(content: unknown): string {
  if (typeof content === 'string') {
    return content
  }
  if (Array.isArray(content)) {
    const text = content.map(blockToText).filter(Boolean).join('\n')
    if (text) return text
  }
  try {
    return JSON.stringify(content)
  } catch {
    return String(content)
  }
}

function anthropicMessagesToOpenAI(
  messages: BetaMessageParam[],
): OpenAIChatMessage[] {
  const output: OpenAIChatMessage[] = []

  for (const message of messages) {
    if (typeof message.content === 'string') {
      output.push({
        role:
          message.role === 'assistant' || message.role === 'user'
            ? message.role
            : 'user',
        content: message.content,
      })
      continue
    }

    const blocks = message.content ?? []

    if (message.role === 'assistant') {
      const textParts: string[] = []
      const toolCalls: NonNullable<OpenAIChatMessage['tool_calls']> = []
      for (const block of blocks) {
        const typed = block as Record<string, unknown>
        const type = typed.type
        if (type === 'text' && typeof typed.text === 'string') {
          textParts.push(typed.text)
        } else if (type === 'tool_use') {
          const name = typeof typed.name === 'string' ? typed.name : 'tool'
          const id =
            typeof typed.id === 'string' && typed.id
              ? typed.id
              : `toolu_${randomUUID()}`
          const input = typed.input ?? {}
          toolCalls.push({
            id,
            type: 'function',
            function: {
              name,
              arguments: JSON.stringify(input),
            },
          })
        }
      }

      if (textParts.length > 0 || toolCalls.length > 0) {
        output.push({
          role: 'assistant',
          content: textParts.length > 0 ? textParts.join('\n') : null,
          ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
        })
      }
      continue
    }

    // user message: split text and tool_result into OpenAI-compatible shape
    const textParts: string[] = []
    const flushUserText = () => {
      if (textParts.length === 0) return
      output.push({
        role: 'user',
        content: textParts.join('\n'),
      })
      textParts.length = 0
    }

    for (const block of blocks) {
      const typed = block as Record<string, unknown>
      const type = typed.type
      if (type === 'text') {
        if (typeof typed.text === 'string') {
          textParts.push(typed.text)
        }
        continue
      }
      if (type === 'tool_result') {
        flushUserText()
        const toolUseId =
          typeof typed.tool_use_id === 'string' ? typed.tool_use_id : ''
        output.push({
          role: 'tool',
          tool_call_id: toolUseId || `toolu_${randomUUID()}`,
          content: toolResultContentToText(typed.content),
        })
        continue
      }
      const fallbackText = blockToText(block)
      if (fallbackText) {
        textParts.push(fallbackText)
      }
    }
    flushUserText()
  }

  return output
}

function systemPromptToMessage(
  system: BetaMessageStreamParams['system'],
): OpenAIChatMessage | null {
  if (!system) return null
  if (typeof system === 'string') {
    return { role: 'system', content: system }
  }
  const text = system
    .map(block => (typeof block.text === 'string' ? block.text : ''))
    .filter(Boolean)
    .join('\n')
  return text ? { role: 'system', content: text } : null
}

function anthropicToolsToOpenAI(
  tools: BetaToolUnion[] | undefined,
): Array<{
  type: 'function'
  function: {
    name: string
    description?: string
    parameters: Record<string, unknown>
  }
}> {
  if (!tools || tools.length === 0) return []
  return tools
    .filter(tool => tool.type === 'custom')
    .map(tool => ({
      type: 'function' as const,
      function: {
        name: tool.name,
        ...(tool.description ? { description: tool.description } : {}),
        parameters: (tool.input_schema as Record<string, unknown>) ?? {
          type: 'object',
          properties: {},
        },
      },
    }))
}

function mapToolChoice(
  toolChoice: BetaToolChoiceAuto | BetaToolChoiceTool | undefined,
): 'auto' | 'required' | { type: 'function'; function: { name: string } } {
  if (!toolChoice) return 'auto'
  if (toolChoice.type === 'tool') {
    return { type: 'function', function: { name: toolChoice.name } }
  }
  if (toolChoice.type === 'any') {
    return 'required'
  }
  return 'auto'
}

function mapStopReason(
  finishReason: string | null | undefined,
  hasToolCalls: boolean,
): 'end_turn' | 'tool_use' | 'max_tokens' | null {
  if (hasToolCalls) return 'tool_use'
  if (finishReason === 'length') return 'max_tokens'
  if (finishReason === 'stop') return 'end_turn'
  return 'end_turn'
}

function buildUsage(usage: {
  prompt_tokens?: number
  completion_tokens?: number
}): BetaMessageDeltaUsage {
  return {
    input_tokens: usage.prompt_tokens ?? 0,
    output_tokens: usage.completion_tokens ?? 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    server_tool_use: {
      web_search_requests: 0,
      web_fetch_requests: 0,
    },
  }
}

function openAIResponseToBetaMessage(
  response: any,
  model: string,
): BetaMessage {
  if (!Array.isArray(response?.choices) || response.choices.length === 0) {
    const preview = JSON.stringify(response)?.slice(0, 500) ?? ''
    throw new Error(
      `OpenAI-compatible response missing choices. Response preview: ${preview}`,
    )
  }

  const choice = response?.choices?.[0] ?? {}
  const message = choice.message ?? {}
  const toolCalls: any[] = Array.isArray(message.tool_calls)
    ? message.tool_calls
    : []
  const contentBlocks: Array<Record<string, unknown>> = []

  if (typeof message.content === 'string' && message.content) {
    contentBlocks.push({
      type: 'text',
      text: message.content,
    })
  }

  for (const toolCall of toolCalls) {
    const id =
      typeof toolCall?.id === 'string' && toolCall.id
        ? toolCall.id
        : `toolu_${randomUUID()}`
    const name =
      typeof toolCall?.function?.name === 'string'
        ? toolCall.function.name
        : 'tool'
    const args =
      typeof toolCall?.function?.arguments === 'string'
        ? toolCall.function.arguments
        : '{}'
    contentBlocks.push({
      type: 'tool_use',
      id,
      name,
      input: safeParseJsonObject(args),
    })
  }

  const stopReason = mapStopReason(choice.finish_reason, toolCalls.length > 0)
  const usage = buildUsage(response?.usage ?? {})

  if (contentBlocks.length === 0) {
    const preview = JSON.stringify(choice)?.slice(0, 500) ?? ''
    throw new Error(
      `OpenAI-compatible response has empty message content/tool_calls. Choice preview: ${preview}`,
    )
  }

  return {
    id: response?.id || `msg_${randomUUID()}`,
    type: 'message',
    role: 'assistant',
    model,
    content: contentBlocks as BetaMessage['content'],
    stop_reason: stopReason,
    stop_sequence: null,
    usage: usage as BetaMessage['usage'],
  } as BetaMessage
}

function createSyntheticStreamEvents(
  message: BetaMessage,
): BetaRawMessageStreamEvent[] {
  const usage = (message.usage ?? buildUsage({})) as BetaMessageDeltaUsage
  const events: BetaRawMessageStreamEvent[] = []

  events.push({
    type: 'message_start',
    message: {
      ...message,
      content: [],
      usage: {
        ...usage,
        output_tokens: 0,
      } as BetaMessage['usage'],
      stop_reason: null,
    } as BetaMessage,
  } as BetaRawMessageStreamEvent)

  message.content.forEach((block, index) => {
    if (block.type === 'text') {
      events.push({
        type: 'content_block_start',
        index,
        content_block: {
          type: 'text',
          text: '',
        },
      } as BetaRawMessageStreamEvent)
      events.push({
        type: 'content_block_delta',
        index,
        delta: {
          type: 'text_delta',
          text: block.text,
        },
      } as BetaRawMessageStreamEvent)
      events.push({
        type: 'content_block_stop',
        index,
      } as BetaRawMessageStreamEvent)
      return
    }

    if (block.type === 'tool_use') {
      events.push({
        type: 'content_block_start',
        index,
        content_block: {
          type: 'tool_use',
          id: block.id,
          name: block.name,
          input: '',
        },
      } as BetaRawMessageStreamEvent)
      events.push({
        type: 'content_block_delta',
        index,
        delta: {
          type: 'input_json_delta',
          partial_json: JSON.stringify(block.input ?? {}),
        },
      } as BetaRawMessageStreamEvent)
      events.push({
        type: 'content_block_stop',
        index,
      } as BetaRawMessageStreamEvent)
    }
  })

  events.push({
    type: 'message_delta',
    delta: {
      stop_reason: message.stop_reason ?? 'end_turn',
      stop_sequence: null,
    },
    usage,
  } as BetaRawMessageStreamEvent)

  events.push({
    type: 'message_stop',
  } as BetaRawMessageStreamEvent)

  return events
}

async function requestOpenAIChatCompletions(
  params: BetaMessageStreamParams,
  requestOptions: CompatRequestOptions | undefined,
  options: OpenAICompatClientOptions,
): Promise<{ data: any; response: Response }> {
  const baseUrl = getOpenAIBaseUrl()
  const apiKey = getOpenAIApiKey()
  const fetchFn = options.fetchFn ?? globalThis.fetch
  const headers = new Headers(options.defaultHeaders)
  headers.set('Content-Type', 'application/json')
  if (apiKey && !headers.has('Authorization')) {
    headers.set('Authorization', `Bearer ${apiKey}`)
  }
  if (requestOptions?.headers) {
    for (const [key, value] of Object.entries(requestOptions.headers)) {
      headers.set(key, value)
    }
  }

  const openaiMessages = anthropicMessagesToOpenAI(params.messages)
  const systemMessage = systemPromptToMessage(params.system)
  const body: Record<string, unknown> = {
    model: params.model,
    messages: systemMessage
      ? [systemMessage, ...openaiMessages]
      : openaiMessages,
    max_completion_tokens: params.max_tokens,
    temperature: params.temperature,
    stream: false,
  }

  const tools = anthropicToolsToOpenAI(params.tools)
  if (tools.length > 0) {
    body.tools = tools
    body.tool_choice = mapToolChoice(
      params.tool_choice as BetaToolChoiceAuto | BetaToolChoiceTool | undefined,
    )
  }

  compatDebug('request', {
    url: `${baseUrl}/chat/completions`,
    model: params.model,
    message_count: openaiMessages.length + (systemMessage ? 1 : 0),
    has_tools: tools.length > 0,
  })

  const timeoutMs = getOpenAICompatRequestTimeoutMs()
  const timeoutController = new AbortController()
  const timeoutHandle = setTimeout(() => {
    timeoutController.abort(
      new Error(`OpenAI-compatible request timed out after ${timeoutMs}ms`),
    )
  }, timeoutMs)
  const externalSignal = requestOptions?.signal
  const onExternalAbort = () =>
    timeoutController.abort(
      externalSignal?.reason ?? new Error('OpenAI-compatible request aborted'),
    )
  if (externalSignal) {
    if (externalSignal.aborted) {
      onExternalAbort()
    } else {
      externalSignal.addEventListener('abort', onExternalAbort, {
        once: true,
      })
    }
  }

  let response: Response
  try {
    response = await fetchFn(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      ...(getProxyFetchOptions({
        forAnthropicAPI: true,
      }) as Record<string, unknown>),
      signal: timeoutController.signal,
    }).catch(async err => {
      if (timeoutController.signal.aborted && !externalSignal?.aborted) {
        throw new Error(
          `OpenAI-compatible request timed out after ${timeoutMs}ms`,
        )
      }
      const hasProxy = !!getProxyUrl()
      if (!hasProxy) throw err

      compatDebug('fetch failed, trying axios fallback', {
        message: err instanceof Error ? err.message : String(err),
      })
      const client = createAxiosInstance()
      const axiosResp = await client.post(`${baseUrl}/chat/completions`, body, {
        headers: Object.fromEntries(headers.entries()),
        timeout: timeoutMs,
        validateStatus: () => true,
        signal: timeoutController.signal,
      })
      const fallbackHeaders = new Headers()
      for (const [k, v] of Object.entries(axiosResp.headers ?? {})) {
        if (typeof v === 'string') fallbackHeaders.set(k, v)
      }
      return new Response(JSON.stringify(axiosResp.data), {
        status: axiosResp.status,
        headers: fallbackHeaders,
      })
    })
  } finally {
    clearTimeout(timeoutHandle)
    externalSignal?.removeEventListener('abort', onExternalAbort)
  }

  if (!response.ok) {
    const errText = await response.text().catch(() => '')
    throw new Error(
      `OpenAI-compatible request failed (${response.status}): ${errText || response.statusText}`,
    )
  }

  const data = await response.json()
  compatDebug('response', {
    id: data?.id,
    model: data?.model,
    has_choices: Array.isArray(data?.choices),
    choice_count: Array.isArray(data?.choices) ? data.choices.length : 0,
    first_choice: data?.choices?.[0],
  })

  return {
    data,
    response,
  }
}

function createSyntheticStream(
  message: BetaMessage,
  signal?: AbortSignal,
): {
  controller: AbortController
  [Symbol.asyncIterator](): AsyncIterator<BetaRawMessageStreamEvent>
} {
  const controller = new AbortController()
  if (signal) {
    if (signal.aborted) {
      controller.abort()
    } else {
      signal.addEventListener('abort', () => controller.abort(), {
        once: true,
      })
    }
  }
  const iterator = async function* () {
    const events = createSyntheticStreamEvents(message)
    for (const event of events) {
      if (controller.signal.aborted) {
        throw new Error('OpenAI-compatible stream aborted')
      }
      yield event
    }
  }

  return {
    controller,
    [Symbol.asyncIterator]: iterator,
  }
}

function createLazySyntheticStream(
  params: BetaMessageStreamParams,
  requestOptions: CompatRequestOptions | undefined,
  options: OpenAICompatClientOptions,
): {
  controller: AbortController
  [Symbol.asyncIterator](): AsyncIterator<BetaRawMessageStreamEvent>
} {
  const controller = new AbortController()
  if (requestOptions?.signal) {
    if (requestOptions.signal.aborted) {
      controller.abort()
    } else {
      requestOptions.signal.addEventListener('abort', () => controller.abort(), {
        once: true,
      })
    }
  }
  const iterator = async function* () {
    const { data } = await requestOpenAIChatCompletions(
      params,
      {
        ...requestOptions,
        signal: controller.signal,
      },
      options,
    )
    const betaMessage = openAIResponseToBetaMessage(data, params.model)
    const events = createSyntheticStreamEvents(betaMessage)
    for (const event of events) {
      if (controller.signal.aborted) {
        throw new Error('OpenAI-compatible stream aborted')
      }
      yield event
    }
  }
  return {
    controller,
    [Symbol.asyncIterator]: iterator,
  }
}

function estimateTokens(messages: BetaMessageParam[]): number {
  const content = messages
    .map(message =>
      typeof message.content === 'string'
        ? message.content
        : (message.content ?? []).map(blockToText).join('\n'),
    )
    .join('\n')
  // Approximation: average 1 token ~= 4 chars for mixed English/code.
  return Math.max(1, Math.ceil(content.length / 4))
}

export function createOpenAICompatibleAnthropicClient(
  options: OpenAICompatClientOptions,
): Anthropic {
  const client = {
    beta: {
      messages: {
        create: (
          params: BetaMessageStreamParams,
          requestOptions?: CompatRequestOptions,
        ) => {
          const isStreaming = Boolean((params as { stream?: boolean }).stream)
          if (isStreaming) {
            return {
              withResponse: async () => {
                const { data, response } = await requestOpenAIChatCompletions(
                  params,
                  requestOptions,
                  options,
                )
                const betaMessage = openAIResponseToBetaMessage(
                  data,
                  params.model,
                )
                return {
                  data: createSyntheticStream(
                    betaMessage,
                    requestOptions?.signal,
                  ),
                  response,
                  request_id:
                    response.headers.get('x-request-id') || randomUUID(),
                }
              },
            }
          }
          return (async () => {
            const { data } = await requestOpenAIChatCompletions(
              params,
              requestOptions,
              options,
            )
            return openAIResponseToBetaMessage(data, params.model)
          })()
        },
        stream: (
          params: BetaMessageStreamParams,
          requestOptions?: CompatRequestOptions,
        ): {
          controller: AbortController
          [Symbol.asyncIterator](): AsyncIterator<BetaRawMessageStreamEvent>
        } => createLazySyntheticStream(params, requestOptions, options),
        countTokens: async ({
          messages,
        }: {
          messages: BetaMessageParam[]
        }): Promise<{ input_tokens: number }> => ({
          input_tokens: estimateTokens(messages),
        }),
      },
    },
  }
  return client as unknown as Anthropic
}
