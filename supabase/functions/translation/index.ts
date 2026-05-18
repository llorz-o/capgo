import sourceMessages from '../messages/en.json' with { type: 'json' }
import { createAllCatch, createHono, useCors } from '../_backend/utils/hono.ts'
import { version } from '../_backend/utils/version.ts'

const SUPPORTED_LANGUAGES = new Set([
  'de',
  'en',
  'es',
  'fr',
  'hi',
  'id',
  'it',
  'ja',
  'ko',
  'pl',
  'pt',
  'pt-br',
  'ru',
  'tr',
  'vi',
  'zh',
  'zh-cn',
])

const functionName = 'translation'
const appGlobal = createHono(functionName, version)

appGlobal.use('*', useCors)

/** Self-hosted: no Workers AI — return bundled English catalog so the console can boot. */
appGlobal.post('/messages', async (c) => {
  const body = await c.req.json().catch(() => ({})) as { targetLanguage?: string }
  const targetLanguage = typeof body.targetLanguage === 'string' ? body.targetLanguage.trim().toLowerCase() : ''
  if (!SUPPORTED_LANGUAGES.has(targetLanguage)) {
    return c.json({ error: 'unsupported_translation_language' }, 400)
  }
  if (targetLanguage === 'en') {
    return c.json({ error: 'English messages are already bundled' }, 400)
  }

  return c.json({
    checksum: 'self-hosted-en-fallback',
    model: 'self-hosted',
    status: 'ready',
    messages: sourceMessages as Record<string, string>,
  })
})

createAllCatch(appGlobal, functionName)
Deno.serve(appGlobal.fetch)
