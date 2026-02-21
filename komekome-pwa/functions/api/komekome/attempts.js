// GET: Retrieve all attempts
// POST: Add new attempts (append)

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

export async function onRequestGet(context) {
  const { request, env } = context;
  if (!verifyToken(request, env)) return unauthorized(request);

  const data = await env.KOMEKOME_STORE.get("attempts_all", "json");
  return json({ attempts: data || [] }, 200, request);
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

  const newAttempts = Array.isArray(body) ? body : body.attempts;
  if (!Array.isArray(newAttempts) || newAttempts.length === 0) {
    return json({ error: "Must provide attempts array" }, 400, request);
  }

  // Read existing, append, write back
  const existing = (await env.KOMEKOME_STORE.get("attempts_all", "json")) || [];
  // Deduplicate by attempt id
  const existingIds = new Set(existing.map(a => a.id));
  const toAdd = newAttempts.filter(a => a.id && !existingIds.has(a.id));
  const merged = [...existing, ...toAdd];

  await env.KOMEKOME_STORE.put("attempts_all", JSON.stringify(merged));

  return json({ ok: true, added: toAdd.length, total: merged.length }, 200, request);
}

export async function onRequestOptions(context) {
  return new Response(null, { headers: corsHeaders(context.request) });
}
