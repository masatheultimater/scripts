// POST: PWA がセッション結果を保存
// GET: WSL2 が未処理結果を一覧取得

const ALLOWED_ORIGIN = "https://komekome.pages.dev";

function corsHeaders(request) {
  const origin = request?.headers?.get("Origin") || "";
  const allowed = origin === ALLOWED_ORIGIN || origin === "" ? ALLOWED_ORIGIN : origin;
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
  };
}

function unauthorized(request) {
  return new Response(JSON.stringify({ error: "Unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json", ...corsHeaders(request) },
  });
}

function json(data, status = 200, request) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(request) },
  });
}

function verifyToken(request, env) {
  const auth = request.headers.get("Authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "");
  return token && token === env.API_TOKEN;
}

export async function onRequestPost(context) {
  const { request, env } = context;
  if (!verifyToken(request, env)) return unauthorized(request);

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400, request);
  }

  if (!body || typeof body !== "object") {
    return json({ error: "Request body must be a JSON object" }, 400, request);
  }

  const sessionId = body.session_id || `s_${Date.now().toString(36)}`;
  const key = `result:${sessionId}`;

  const record = {
    ...body,
    session_id: sessionId,
    processed: false,
    stored_at: new Date().toISOString(),
  };

  await env.KOMEKOME_STORE.put(key, JSON.stringify(record));

  return json({ ok: true, session_id: sessionId }, 200, request);
}

export async function onRequestGet(context) {
  const { request, env } = context;
  if (!verifyToken(request, env)) return unauthorized(request);

  // KV list with prefix "result:"
  const list = await env.KOMEKOME_STORE.list({ prefix: "result:" });
  const results = [];

  for (const key of list.keys) {
    const data = await env.KOMEKOME_STORE.get(key.name, "json");
    if (data && !data.processed) {
      results.push(data);
    }
  }

  return json({ results }, 200, request);
}

export async function onRequestOptions(context) {
  return new Response(null, {
    headers: corsHeaders(context.request),
  });
}
