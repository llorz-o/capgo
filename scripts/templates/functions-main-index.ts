console.log('Capgo main router started')

const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'

Deno.serve(async (req: Request) => {
  if (req.method !== 'OPTIONS' && VERIFY_JWT) {
    return new Response(JSON.stringify({ msg: 'JWT verification enabled but not configured in this main router' }), {
      status: 501,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const url = new URL(req.url)
  const pathParts = url.pathname.split('/').filter(Boolean)
  const serviceName = pathParts[0]

  if (!serviceName) {
    return new Response(JSON.stringify({ msg: 'missing function name in request' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${serviceName}`
  const importMapPath = '/home/deno/functions/deno.capgo.json'
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb: 150,
      workerTimeoutMs: 60 * 1000,
      noModuleCache: false,
      importMapPath,
      envVars,
    })
    return await worker.fetch(req)
  } catch (e) {
    console.error('worker error', e)
    return new Response(JSON.stringify({ msg: e.toString() }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
