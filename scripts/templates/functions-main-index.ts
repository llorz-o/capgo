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
      // 4c8g 自托管：60s 回收会让 worker 每分钟集体重建，
      // 并发 spawn isolate 抢满 CPU 后触发 InvalidWorkerCreation → 504。
      // 拉长存活周期以降低冷启动频率；上游 Supabase 模板默认即 5 分钟。
      memoryLimitMb: 256,
      workerTimeoutMs: 10 * 60 * 1000,
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
