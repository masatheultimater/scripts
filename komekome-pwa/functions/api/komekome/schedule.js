// GET: PWA fetches weekly schedule
// PUT: PWA updates weekly schedule + regenerate today_problems
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

// ── Smart problem selection ──

function todayStr() {
  const d = new Date();
  return d.toISOString().slice(0, 10);
}

function scoreProblem(problem, attemptStats) {
  const stat = attemptStats[problem.id] || { wrong: 0, correct: 0, total: 0, lastDate: "" };
  const rankScore = problem.rank === "A" ? 30 : problem.rank === "B" ? 20 : 10;
  // Priority: 未着手 > 間違い多い > ランクA > 日が空いた
  const unattemptedBonus = stat.total === 0 ? 10000 : 0;
  const wrongScore = Math.min(stat.wrong, 20) * 100; // max 2000, stronger weak prioritization
  const wrongGap = Math.max(stat.wrong - stat.correct, 0);
  const wrongGapBonus = Math.min(wrongGap, 10) * 50; // max 500
  const today = todayStr();
  let daysSinceLast = 30;
  if (stat.lastDate) {
    const diff = (new Date(today) - new Date(stat.lastDate)) / 86400000;
    daysSinceLast = Math.max(0, Math.min(diff, 30));
  }
  return unattemptedBonus + wrongScore + wrongGapBonus + rankScore + daysSinceLast;
}

function buildAttemptStats(attempts) {
  const stats = {};
  for (const a of attempts) {
    const pid = a.problem_id;
    if (!stats[pid]) stats[pid] = { wrong: 0, correct: 0, total: 0, lastDate: "" };
    stats[pid].total++;
    if (a.result === "○") stats[pid].correct++;
    else stats[pid].wrong++;
    if (a.date > stats[pid].lastDate) stats[pid].lastDate = a.date;
  }
  return stats;
}

function selectProblems(problems, categories, attemptStats, calcCount, theoryCount) {
  // Filter by categories
  const catSet = new Set(categories);
  const filtered = Object.values(problems).filter(p => catSet.has(p.parent_category));

  // Split by type
  const calcPool = filtered.filter(p => p.type === "計算");
  const theoryPool = filtered.filter(p => p.type === "理論");

  // Score and sort (descending)
  const sortByScore = (pool) => {
    return pool
      .map(p => ({ ...p, _score: scoreProblem(p, attemptStats) }))
      .sort((a, b) => b._score - a._score);
  };

  const selectedCalc = sortByScore(calcPool).slice(0, calcCount);
  const selectedTheory = sortByScore(theoryPool).slice(0, theoryCount);

  return [...selectedCalc, ...selectedTheory];
}

function buildTodayProblems(selected, schedule) {
  // Group by topic (use parent_category + first normalized_topic)
  const topicMap = {};
  for (const p of selected) {
    const topicKey = (p.normalized_topics && p.normalized_topics[0]) || p.title;
    if (!topicMap[topicKey]) {
      topicMap[topicKey] = {
        topic_id: `${p.parent_category}/${topicKey}`,
        topic_name: topicKey,
        category: p.parent_category,
        reason: "schedule",
        problems: [],
      };
    }
    topicMap[topicKey].problems.push({
      problem_id: p.id,
      book: p.book,
      number: p.number,
      title: p.title,
      type: p.type,
      scope: p.scope,
      page: p.page,
      time_min: p.time_min,
      rank: p.rank,
    });
  }

  const topics = Object.values(topicMap);
  const totalProblems = selected.length;

  return {
    generated_date: todayStr(),
    generated_at: new Date().toISOString().replace("T", " ").slice(0, 19),
    schema_version: 4,
    selection_policy: "worker-schedule-smart",
    carryover_count: 0,
    total_topics: topics.length,
    total_problems: totalProblems,
    weekly_schedule: {
      week_start: schedule.week_start || "",
      scope_categories: schedule.scope_categories || [],
    },
    topics,
  };
}

async function regenerateToday(env, schedule) {
  const calcCount = schedule.calc_count || 20;
  const theoryCount = schedule.theory_count || 10;
  const categories = schedule.scope_categories || [];
  if (categories.length === 0) return null;

  const [masterData, attemptsData] = await Promise.all([
    env.KOMEKOME_STORE.get("problems_master", "json"),
    env.KOMEKOME_STORE.get("attempts_all", "json"),
  ]);

  if (!masterData || !masterData.problems) return null;

  const attemptStats = buildAttemptStats(attemptsData || []);
  const selected = selectProblems(masterData.problems, categories, attemptStats, calcCount, theoryCount);

  // Graduated rotation: 2 least-recently-practiced from scope categories
  const catSet = new Set(categories);
  const selectedIds = new Set(selected.map(p => p.id));
  const graduatedPool = Object.values(masterData.problems)
    .filter(p => {
      if (selectedIds.has(p.id) || !catSet.has(p.parent_category)) return false;
      const stat = attemptStats[p.id];
      return stat && stat.total >= 3 && stat.correct >= 2;
    })
    .sort((a, b) => {
      const la = (attemptStats[a.id] || {}).lastDate || "";
      const lb = (attemptStats[b.id] || {}).lastDate || "";
      return la.localeCompare(lb);
    });
  selected.push(...graduatedPool.slice(0, 2));

  const todayData = buildTodayProblems(selected, schedule);

  await env.KOMEKOME_STORE.put("today_problems", JSON.stringify(todayData));
  return todayData;
}

// ── Handlers ──

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

  // Regenerate today_problems immediately
  let todayResult = null;
  try {
    todayResult = await regenerateToday(env, body);
  } catch (e) {
    // Non-fatal: schedule saved, regeneration failed
    return json({ ok: true, stored_at: body.updated_at, regenerated: false, error: e.message }, 200, request);
  }

  return json({
    ok: true,
    stored_at: body.updated_at,
    regenerated: !!todayResult,
    total_problems: todayResult ? todayResult.total_problems : 0,
  }, 200, request);
}

export async function onRequestPost(context) {
  // POST behaves the same as PUT (for WSL push compatibility)
  return onRequestPut(context);
}

export async function onRequestOptions(context) {
  return new Response(null, { headers: corsHeaders(context.request) });
}
