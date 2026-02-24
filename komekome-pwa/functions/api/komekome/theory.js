// GET: PWA fetches theory ○× question bank
// POST: WSL pushes theory questions

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

  const data = await env.KOMEKOME_STORE.get("theory_bank", "json");
  if (!data) {
    return json({ version: 0, total: 0, questions: [] }, 200, request);
  }
  return json(data, 200, request);
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

  if (!body || typeof body !== "object" || !Array.isArray(body.questions)) {
    return json({ error: "Request body must contain questions array" }, 400, request);
  }

  await env.KOMEKOME_STORE.put("theory_bank", JSON.stringify(body));

  return json({ ok: true, total: body.questions.length, stored_at: new Date().toISOString() }, 200, request);
}

export async function onRequestOptions(context) {
  return new Response(null, { headers: corsHeaders(context.request) });
}
