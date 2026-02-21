// GET: PWA fetches weekly schedule
// PUT: PWA updates weekly schedule
// POST: WSL pushes weekly schedule

const ALLOWED_ORIGIN = "https://komekome.pages.dev";

function corsHeaders(request) {
  const origin = request?.headers?.get("Origin") || "";
  const allowed = origin === ALLOWED_ORIGIN || origin === "" ? ALLOWED_ORIGIN : origin;
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Methods": "GET, PUT, POST, OPTIONS",
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

  const data = await env.KOMEKOME_STORE.get("weekly_schedule", "json");
  if (!data) {
    return json({ week_start: "", scope_categories: [], updated_at: null }, 200, request);
  }
  return json(data, 200, request);
}

export async function onRequestPut(context) {
  const { request, env } = context;
  if (!verifyToken(request, env)) return unauthorized(request);

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400, request);
  }

  if (!body || typeof body !== "object") {
    return json({ error: "Request body must be an object" }, 400, request);
  }

  body.updated_at = new Date().toISOString();
  await env.KOMEKOME_STORE.put("weekly_schedule", JSON.stringify(body));

  return json({ ok: true, stored_at: body.updated_at }, 200, request);
}

export async function onRequestPost(context) {
  // POST behaves the same as PUT (for WSL push compatibility)
  return onRequestPut(context);
}

export async function onRequestOptions(context) {
  return new Response(null, { headers: corsHeaders(context.request) });
}
