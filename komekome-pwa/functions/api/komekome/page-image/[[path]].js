// GET: Serve page image from R2
// Path: /api/komekome/page-image/<book>/<page>.webp

const ALLOWED_ORIGIN = "https://komekome.pages.dev";

function corsHeaders(request) {
  const origin = request?.headers?.get("Origin") || "";
  const allowed = origin === ALLOWED_ORIGIN || origin === "" ? ALLOWED_ORIGIN : origin;
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization",
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
  const { request, env, params } = context;
  if (!verifyToken(request, env)) return unauthorized(request);

  const pathParts = params.path;
  if (!pathParts || pathParts.length === 0) {
    return json({ error: "Path required" }, 400, request);
  }

  const key = pathParts.join("/");
  const object = await env.KOMEKOME_PAGES.get(key);

  if (!object) {
    return json({ error: "Not found" }, 404, request);
  }

  return new Response(object.body, {
    headers: {
      "Content-Type": "image/webp",
      "Cache-Control": "public, max-age=31536000, immutable",
      ...corsHeaders(request),
    },
  });
}

export async function onRequestOptions(context) {
  return new Response(null, { headers: corsHeaders(context.request) });
}
