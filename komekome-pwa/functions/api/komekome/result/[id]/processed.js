// PUT: WSL2 が処理済みマークを設定

const ALLOWED_ORIGIN = "https://komekome.pages.dev";

function corsHeaders(request) {
  const origin = request?.headers?.get("Origin") || "";
  const allowed = origin === ALLOWED_ORIGIN || origin === "" ? ALLOWED_ORIGIN : origin;
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Methods": "PUT, OPTIONS",
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

export async function onRequestPut(context) {
  const { request, env, params } = context;
  if (!verifyToken(request, env)) return unauthorized(request);

  const sessionId = params.id;
  const key = `result:${sessionId}`;

  const data = await env.KOMEKOME_STORE.get(key, "json");
  if (!data) {
    return json({ error: "Not found" }, 404, request);
  }

  data.processed = true;
  data.processed_at = new Date().toISOString();
  await env.KOMEKOME_STORE.put(key, JSON.stringify(data));

  return json({ ok: true, session_id: sessionId }, 200, request);
}

export async function onRequestOptions(context) {
  return new Response(null, {
    headers: corsHeaders(context.request),
  });
}
