import { useState, useEffect, useCallback, useMemo } from "react";
import { createRoot } from "react-dom/client";

// ── Storage ──
function load(key, fb) {
  try { const r = localStorage.getItem(key); return r ? JSON.parse(r) : fb; } catch { return fb; }
}
function save(key, v) {
  try { localStorage.setItem(key, JSON.stringify(v)); } catch (e) { console.error(e); }
}
function setCookie(name, value, days = 365) {
  const d = new Date(); d.setTime(d.getTime() + days * 86400000);
  document.cookie = `${name}=${encodeURIComponent(value)};expires=${d.toUTCString()};path=/;SameSite=Strict;Secure`;
}
function getCookie(name) {
  const m = document.cookie.match(new RegExp(`(?:^|;)\\s*${name}=([^;]*)`));
  return m ? decodeURIComponent(m[1]) : "";
}

// ── API ──
function apiBase(url) { return url ? url.replace(/\/+$/, "") : ""; }

async function apiFetch(url, token, options = {}) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 15000);
  try {
    const res = await fetch(url, {
      ...options, signal: controller.signal,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(options.headers || {}) },
    });
    if (!res.ok) throw new Error(`API ${res.status}`);
    return res.json();
  } finally { clearTimeout(timeoutId); }
}

// ── Constants & Date Utils ──
const font = "'Noto Sans JP', -apple-system, sans-serif";
function today() { return new Date().toISOString().split("T")[0]; }

function dateAdd(d, n) { const x = new Date(d + "T00:00:00"); x.setDate(x.getDate() + n); return x.toISOString().split("T")[0]; }
function weekStart(d) { const x = new Date(d + "T00:00:00"); x.setDate(x.getDate() - x.getDay()); return x.toISOString().split("T")[0]; }
function monthStart(d) { return d.slice(0, 7) + "-01"; }
function yearStart(d) { return d.slice(0, 4) + "-01-01"; }
function fmtDate(d) { if (!d) return "-"; const [, m, day] = d.split("-"); return `${+m}/${+day}`; }
function formatRemain(until) {
  const ms = new Date(until) - new Date();
  if (ms <= 0) return "期限切れ";
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  return h > 0 ? h + "時間" + m + "分" : m + "分";
}

const C = {
  bg: "#0f1419", surface: "#1a1f2e", surface2: "#222838", surface3: "#2a3142",
  border: "#333b4f", accent: "#ff8b3d", accentDim: "rgba(255,139,61,0.12)",
  green: "#3dd68c", greenDim: "rgba(61,214,140,0.12)",
  red: "#ff6b6b", redDim: "rgba(255,107,107,0.12)",
  blue: "#5b9cf6", blueDim: "rgba(91,156,246,0.12)",
  purple: "#a78bfa", yellow: "#ffc847",
  text: "#e8ecf1", text2: "#9ba4b5", text3: "#5f6980",
};

const MISTAKE_TYPES_COMMON = [
  { id: "知識不足", label: "知識不足", desc: "規定を知らなかった" },
  { id: "条件判断ミス", label: "条件判断", desc: "適用条件を間違えた" },
  { id: "問題読み落とし", label: "読み落とし", desc: "問題文の条件を見落とし" },
];
const MISTAKE_TYPES_CALC = [
  { id: "計算手順ミス", label: "手順ミス", desc: "計算の手順・方法を間違えた" },
  { id: "ケアレスミス", label: "ケアレス", desc: "単純な計算・転記ミス" },
  { id: "項目漏れ", label: "項目漏れ", desc: "調整項目を見落とした" },
];
const MISTAKE_TYPES_THEORY = [
  { id: "暗記不足", label: "暗記不足", desc: "条文を再現できなかった" },
  { id: "論述不備", label: "論述不備", desc: "答案の構成・表現が不十分" },
];

function getMistakeTypes(problemType) {
  return problemType === "理論"
    ? [...MISTAKE_TYPES_COMMON, ...MISTAKE_TYPES_THEORY]
    : [...MISTAKE_TYPES_COMMON, ...MISTAKE_TYPES_CALC];
}

// ── Components ──
function Btn({ onClick, disabled, children, bg, color, style: extra = {} }) {
  const [pressed, setPressed] = useState(false);
  return (
    <button onClick={onClick} disabled={disabled}
      onTouchStart={() => setPressed(true)} onTouchEnd={() => setPressed(false)}
      onMouseDown={() => setPressed(true)} onMouseUp={() => setPressed(false)} onMouseLeave={() => setPressed(false)}
      style={{
        background: bg, color, border: "none", borderRadius: 10,
        padding: "14px 24px", fontSize: 15, fontWeight: 600,
        cursor: disabled ? "default" : "pointer", fontFamily: font,
        transition: "all 0.1s", opacity: disabled ? 0.5 : pressed ? 0.7 : 1,
        transform: pressed ? "scale(0.96)" : "scale(1)", ...extra,
      }}>{children}</button>
  );
}

function RankBadge({ rank }) {
  const colors = { A: C.green, B: C.blue, C: C.purple };
  const c = colors[rank] || C.text3;
  return rank ? (
    <span style={{ fontSize: 10, padding: "2px 8px", borderRadius: 4, background: `${c}20`, color: c, fontWeight: 700 }}>{rank}</span>
  ) : null;
}

function ScopeBadge({ scope }) {
  const c = scope === "総合" ? C.yellow : C.text3;
  return scope === "総合" ? (
    <span style={{ fontSize: 10, padding: "2px 8px", borderRadius: 4, background: `${c}20`, color: c, fontWeight: 600 }}>総合</span>
  ) : null;
}

// ── Book labels ──
const BOOK_ORDER = [
  "法人計算問題集1-1", "法人計算問題集1-2",
  "法人計算問題集2-1", "法人計算問題集2-2",
  "法人計算問題集3-1", "法人計算問題集3-2",
  "法人理論問題集",
];
const BOOK_SHORT = {
  "法人計算問題集1-1": "計算1-1", "法人計算問題集1-2": "計算1-2",
  "法人計算問題集2-1": "計算2-1", "法人計算問題集2-2": "計算2-2",
  "法人計算問題集3-1": "計算3-1", "法人計算問題集3-2": "計算3-2",
  "法人理論問題集": "理論",
};
const DASHBOARD_CATEGORIES = [
  "損金算入",
  "所得計算",
  "その他",
  "グループ法人",
  "益金不算入",
  "組織再編",
  "税額計算",
  "国際課税",
  "総則・定義",
  "欠損金",
  "申告納付等",
  "圧縮記帳等",
  "通算制度",
  "資本等取引",
  "引当金・準備金",
];

// ── Card component ──
function Card({ title, children, style: extra = {} }) {
  return (
    <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "16px 18px", marginBottom: 12, ...extra }}>
      {title && <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 12 }}>{title}</div>}
      {children}
    </div>
  );
}

// ── Auth image (fetches with Bearer token, renders as blob URL) ──
function AuthImage({ src, token, style: extra = {}, alt = "" }) {
  const [blobUrl, setBlobUrl] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    let objectUrl = null;
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch(src, { headers: { Authorization: `Bearer ${token}` } });
        if (!res.ok) throw new Error(res.status);
        const blob = await res.blob();
        if (cancelled) return;
        objectUrl = URL.createObjectURL(blob);
        setBlobUrl(objectUrl);
      } catch {
        if (!cancelled) setError(true);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; if (objectUrl) URL.revokeObjectURL(objectUrl); };
  }, [src, token]);

  if (loading) return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", padding: 40, color: C.text3, fontSize: 13, ...extra }}>読込中...</div>
  );
  if (error) return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", padding: 40, color: C.red, fontSize: 13, ...extra }}>画像を読み込めません</div>
  );
  return <img src={blobUrl} alt={alt} style={{ maxWidth: "100%", borderRadius: 8, ...extra }} />;
}

// ── Reason badge for today's problems ──
function ReasonBadge({ reason }) {
  const colors = {
    "弱点集中24h": C.red, "弱点集中": C.red, "失効復習": C.red, "卒業後復習": C.purple,
    "間隔復習": C.blue, "弱点補強": C.yellow,
    "3日後復習": C.green, "7日後復習": C.green, "14日後復習": C.green, "28日後復習": C.green,
    "新規A論点": C.accent, "新規B論点": C.text2,
  };
  const c = colors[reason] || C.text3;
  return <span style={{ fontSize: 9, padding: "2px 6px", borderRadius: 4, background: `${c}20`, color: c, fontWeight: 600 }}>{reason}</span>;
}

// ── Bar chart (horizontal) ──
function HBar({ label, value, max, color, sub }) {
  const pct = max > 0 ? (value / max) * 100 : 0;
  return (
    <div style={{ marginBottom: 8 }}>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 2 }}>
        <span style={{ color: C.text2, fontSize: 12 }}>{label}</span>
        <span style={{ color, fontSize: 12, fontWeight: 700 }}>{value}</span>
      </div>
      <div style={{ height: 6, background: C.surface3, borderRadius: 3, overflow: "hidden" }}>
        <div style={{ height: "100%", background: color, width: `${Math.min(pct, 100)}%`, borderRadius: 3, transition: "width 0.3s" }} />
      </div>
      {sub && <div style={{ color: C.text3, fontSize: 9, marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

// ── Stat number ──
function StatNum({ value, label, color, cols }) {
  return (
    <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "14px 8px", textAlign: "center" }}>
      <div style={{ color: color || C.text, fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ color: C.text3, fontSize: 10, marginTop: 2 }}>{label}</div>
    </div>
  );
}

// ── Daily mini bar chart ──
function DailyChart({ dailyData, maxVal, color }) {
  const bars = dailyData.slice(-14); // last 14 days
  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: 2, height: 50 }}>
      {bars.map((d, i) => {
        const h = maxVal > 0 ? Math.max((d.value / maxVal) * 48, d.value > 0 ? 3 : 0) : 0;
        return (
          <div key={i} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 2 }}>
            <div style={{ width: "100%", height: h, background: color, borderRadius: 2, transition: "height 0.3s" }} />
            {i % 2 === 0 && <span style={{ color: C.text3, fontSize: 7 }}>{d.label}</span>}
          </div>
        );
      })}
    </div>
  );
}

// ═══════ STATS VIEW ═══════
const PERIODS = [
  { id: "day", label: "今日" },
  { id: "week", label: "週" },
  { id: "month", label: "月" },
  { id: "year", label: "年" },
  { id: "all", label: "累計" },
];

function StatsView({ attempts, problems, problemList, onBack }) {
  const [period, setPeriod] = useState("week");

  // Filter attempts by period
  const filtered = useMemo(() => {
    const t = today();
    let start;
    switch (period) {
      case "day": start = t; break;
      case "week": start = weekStart(t); break;
      case "month": start = monthStart(t); break;
      case "year": start = yearStart(t); break;
      default: start = "2000-01-01";
    }
    return attempts.filter(a => a.date >= start);
  }, [attempts, period]);

  // Core metrics
  const totalCount = filtered.length;
  const correctCount = filtered.filter(a => a.result === "○").length;
  const wrongCount = totalCount - correctCount;
  const rate = totalCount > 0 ? Math.round(correctCount / totalCount * 100) : null;
  const totalTime = filtered.reduce((s, a) => s + (a.time_min || 0), 0);
  const uniqueProblems = new Set(filtered.map(a => a.problem_id)).size;

  // Mistakes distribution
  const mistakeMap = {};
  filtered.filter(a => a.result === "×" && a.mistakes).forEach(a => {
    a.mistakes.forEach(m => { mistakeMap[m] = (mistakeMap[m] || 0) + 1; });
  });
  const mistakeEntries = Object.entries(mistakeMap).sort((a, b) => b[1] - a[1]);
  const maxMistake = mistakeEntries.length > 0 ? mistakeEntries[0][1] : 1;

  // By book
  const bookStats = useMemo(() => {
    const bs = {};
    filtered.forEach(a => {
      const p = problems[a.problem_id];
      const book = p ? p.book : "不明";
      if (!bs[book]) bs[book] = { correct: 0, wrong: 0, total: 0, time: 0, ids: new Set() };
      bs[book].total++;
      bs[book].time += a.time_min || 0;
      bs[book].ids.add(a.problem_id);
      if (a.result === "○") bs[book].correct++; else bs[book].wrong++;
    });
    return bs;
  }, [filtered, problems]);

  // Daily trend (last 14 days for week+, last 7 for day)
  const dailyTrend = useMemo(() => {
    const days = period === "day" ? 1 : period === "week" ? 7 : 14;
    const t = today();
    const data = [];
    for (let i = days - 1; i >= 0; i--) {
      const d = dateAdd(t, -i);
      const dayAttempts = attempts.filter(a => a.date === d);
      data.push({
        date: d,
        label: fmtDate(d),
        value: dayAttempts.length,
        correct: dayAttempts.filter(a => a.result === "○").length,
        wrong: dayAttempts.filter(a => a.result === "×").length,
        time: dayAttempts.reduce((s, a) => s + (a.time_min || 0), 0),
      });
    }
    return data;
  }, [attempts, period]);
  const maxDaily = Math.max(...dailyTrend.map(d => d.value), 1);

  // Weak problems (by wrong count in period)
  const weakMap = {};
  filtered.filter(a => a.result === "×").forEach(a => {
    weakMap[a.problem_id] = (weakMap[a.problem_id] || 0) + 1;
  });
  const weakProblems = Object.entries(weakMap)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 15)
    .map(([pid, cnt]) => ({ id: pid, wrong: cnt, ...(problems[pid] || { title: pid }) }));

  // Speed analysis: problems where actual time > target time
  const speedIssues = useMemo(() => {
    const byProblem = {};
    filtered.filter(a => a.time_min > 0).forEach(a => {
      const p = problems[a.problem_id];
      if (!p || !p.time_min) return;
      if (!byProblem[a.problem_id]) byProblem[a.problem_id] = { times: [], target: p.time_min, title: p.title, book: p.book };
      byProblem[a.problem_id].times.push(a.time_min);
    });
    return Object.entries(byProblem)
      .map(([pid, d]) => ({ id: pid, avg: Math.round(d.times.reduce((s, t) => s + t, 0) / d.times.length), target: d.target, title: d.title, book: d.book, ratio: Math.round((d.times.reduce((s, t) => s + t, 0) / d.times.length) / d.target * 100) }))
      .filter(d => d.ratio > 120) // 20%+ over target
      .sort((a, b) => b.ratio - a.ratio)
      .slice(0, 10);
  }, [filtered, problems]);

  // Coverage: how many of total problems have been attempted
  const attemptedAll = new Set(attempts.map(a => a.problem_id)).size;
  const coveragePct = problemList.length > 0 ? Math.round(attemptedAll / problemList.length * 100) : 0;

  // Streak: consecutive days with at least 1 attempt
  const streak = useMemo(() => {
    const t = today();
    let count = 0;
    let d = t;
    while (true) {
      if (attempts.some(a => a.date === d)) { count++; d = dateAdd(d, -1); }
      else break;
    }
    return count;
  }, [attempts]);

  return (
    <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
      <div style={{ maxWidth: 480, margin: "0 auto" }}>
        <button onClick={onBack} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 戻る</button>
        <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 12px" }}>分析</h2>

        {/* Period selector */}
        <div style={{ display: "flex", gap: 4, marginBottom: 16 }}>
          {PERIODS.map(p => (
            <button key={p.id} onClick={() => setPeriod(p.id)}
              style={{ flex: 1, padding: "8px 0", borderRadius: 8, border: "none", cursor: "pointer", fontFamily: font, fontSize: 12, fontWeight: 600,
                background: period === p.id ? C.accent : C.surface, color: period === p.id ? "#fff" : C.text3 }}>
              {p.label}
            </button>
          ))}
        </div>

        {/* KPI cards */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 8, marginBottom: 12 }}>
          <StatNum value={totalCount} label="解答数" color={C.accent} />
          <StatNum value={rate !== null ? `${rate}%` : "-"} label="正答率" color={rate >= 80 ? C.green : rate >= 60 ? C.blue : rate !== null ? C.red : C.text3} />
          <StatNum value={`${totalTime}分`} label="学習時間" color={C.blue} />
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr 1fr", gap: 8, marginBottom: 12 }}>
          <StatNum value={correctCount} label="正解" color={C.green} />
          <StatNum value={wrongCount} label="不正解" color={C.red} />
          <StatNum value={uniqueProblems} label="問題種類" color={C.text2} />
          <StatNum value={`${streak}日`} label="連続" color={C.yellow} />
        </div>

        {/* Coverage */}
        <Card title="カバー率">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
            <span style={{ color: C.text, fontSize: 14, fontWeight: 700 }}>{coveragePct}%</span>
            <span style={{ color: C.text3, fontSize: 11 }}>{attemptedAll} / {problemList.length}問</span>
          </div>
          <div style={{ height: 8, background: C.surface3, borderRadius: 4, overflow: "hidden" }}>
            <div style={{ height: "100%", background: C.accent, width: `${coveragePct}%`, borderRadius: 4, transition: "width 0.3s" }} />
          </div>
        </Card>

        {/* Daily chart */}
        {period !== "day" && dailyTrend.length > 1 && (
          <Card title="日別推移">
            <DailyChart dailyData={dailyTrend} maxVal={maxDaily} color={C.accent} />
            <div style={{ display: "flex", justifyContent: "space-between", marginTop: 6 }}>
              <span style={{ color: C.text3, fontSize: 9 }}>解答数</span>
              <span style={{ color: C.text3, fontSize: 9 }}>max: {maxDaily}</span>
            </div>
          </Card>
        )}

        {/* By book */}
        <Card title="問題集別">
          {BOOK_ORDER.map(book => {
            const s = bookStats[book];
            if (!s) return null;
            const bookRate = s.total > 0 ? Math.round(s.correct / s.total * 100) : 0;
            const bookTotal = problemList.filter(p => p.book === book).length;
            const rateColor = bookRate >= 80 ? C.green : bookRate >= 60 ? C.blue : C.red;
            return (
              <div key={book} style={{ marginBottom: 10, paddingBottom: 10, borderBottom: `1px solid ${C.border}` }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
                  <span style={{ color: C.text, fontSize: 13, fontWeight: 600 }}>{BOOK_SHORT[book]}</span>
                  <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                    <span style={{ color: C.green, fontSize: 11 }}>{s.correct}○</span>
                    <span style={{ color: C.red, fontSize: 11 }}>{s.wrong}×</span>
                    <span style={{ color: rateColor, fontSize: 13, fontWeight: 700 }}>{bookRate}%</span>
                  </div>
                </div>
                <div style={{ height: 6, background: C.surface3, borderRadius: 3, overflow: "hidden", marginBottom: 4 }}>
                  <div style={{ height: "100%", background: rateColor, width: `${bookRate}%`, borderRadius: 3, transition: "width 0.3s" }} />
                </div>
                <div style={{ color: C.text3, fontSize: 10 }}>{s.ids.size}/{bookTotal}問着手 / {s.total}回 / {s.time}分</div>
              </div>
            );
          })}
        </Card>

        {/* Mistake types */}
        {mistakeEntries.length > 0 && (
          <Card title="間違い分類">
            {mistakeEntries.map(([type, count]) => (
              <HBar key={type} label={type} value={count} max={maxMistake} color={C.red} />
            ))}
          </Card>
        )}

        {/* Speed issues */}
        {speedIssues.length > 0 && (
          <Card title="時間超過（目安の120%超）">
            {speedIssues.map(si => (
              <div key={si.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 0", borderBottom: `1px solid ${C.border}` }}>
                <span style={{ color: si.ratio > 200 ? C.red : C.yellow, fontSize: 12, fontWeight: 700, minWidth: 36, textAlign: "right" }}>{si.ratio}%</span>
                <div style={{ flex: 1 }}>
                  <div style={{ color: C.text, fontSize: 12, lineHeight: 1.3 }}>{si.title}</div>
                  <div style={{ color: C.text3, fontSize: 10 }}>{si.avg}分 / 目安{si.target}分</div>
                </div>
              </div>
            ))}
          </Card>
        )}

        {/* Weak problems */}
        {weakProblems.length > 0 && (
          <Card title="弱点問題 TOP15">
            {weakProblems.map((wp, i) => (
              <div key={wp.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 0", borderBottom: i < weakProblems.length - 1 ? `1px solid ${C.border}` : "none" }}>
                <span style={{ color: C.red, fontSize: 14, fontWeight: 700, minWidth: 28, textAlign: "right" }}>{wp.wrong}×</span>
                <div style={{ flex: 1 }}>
                  <div style={{ color: C.text, fontSize: 12, lineHeight: 1.4 }}>{wp.title}</div>
                  <div style={{ color: C.text3, fontSize: 10 }}>{BOOK_SHORT[wp.book] || wp.book}</div>
                </div>
              </div>
            ))}
          </Card>
        )}

        {totalCount === 0 && (
          <div style={{ color: C.text3, textAlign: "center", padding: 40, fontSize: 14 }}>この期間のデータはありません</div>
        )}
      </div>
    </div>
  );
}

// ═══════ DASHBOARD VIEW ═══════
function DashboardView({ dashboardData, onBack }) {
  const categories = useMemo(() => {
    const raw = Array.isArray(dashboardData?.categories) ? dashboardData.categories : [];
    const map = new Map(raw.map(c => [c.name, c]));
    return DASHBOARD_CATEGORIES.map((name) => map.get(name) || ({
      name,
      total_topics: 0,
      stage_counts: { "未着手": 0, "学習中": 0, "復習中": 0, "卒業済": 0 },
      progress_rate: 0,
      accuracy: 0,
      graduation_probability: 0,
      focus_active_topics: 0,
    }));
  }, [dashboardData]);

  const totals = dashboardData?.totals || {};
  const stageColors = { "未着手": "#5f6980", "学習中": "#ff8b3d", "復習中": "#5b9cf6", "卒業済": "#3dd68c" };

  return (
    <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
      <div style={{ maxWidth: 480, margin: "0 auto" }}>
        <button onClick={onBack} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 戻る</button>
        <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 4px" }}>カテゴリ進捗</h2>
        <div style={{ color: C.text3, fontSize: 11, marginBottom: 12 }}>{dashboardData?.generated_date || "-"}</div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr 1fr", gap: 8, marginBottom: 12 }}>
          <StatNum value={totals.topics || 0} label="総論点" color={C.accent} />
          <StatNum value={totals.attempted_topics || 0} label="着手" color={C.blue} />
          <StatNum value={totals.graduated_topics || 0} label="卒業" color={C.green} />
          <StatNum value={`${Math.round((totals.overall_accuracy || 0) * 100)}%`} label="正答率" color={C.yellow} />
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {categories.map((cat) => {
            const sc = cat.stage_counts || {};
            const total = cat.total_topics || 0;
            const segments = ["未着手", "学習中", "復習中", "卒業済"];
            return (
              <div key={cat.name} style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "12px 14px" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                  <span style={{ color: C.text, fontSize: 14, fontWeight: 700 }}>{cat.name}</span>
                  <span style={{ color: C.text3, fontSize: 11 }}>{total}論点</span>
                </div>

                <div style={{ height: 8, background: C.surface3, borderRadius: 5, overflow: "hidden", display: "flex", marginBottom: 8 }}>
                  {segments.map((k) => {
                    const count = sc[k] || 0;
                    const pct = total > 0 ? (count / total) * 100 : 0;
                    return <div key={k} style={{ width: `${pct}%`, background: stageColors[k] }} />;
                  })}
                </div>

                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 8 }}>
                  <div style={{ color: C.text2, fontSize: 11 }}>正答率 {Math.round((cat.accuracy || 0) * 100)}%</div>
                  <div style={{ color: C.text2, fontSize: 11 }}>卒業確率 {Math.round((cat.graduation_probability || 0) * 100)}%</div>
                  <div style={{ color: (cat.focus_active_topics || 0) > 0 ? C.red : C.text3, fontSize: 11, textAlign: "right" }}>
                    フォーカス {(cat.focus_active_topics || 0)}件
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

function InlineMarkdown({ text }) {
  if (!text) return null;
  const parts = [];
  const re = /(\*\*(.+?)\*\*)|(\*(.+?)\*)|(`(.+?)`)/g;
  let lastIndex = 0;
  let match;
  while ((match = re.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }
    if (match[1]) {
      parts.push(<strong key={match.index} style={{ color: C.text, fontWeight: 700 }}>{match[2]}</strong>);
    } else if (match[3]) {
      parts.push(<em key={match.index} style={{ fontStyle: "italic" }}>{match[4]}</em>);
    } else if (match[5]) {
      parts.push(<code key={match.index} style={{ background: C.surface2, padding: "1px 4px", borderRadius: 3, fontSize: "0.9em", fontFamily: "monospace", color: C.purple }}>{match[6]}</code>);
    }
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }
  return parts.length === 1 && typeof parts[0] === "string" ? parts[0] : <>{parts}</>;
}

function convertLatex(tex) {
  const parts = [];
  let remaining = tex;
  let keyIndex = 0;

  while (remaining.length > 0) {
    const fracIdx = remaining.indexOf("\\frac{");
    if (fracIdx === -1) {
      parts.push(replaceSymbols(remaining));
      break;
    }
    if (fracIdx > 0) {
      parts.push(replaceSymbols(remaining.slice(0, fracIdx)));
    }
    const afterFrac = remaining.slice(fracIdx + 6);
    const { content: num, rest: afterNum } = extractBraces(afterFrac);
    let den = "";
    let rest = "";
    if (afterNum.startsWith("{")) {
      const denParsed = extractBraces(afterNum.slice(1));
      den = denParsed.content;
      rest = denParsed.rest;
    } else {
      den = afterNum;
      rest = "";
    }

    parts.push(
      <span key={keyIndex++} style={{ display: "inline-flex", flexDirection: "column", alignItems: "center", verticalAlign: "middle", margin: "0 3px", lineHeight: 1.3 }}>
        <span style={{ borderBottom: `1px solid ${C.purple}`, padding: "0 4px", fontSize: "0.85em" }}>{convertLatex(num)}</span>
        <span style={{ padding: "0 4px", fontSize: "0.85em" }}>{convertLatex(den)}</span>
      </span>
    );
    remaining = rest || "";
  }

  return parts.length === 1 ? parts[0] : <>{parts}</>;
}

function replaceSymbols(s) {
  return s
    .replace(/\\times/g, "×")
    .replace(/\\div/g, "÷")
    .replace(/\\leq/g, "≤")
    .replace(/\\geq/g, "≥")
    .replace(/\\neq/g, "≠")
    .replace(/\\cdot/g, "·")
    .replace(/\\pm/g, "±")
    .replace(/\\text\{(.+?)\}/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

function extractBraces(s) {
  let depth = 0;
  let i = 0;
  for (; i < s.length; i++) {
    if (s[i] === "{") depth++;
    else if (s[i] === "}") {
      if (depth === 0) return { content: s.slice(0, i), rest: s.slice(i + 1) };
      depth--;
    }
  }
  return { content: s, rest: "" };
}

function MathBlock({ text }) {
  let content = text.replace(/^\$\$\s*/, "").replace(/\s*\$\$$/, "").trim();
  const isAlign = content.includes("\\begin{align}");
  if (isAlign) {
    content = content.replace(/\\begin\{align\}/, "").replace(/\\end\{align\}/, "").trim();
    const lines = content.split(/\\\\\s*/).map((l) => l.trim()).filter(Boolean);
    return (
      <div style={{ color: C.purple, fontFamily: "monospace", fontSize: 12, padding: "6px 10px", background: C.surface2, borderRadius: 6, marginTop: 4, marginBottom: 4, overflowX: "auto", lineHeight: 2 }}>
        {lines.map((line, i) => {
          const cleaned = convertLatex(line.replace(/&/g, "").trim());
          return <div key={i}>{cleaned}</div>;
        })}
      </div>
    );
  }

  const cleaned = convertLatex(content);
  return (
    <div style={{ color: C.purple, fontFamily: "monospace", fontSize: 12, padding: "6px 10px", background: C.surface2, borderRadius: 6, marginTop: 4, marginBottom: 4, overflowX: "auto" }}>
      {cleaned}
    </div>
  );
}

// ── Table figure component ──
function TableFigure({ rows }) {
  if (!rows || rows.length === 0) return null;
  const parsed = rows.map(r => ({
    cells: r.split("|").filter(Boolean).map(c => c.trim()),
    isSep: /^[-:| ]+$/.test(r.replace(/\|/g, "").trim()),
  })).filter(r => !r.isSep);
  if (parsed.length === 0) return null;
  const header = parsed[0];
  const body = parsed.slice(1);
  return (
    <div style={{ border: `1px solid ${C.border}`, borderRadius: 8, overflow: "hidden", marginTop: 6, marginBottom: 6 }}>
      <div style={{ display: "flex", gap: 0, background: `${C.accent}18`, padding: "6px 8px", borderBottom: `1px solid ${C.border}` }}>
        {header.cells.map((c, j) => <span key={j} style={{ flex: 1, fontSize: 11, fontWeight: 700, color: C.accent }}><InlineMarkdown text={c} /></span>)}
      </div>
      {body.map((row, i) => (
        <div key={i} style={{ display: "flex", gap: 0, padding: "5px 8px", borderBottom: i < body.length - 1 ? `1px solid ${C.border}` : "none", background: i % 2 === 0 ? "transparent" : `${C.surface2}40` }}>
          {row.cells.map((c, j) => <span key={j} style={{ flex: 1, fontSize: 11, color: C.text }}><InlineMarkdown text={c} /></span>)}
        </div>
      ))}
    </div>
  );
}

// ── Markdown-like section renderer (2-pass: groups table rows) ──
function SectionContent({ text }) {
  if (!text) return null;
  const lines = text.split("\n");

  const blocks = [];
  let tableBuffer = [];
  let mathBuffer = null;
  let codeBuffer = null;

  const flushTable = () => {
    if (tableBuffer.length > 0) { blocks.push({ type: "table", rows: [...tableBuffer] }); tableBuffer = []; }
  };

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed.startsWith("```")) {
      if (codeBuffer === null) {
        flushTable();
        codeBuffer = [];
      } else {
        blocks.push({ type: "code", lines: [...codeBuffer] });
        codeBuffer = null;
      }
      continue;
    }
    if (codeBuffer !== null) {
      codeBuffer.push(line);
      continue;
    }

    if (trimmed === "$$") {
      if (mathBuffer === null) {
        flushTable();
        mathBuffer = [];
      } else {
        blocks.push({ type: "math", content: mathBuffer.join("\n") });
        mathBuffer = null;
      }
      continue;
    }
    if (mathBuffer !== null) {
      mathBuffer.push(trimmed);
      continue;
    }

    if (trimmed.startsWith("|") && trimmed.endsWith("|")) {
      tableBuffer.push(trimmed);
      continue;
    }
    flushTable();

    if (trimmed.startsWith("$$") && trimmed.endsWith("$$") && trimmed.length > 4) {
      blocks.push({ type: "math", content: trimmed.slice(2, -2).trim() });
      continue;
    }

    blocks.push({ type: "line", text: trimmed });
  }
  flushTable();
  if (mathBuffer !== null) blocks.push({ type: "math", content: mathBuffer.join("\n") });
  if (codeBuffer !== null) blocks.push({ type: "code", lines: codeBuffer });

  return (
    <div style={{ fontSize: 13, lineHeight: 1.8, color: C.text }}>
      {blocks.map((block, i) => {
        if (block.type === "table") return <TableFigure key={i} rows={block.rows} />;
        if (block.type === "math") return <MathBlock key={i} text={"$$" + block.content + "$$"} />;
        if (block.type === "code") return (
          <pre key={i} style={{ color: C.text2, fontFamily: "monospace", fontSize: 11, padding: "8px 10px", background: C.surface2, borderRadius: 6, marginTop: 4, marginBottom: 4, overflowX: "auto", lineHeight: 1.6, whiteSpace: "pre-wrap" }}>
            {block.lines.join("\n")}
          </pre>
        );

        const trimmed = block.text;
        if (!trimmed) return <div key={i} style={{ height: 8 }} />;

        if (trimmed.startsWith("#### ")) return <div key={i} style={{ fontWeight: 700, fontSize: 12.5, color: C.blue, marginTop: 10, marginBottom: 3 }}><InlineMarkdown text={trimmed.slice(5)} /></div>;

        if (trimmed.startsWith("### ")) return <div key={i} style={{ fontWeight: 700, fontSize: 13, color: C.accent, marginTop: 12, marginBottom: 4 }}><InlineMarkdown text={trimmed.slice(4)} /></div>;

        if (trimmed.startsWith("- **")) {
          const m = trimmed.match(/^- \*\*(.+?)\*\*[：:]?\s*(.*)$/);
          if (m) return <div key={i} style={{ paddingLeft: 12, marginBottom: 4 }}><span style={{ fontWeight: 700, color: C.blue }}>{m[1]}</span>{m[2] && <span style={{ color: C.text2 }}>: <InlineMarkdown text={m[2]} /></span>}</div>;
        }

        if (trimmed.startsWith("- ")) return <div key={i} style={{ paddingLeft: 12, marginBottom: 2, color: C.text2 }}><InlineMarkdown text={trimmed.slice(2)} /></div>;

        const numMatch = trimmed.match(/^(\d+)\.\s+(.*)$/);
        if (numMatch) return <div key={i} style={{ paddingLeft: 4, marginBottom: 2, color: C.text }}><span style={{ color: C.text3, marginRight: 6, fontWeight: 600, fontSize: 12, minWidth: 18, display: "inline-block" }}>{numMatch[1]}.</span><InlineMarkdown text={numMatch[2]} /></div>;

        return <div key={i}><InlineMarkdown text={trimmed} /></div>;
      })}
    </div>
  );
}

// ── Status badge for topics ──
function StatusBadge({ status }) {
  const colors = { "卒業": C.green, "復習中": C.blue, "学習中": C.accent, "未着手": C.text3 };
  const c = colors[status] || C.text3;
  return <span style={{ fontSize: 9, padding: "2px 6px", borderRadius: 4, background: `${c}20`, color: c, fontWeight: 600 }}>{status}</span>;
}

// ═══════ MAIN APP ═══════
function App() {
  const [problems, setProblems] = useState({});
  const [attempts, setAttempts] = useState([]);
  const [view, setView] = useState("home");
  const [loaded, setLoaded] = useState(false);
  const [apiToken, setApiToken] = useState("");
  const [apiUrl, setApiUrl] = useState("");
  const [syncStatus, setSyncStatus] = useState("idle");
  const [syncMsg, setSyncMsg] = useState("");

  // Log flow state
  const [logBook, setLogBook] = useState(null);
  const [logProblem, setLogProblem] = useState(null);
  const [logResult, setLogResult] = useState(null); // "○" or "×"
  const [logTime, setLogTime] = useState("");
  const [logMistakes, setLogMistakes] = useState({});
  const [logMemo, setLogMemo] = useState("");

  // Today's problems state
  const [todayData, setTodayData] = useState(null);
  const [dashboardData, setDashboardData] = useState(null);
  const [todayProblem, setTodayProblem] = useState(null);
  const [todayTopicCtx, setTodayTopicCtx] = useState(null);
  const [pageViewStep, setPageViewStep] = useState("view"); // "view" | "mistakes" | "review"
  const [pvMistakes, setPvMistakes] = useState({});
  const [pvTime, setPvTime] = useState("");
  const [hintOpen, setHintOpen] = useState(false);

  // Topics state
  const [topics, setTopics] = useState([]);
  const [topicCategories, setTopicCategories] = useState([]);
  const [topicCat, setTopicCat] = useState(null);
  const [topicItem, setTopicItem] = useState(null);
  const [topicSearch, setTopicSearch] = useState("");

  // Settings
  const [apiTokenInput, setApiTokenInput] = useState("");
  const [apiUrlInput, setApiUrlInput] = useState("");
  const [scheduleCategories, setScheduleCategories] = useState([]);

  // ── Init ──
  useEffect(() => {
    const hash = location.hash;
    if (hash.startsWith("#token=")) {
      const t = decodeURIComponent(hash.slice(7));
      if (t) { save("kk3-api-token", t); save("kk3-api-url", ""); setCookie("kk3_token", t); history.replaceState(null, "", location.pathname); }
    }
    let savedToken = load("kk3-api-token", "");
    if (!savedToken) { const ct = getCookie("kk3_token"); if (ct) { savedToken = ct; save("kk3-api-token", savedToken); } }
    const savedUrl = load("kk3-api-url", "");
    setApiToken(savedToken); setApiTokenInput(savedToken);
    setApiUrl(savedUrl); setApiUrlInput(savedUrl);
    setAttempts(load("kk3-attempts", []));

    (async () => {
      if (savedToken) {
        setSyncStatus("syncing");
        try {
          const pData = await apiFetch(`${apiBase(savedUrl)}/api/komekome/problems`, savedToken);
          if (pData && pData.problems) { setProblems(pData.problems); save("kk3-problems", pData.problems); }
          // Merge remote attempts
          const aData = await apiFetch(`${apiBase(savedUrl)}/api/komekome/attempts`, savedToken);
          if (aData && aData.attempts) {
            const local = load("kk3-attempts", []);
            const remoteIds = new Set(aData.attempts.map(a => a.id));
            const localOnly = local.filter(a => !remoteIds.has(a.id));
            const merged = [...aData.attempts, ...localOnly];
            merged.sort((a, b) => b.id.localeCompare(a.id));
            setAttempts(merged);
            save("kk3-attempts", merged);
            // Push local-only back to server
            if (localOnly.length > 0) {
              try { await apiFetch(`${apiBase(savedUrl)}/api/komekome/attempts`, savedToken, { method: "POST", body: JSON.stringify(localOnly) }); } catch {}
            }
          }
          // Fetch topics
          try {
            const tData = await apiFetch(`${apiBase(savedUrl)}/api/komekome/topics`, savedToken);
            if (tData && tData.topics) {
              setTopics(tData.topics); setTopicCategories(tData.categories || []);
              save("kk3-topics", tData.topics); save("kk3-topic-cats", tData.categories || []);
            }
          } catch {}
          // Fetch today's problems
          try {
            const tdData = await apiFetch(`${apiBase(savedUrl)}/api/komekome/today`, savedToken);
            if (tdData && tdData.topics) {
              setTodayData(tdData); save("kk3-today", tdData);
            }
          } catch {}
          // Fetch dashboard data
          try {
            const dbData = await apiFetch(`${apiBase(savedUrl)}/api/komekome/dashboard`, savedToken);
            if (dbData && dbData.categories) {
              setDashboardData(dbData); save("kk3-dashboard", dbData);
            }
          } catch {}
          // Fetch schedule
          try {
            const schData = await apiFetch(`${apiBase(savedUrl)}/api/komekome/schedule`, savedToken);
            if (schData && Array.isArray(schData.scope_categories)) {
              setScheduleCategories(schData.scope_categories);
            }
          } catch {}
          setSyncStatus("synced"); setSyncMsg("OK");
        } catch (e) {
          // Offline fallback
          const cached = load("kk3-problems", {});
          if (Object.keys(cached).length > 0) setProblems(cached);
          const cachedTopics = load("kk3-topics", []);
          if (cachedTopics.length > 0) { setTopics(cachedTopics); setTopicCategories(load("kk3-topic-cats", [])); }
          const cachedToday = load("kk3-today", null);
          if (cachedToday) setTodayData(cachedToday);
          const cachedDashboard = load("kk3-dashboard", null);
          if (cachedDashboard) setDashboardData(cachedDashboard);
          setSyncStatus("offline"); setSyncMsg(e.message);
        }
      } else {
        const cached = load("kk3-problems", {});
        if (Object.keys(cached).length > 0) setProblems(cached);
        const cachedDashboard = load("kk3-dashboard", null);
        if (cachedDashboard) setDashboardData(cachedDashboard);
      }
      setLoaded(true);
    })();
  }, []);

  // ── Save attempts on change ──
  useEffect(() => { if (loaded) save("kk3-attempts", attempts); }, [attempts, loaded]);

  // ── Derived data ──
  const problemList = useMemo(() => Object.values(problems), [problems]);
  const bookProblems = useMemo(() => {
    if (!logBook) return [];
    return problemList.filter(p => p.book === logBook).sort((a, b) => {
      // Sort by page, then by number
      if (a.page !== b.page) return a.page - b.page;
      return a.number.localeCompare(b.number, "ja");
    });
  }, [problemList, logBook]);

  const todayAttempts = useMemo(() => {
    const t = today();
    return attempts.filter(a => a.date === t);
  }, [attempts]);

  const problemAttempts = useCallback((pid) => {
    return attempts.filter(a => a.problem_id === pid);
  }, [attempts]);

  // ── Submit attempt ──
  const submitAttempt = useCallback(async () => {
    if (!logProblem || !logResult) return;
    const selectedMistakes = Object.entries(logMistakes).filter(([, v]) => v).map(([k]) => k);
    const attempt = {
      id: `a_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 5)}`,
      date: today(),
      problem_id: logProblem.id,
      result: logResult,
      time_min: parseInt(logTime) || 0,
      mistakes: logResult === "×" ? selectedMistakes : [],
      memo: logMemo.trim(),
    };

    const newAttempts = [attempt, ...attempts];
    setAttempts(newAttempts);

    // Push to API
    const token = load("kk3-api-token", "");
    const url = load("kk3-api-url", "");
    if (token) {
      try { await apiFetch(`${apiBase(url)}/api/komekome/attempts`, token, { method: "POST", body: JSON.stringify([attempt]) }); }
      catch { /* stored locally, will sync later */ }
    }

    // Reset and go to confirmation
    setView("logged");
  }, [logProblem, logResult, logTime, logMistakes, logMemo, attempts]);

  const resetLog = useCallback(() => {
    setLogBook(null); setLogProblem(null); setLogResult(null);
    setLogTime(""); setLogMistakes({}); setLogMemo("");
  }, []);

  const resetPageView = useCallback(() => {
    setTodayProblem(null); setTodayTopicCtx(null);
    setPageViewStep("view"); setPvMistakes({}); setPvTime("");
    setHintOpen(false);
  }, []);

  const submitPageViewAttempt = useCallback(async (result) => {
    if (!todayProblem) return;
    const selectedMistakes = Object.entries(pvMistakes).filter(([, v]) => v).map(([k]) => k);
    const attempt = {
      id: `a_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 5)}`,
      date: today(),
      problem_id: todayProblem.problem_id,
      result,
      time_min: parseInt(pvTime) || 0,
      mistakes: result === "×" ? selectedMistakes : [],
      memo: "",
    };
    const newAttempts = [attempt, ...attempts];
    setAttempts(newAttempts);
    const token = load("kk3-api-token", "");
    const url = load("kk3-api-url", "");
    if (token) {
      try { await apiFetch(`${apiBase(url)}/api/komekome/attempts`, token, { method: "POST", body: JSON.stringify([attempt]) }); }
      catch {}
    }
    if (result === "×") {
      setPageViewStep("review");
    } else {
      resetPageView();
      setView("today");
    }
  }, [todayProblem, pvMistakes, pvTime, attempts, resetPageView]);

  // ── Loading ──
  if (!loaded) return (
    <div style={{ background: C.bg, minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center" }}>
      <span style={{ color: C.text3, fontFamily: font }}>Loading...</span>
    </div>
  );

  // ═══════ SETTINGS ═══════
  if (view === "settings") {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView("home")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 12 }}>← 戻る</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 20px" }}>設定</h2>
          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: 16 }}>
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 6 }}>API URL（空欄 = 同一サーバー）</div>
            <input type="url" value={apiUrlInput} onChange={e => setApiUrlInput(e.target.value)}
              placeholder="空欄でOK" style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 14, fontFamily: "monospace", marginBottom: 10, boxSizing: "border-box", outline: "none" }} />
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 6 }}>API Token</div>
            <input type="password" value={apiTokenInput} onChange={e => setApiTokenInput(e.target.value)}
              placeholder="your-secret-token" style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 14, fontFamily: "monospace", marginBottom: 10, boxSizing: "border-box", outline: "none" }} />
            <Btn onClick={async () => {
              const newToken = apiTokenInput.trim();
              const newUrl = apiUrlInput.trim().replace(/\/+$/, "");
              setApiToken(newToken); setApiUrl(newUrl);
              save("kk3-api-token", newToken); save("kk3-api-url", newUrl); setCookie("kk3_token", newToken);
              if (newToken) {
                setSyncStatus("syncing"); setSyncMsg("テスト中...");
                try {
                  const res = await fetch(`${apiBase(newUrl)}/api/komekome/problems`, { method: "GET", headers: { Authorization: `Bearer ${newToken}` } });
                  if (res.status === 401) { setSyncStatus("error"); setSyncMsg("認証エラー"); }
                  else if (!res.ok) { setSyncStatus("error"); setSyncMsg(`Error: ${res.status}`); }
                  else { setSyncStatus("synced"); setSyncMsg("接続OK"); }
                } catch (e) { setSyncStatus("error"); setSyncMsg(e.message); }
              }
            }} bg={C.accent} color="#fff" style={{ width: "100%", padding: "10px" }}>保存 & テスト</Btn>
          </div>
          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: 16, marginTop: 12 }}>
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 8 }}>同期ステータス</div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <div style={{ width: 8, height: 8, borderRadius: "50%", background: syncStatus === "synced" ? C.green : syncStatus === "error" ? C.red : C.text3 }} />
              <span style={{ color: C.text2, fontSize: 13 }}>{syncStatus === "synced" ? "接続済み" : syncStatus === "error" ? "エラー" : syncStatus === "offline" ? "オフライン" : "未設定"}</span>
              {syncMsg && <span style={{ color: C.text3, fontSize: 11 }}>({syncMsg})</span>}
            </div>
            <div style={{ color: C.text3, fontSize: 11, marginTop: 12 }}>問題数: {problemList.length} / 記録数: {attempts.length}</div>
          </div>
          {/* Weekly schedule */}
          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: 16, marginTop: 12 }}>
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 8 }}>今週の学習範囲</div>
            <div style={{ color: C.text3, fontSize: 10, marginBottom: 10 }}>選択したカテゴリから新規問題を出題します</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 4, marginBottom: 12 }}>
              {DASHBOARD_CATEGORIES.map(cat => (
                <label key={cat} style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 0", cursor: "pointer" }}>
                  <input type="checkbox" checked={scheduleCategories.includes(cat)}
                    onChange={e => {
                      setScheduleCategories(prev =>
                        e.target.checked ? [...prev, cat] : prev.filter(c => c !== cat)
                      );
                    }}
                    style={{ accentColor: C.accent, width: 18, height: 18, flexShrink: 0 }} />
                  <span style={{ color: C.text, fontSize: 13 }}>{cat}</span>
                </label>
              ))}
            </div>
            <Btn onClick={async () => {
              const token = load("kk3-api-token", "");
              const url = load("kk3-api-url", "");
              if (!token) return;
              try {
                await apiFetch(`${apiBase(url)}/api/komekome/schedule`, token, {
                  method: "PUT",
                  body: JSON.stringify({
                    week_start: weekStart(today()),
                    scope_categories: scheduleCategories,
                  }),
                });
                setSyncMsg("スケジュール保存OK");
              } catch (e) {
                setSyncMsg("スケジュール保存失敗: " + e.message);
              }
            }} bg={C.accent} color="#fff" style={{ width: "100%", padding: "10px" }}>スケジュール保存</Btn>
          </div>
        </div>
      </div>
    );
  }

  // ═══════ LOGGED (confirmation) ═══════
  if (view === "logged") {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "40px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto", textAlign: "center" }}>
          <div style={{ fontSize: 48, marginBottom: 16 }}>{logResult === "○" ? "○" : "×"}</div>
          <h2 style={{ color: C.text, fontSize: 20, fontWeight: 700, margin: "0 0 8px" }}>記録しました</h2>
          <div style={{ color: C.text2, fontSize: 14, marginBottom: 24 }}>{logProblem?.title}</div>
          <div style={{ display: "flex", gap: 12, justifyContent: "center" }}>
            <Btn onClick={() => { resetLog(); setView("log-book"); }} bg={C.accent} color="#fff">続けて記録</Btn>
            <Btn onClick={() => { resetLog(); setView("home"); }} bg={C.surface} color={C.text2} style={{ border: `1px solid ${C.border}` }}>ホーム</Btn>
          </div>
        </div>
      </div>
    );
  }

  // ═══════ LOG: Step 1 - Book Selection ═══════
  if (view === "log-book") {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => { resetLog(); setView("home"); }} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 12 }}>← 戻る</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 16px" }}>問題集を選択</h2>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {BOOK_ORDER.map(book => {
              const count = problemList.filter(p => p.book === book).length;
              const attemptCount = attempts.filter(a => { const p = problems[a.problem_id]; return p && p.book === book; }).length;
              return (
                <button key={book} onClick={() => { setLogBook(book); setView("log-problem"); }}
                  style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "16px 20px", cursor: "pointer", fontFamily: font, textAlign: "left", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <div>
                    <div style={{ color: C.text, fontSize: 15, fontWeight: 600 }}>{BOOK_SHORT[book] || book}</div>
                    <div style={{ color: C.text3, fontSize: 11, marginTop: 2 }}>{count}問</div>
                  </div>
                  <div style={{ textAlign: "right" }}>
                    <div style={{ color: C.accent, fontSize: 14, fontWeight: 700 }}>{attemptCount}</div>
                    <div style={{ color: C.text3, fontSize: 10 }}>記録</div>
                  </div>
                </button>
              );
            })}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ LOG: Step 2 - Problem Selection ═══════
  if (view === "log-problem") {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView("log-book")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← {BOOK_SHORT[logBook]}</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 12px" }}>問題を選択</h2>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            {bookProblems.map(p => {
              const pa = problemAttempts(p.id);
              const lastAttempt = pa.length > 0 ? pa[0] : null;
              const correctCount = pa.filter(a => a.result === "○").length;
              const wrongCount = pa.filter(a => a.result === "×").length;
              return (
                <button key={p.id} onClick={() => { setLogProblem(p); setLogResult(null); setLogTime(""); setLogMistakes({}); setLogMemo(""); setView("log-result"); }}
                  style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10, padding: "12px 16px", cursor: "pointer", fontFamily: font, textAlign: "left", display: "flex", alignItems: "center", gap: 10 }}>
                  <div style={{ minWidth: 42, textAlign: "center" }}>
                    <div style={{ color: C.text2, fontSize: 11, fontWeight: 700 }}>{p.number.replace(/^問題\s*/, "")}</div>
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ color: C.text, fontSize: 13, fontWeight: 500, lineHeight: 1.4 }}>{p.title}</div>
                    <div style={{ display: "flex", gap: 6, marginTop: 4, alignItems: "center" }}>
                      <RankBadge rank={p.rank} />
                      <ScopeBadge scope={p.scope} />
                      {p.time_min > 0 && <span style={{ color: C.text3, fontSize: 10 }}>{p.time_min}分</span>}
                    </div>
                  </div>
                  <div style={{ textAlign: "right", flexShrink: 0 }}>
                    {pa.length > 0 ? (
                      <>
                        <div style={{ display: "flex", gap: 4, justifyContent: "flex-end" }}>
                          <span style={{ color: C.green, fontSize: 12, fontWeight: 700 }}>{correctCount}○</span>
                          <span style={{ color: C.red, fontSize: 12, fontWeight: 700 }}>{wrongCount}×</span>
                        </div>
                        <div style={{ color: C.text3, fontSize: 9, marginTop: 2 }}>{lastAttempt?.date?.slice(5)}</div>
                      </>
                    ) : (
                      <span style={{ color: C.text3, fontSize: 11 }}>未着手</span>
                    )}
                  </div>
                </button>
              );
            })}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ LOG: Step 3 - Result Entry ═══════
  if (view === "log-result" && logProblem) {
    const mistakeTypes = getMistakeTypes(logProblem.type);
    const canSubmit = logResult !== null;

    return (
      <div style={{ background: C.bg, minHeight: "100vh", display: "flex", flexDirection: "column", fontFamily: font }}>
        <div style={{ flex: 1, overflow: "auto", WebkitOverflowScrolling: "touch", padding: "20px 16px" }}>
          <div style={{ maxWidth: 480, margin: "0 auto" }}>
            <button onClick={() => setView("log-problem")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 問題選択</button>

            {/* Problem info */}
            <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "16px 18px", marginBottom: 12 }}>
              <div style={{ display: "flex", gap: 6, alignItems: "center", marginBottom: 6 }}>
                <span style={{ color: C.accent, fontSize: 11, fontWeight: 700 }}>{BOOK_SHORT[logProblem.book]}</span>
                <span style={{ color: C.text3, fontSize: 11 }}>{logProblem.number}</span>
                <RankBadge rank={logProblem.rank} />
                <ScopeBadge scope={logProblem.scope} />
              </div>
              <div style={{ color: C.text, fontSize: 17, fontWeight: 700, lineHeight: 1.5 }}>{logProblem.title}</div>
              {logProblem.time_min > 0 && <div style={{ color: C.text3, fontSize: 11, marginTop: 4 }}>目安: {logProblem.time_min}分</div>}
            </div>

            {/* Result buttons */}
            <div style={{ display: "flex", gap: 12, marginBottom: 12 }}>
              <button onClick={() => setLogResult("○")}
                style={{ flex: 1, padding: "20px", borderRadius: 14, border: `2px solid ${logResult === "○" ? C.green : C.border}`, background: logResult === "○" ? C.greenDim : C.surface, cursor: "pointer", fontFamily: font, transition: "all 0.15s" }}>
                <div style={{ fontSize: 28, color: C.green, fontWeight: 700 }}>○</div>
                <div style={{ color: logResult === "○" ? C.green : C.text3, fontSize: 12, marginTop: 4 }}>正解</div>
              </button>
              <button onClick={() => setLogResult("×")}
                style={{ flex: 1, padding: "20px", borderRadius: 14, border: `2px solid ${logResult === "×" ? C.red : C.border}`, background: logResult === "×" ? C.redDim : C.surface, cursor: "pointer", fontFamily: font, transition: "all 0.15s" }}>
                <div style={{ fontSize: 28, color: C.red, fontWeight: 700 }}>×</div>
                <div style={{ color: logResult === "×" ? C.red : C.text3, fontSize: 12, marginTop: 4 }}>不正解</div>
              </button>
            </div>

            {/* Time input */}
            <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 18px", marginBottom: 12 }}>
              <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 8 }}>所要時間（分）</div>
              <input type="number" inputMode="numeric" value={logTime} onChange={e => setLogTime(e.target.value)}
                placeholder={logProblem.time_min > 0 ? `目安 ${logProblem.time_min}分` : "分"}
                style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 16, fontFamily: font, boxSizing: "border-box", outline: "none", textAlign: "center" }} />
            </div>

            {/* Mistake types (shown when ×) */}
            {logResult === "×" && (
              <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 18px", marginBottom: 12 }}>
                <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 10 }}>間違いの分類（複数可）</div>
                {mistakeTypes.map(mt => (
                  <label key={mt.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 0", cursor: "pointer", borderBottom: `1px solid ${C.border}` }}>
                    <input type="checkbox" checked={!!logMistakes[mt.id]}
                      onChange={e => setLogMistakes(m => ({ ...m, [mt.id]: e.target.checked }))}
                      style={{ accentColor: C.accent, width: 20, height: 20, flexShrink: 0 }} />
                    <div>
                      <div style={{ color: C.text, fontSize: 14, fontWeight: 500 }}>{mt.label}</div>
                      <div style={{ color: C.text3, fontSize: 11 }}>{mt.desc}</div>
                    </div>
                  </label>
                ))}
              </div>
            )}

            {/* Memo */}
            <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 18px", marginBottom: 20 }}>
              <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 8 }}>メモ</div>
              <textarea value={logMemo} onChange={e => setLogMemo(e.target.value)}
                placeholder="どう間違えたか、気づきなど..."
                style={{ width: "100%", minHeight: 60, background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 12px", fontSize: 13, fontFamily: font, resize: "vertical", outline: "none", boxSizing: "border-box", lineHeight: 1.5 }} />
            </div>
          </div>
        </div>

        {/* Submit button (fixed at bottom) */}
        <div style={{ padding: "10px 16px 14px", flexShrink: 0, background: C.bg, borderTop: `1px solid ${C.border}` }}>
          <div style={{ maxWidth: 480, margin: "0 auto" }}>
            <Btn onClick={submitAttempt} disabled={!canSubmit}
              bg={canSubmit ? C.accent : C.surface3} color={canSubmit ? "#fff" : C.text3}
              style={{ width: "100%", padding: "16px", fontSize: 16 }}>記録する</Btn>
          </div>
        </div>
      </div>
    );
  }

  // ═══════ TOPICS: Category List ═══════
  if (view === "topics-cat") {
    const catCounts = {};
    topics.forEach(t => { catCounts[t.category] = (catCounts[t.category] || 0) + 1; });
    const catList = topicCategories.length > 0 ? topicCategories : Object.keys(catCounts).sort();
    const totalTopics = topics.length;

    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView("home")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 戻る</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 4px" }}>論点学習</h2>
          <div style={{ color: C.text3, fontSize: 11, marginBottom: 16 }}>{totalTopics}件の論点ノート</div>

          {/* Search */}
          <input type="search" value={topicSearch} onChange={e => { setTopicSearch(e.target.value); if (e.target.value.trim()) setView("topics-search"); }}
            placeholder="キーワードで検索..."
            style={{ width: "100%", background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10, color: C.text, padding: "12px 16px", fontSize: 14, fontFamily: font, boxSizing: "border-box", outline: "none", marginBottom: 12 }} />

          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {catList.map(cat => {
              const count = catCounts[cat] || 0;
              return (
                <button key={cat} onClick={() => { setTopicCat(cat); setView("topics-list"); }}
                  style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "16px 20px", cursor: "pointer", fontFamily: font, textAlign: "left", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <span style={{ color: C.text, fontSize: 15, fontWeight: 600 }}>{cat}</span>
                  <span style={{ color: C.accent, fontSize: 14, fontWeight: 700 }}>{count}</span>
                </button>
              );
            })}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ TOPICS: Search Results ═══════
  if (view === "topics-search") {
    const q = topicSearch.trim().toLowerCase();
    const filtered = q ? topics.filter(t =>
      (t.display_name || t.topic || "").toLowerCase().includes(q) ||
      (t.summary || "").toLowerCase().includes(q) ||
      (t.keywords || []).some(k => k.toLowerCase().includes(q)) ||
      (t.category || "").toLowerCase().includes(q) ||
      (t.subcategory || "").toLowerCase().includes(q)
    ) : [];

    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => { setTopicSearch(""); setView("topics-cat"); }} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← カテゴリ</button>
          <input type="search" value={topicSearch} onChange={e => setTopicSearch(e.target.value)} autoFocus
            placeholder="キーワードで検索..."
            style={{ width: "100%", background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10, color: C.text, padding: "12px 16px", fontSize: 14, fontFamily: font, boxSizing: "border-box", outline: "none", marginBottom: 12 }} />
          <div style={{ color: C.text3, fontSize: 11, marginBottom: 12 }}>{filtered.length}件</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            {filtered.slice(0, 50).map(t => (
              <button key={t.topic_id} onClick={() => { setTopicItem(t); setView("topics-detail"); }}
                style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10, padding: "12px 16px", cursor: "pointer", fontFamily: font, textAlign: "left" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 4 }}>
                  <span style={{ color: C.text, fontSize: 13, fontWeight: 600, flex: 1 }}>{t.display_name || t.topic}</span>
                  <StatusBadge status={t.status} />
                  <RankBadge rank={t.importance} />
                </div>
                <div style={{ color: C.text3, fontSize: 11 }}>{t.category} / {t.subcategory}</div>
              </button>
            ))}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ TOPICS: Topic List (by category) ═══════
  if (view === "topics-list" && topicCat) {
    const catTopics = topics.filter(t => t.category === topicCat)
      .sort((a, b) => {
        // Sort: importance A > B > C, then by display_name
        const rankOrder = { A: 0, B: 1, C: 2 };
        const ra = rankOrder[a.importance] ?? 3;
        const rb = rankOrder[b.importance] ?? 3;
        if (ra !== rb) return ra - rb;
        return (a.display_name || a.topic).localeCompare(b.display_name || b.topic, "ja");
      });

    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView("topics-cat")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← カテゴリ</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 4px" }}>{topicCat}</h2>
          <div style={{ color: C.text3, fontSize: 11, marginBottom: 16 }}>{catTopics.length}件</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            {catTopics.map(t => (
              <button key={t.topic_id} onClick={() => { setTopicItem(t); setView("topics-detail"); }}
                style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10, padding: "12px 16px", cursor: "pointer", fontFamily: font, textAlign: "left" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 4 }}>
                  <span style={{ color: C.text, fontSize: 13, fontWeight: 600, flex: 1 }}>{t.display_name || t.topic}</span>
                  <StatusBadge status={t.status} />
                  <RankBadge rank={t.importance} />
                </div>
                <div style={{ color: C.text3, fontSize: 11 }}>
                  {t.subcategory && <span>{t.subcategory}</span>}
                  {t.kome_total > 0 && <span style={{ marginLeft: 8 }}>米{t.kome_total}</span>}
                  {t.keywords && t.keywords.length > 0 && <span style={{ marginLeft: 8 }}>{t.keywords.slice(0, 3).join(", ")}</span>}
                </div>
              </button>
            ))}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ TOPICS: Detail View ═══════
  if (view === "topics-detail" && topicItem) {
    const t = topicItem;
    const sections = [
      { key: "summary", title: "概要", icon: "S", color: C.blue },
      { key: "steps", title: "計算手順", icon: "C", color: C.accent },
      { key: "judgment", title: "判断ポイント", icon: "J", color: C.green },
      { key: "mistakes", title: "間違えやすいポイント", icon: "!", color: C.red },
    ];

    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView(topicCat ? "topics-list" : "topics-search")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 戻る</button>

          {/* Header */}
          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "16px 18px", marginBottom: 12 }}>
            <div style={{ display: "flex", gap: 6, alignItems: "center", marginBottom: 8, flexWrap: "wrap" }}>
              <span style={{ color: C.accent, fontSize: 11, fontWeight: 600 }}>{t.category}</span>
              {t.subcategory && <span style={{ color: C.text3, fontSize: 11 }}>/ {t.subcategory}</span>}
              <RankBadge rank={t.importance} />
              <StatusBadge status={t.status} />
            </div>
            <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 8px", lineHeight: 1.4 }}>{t.display_name || t.topic}</h2>
            <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
              {t.conditions && t.conditions.length > 0 && t.conditions.map(c => (
                <span key={c} style={{ fontSize: 10, padding: "2px 8px", borderRadius: 4, background: C.surface2, color: C.text2 }}>{c}</span>
              ))}
              {t.keywords && t.keywords.length > 0 && t.keywords.map(k => (
                <span key={k} style={{ fontSize: 10, padding: "2px 8px", borderRadius: 4, background: C.blueDim, color: C.blue }}>{k}</span>
              ))}
            </div>
          </div>

          {/* Sections */}
          {sections.map(sec => {
            const content = t[sec.key];
            if (!content) return null;
            return (
              <div key={sec.key} style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "16px 18px", marginBottom: 12 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
                  <span style={{ width: 24, height: 24, borderRadius: 6, background: `${sec.color}20`, color: sec.color, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>{sec.icon}</span>
                  <span style={{ color: C.text, fontSize: 14, fontWeight: 700 }}>{sec.title}</span>
                </div>
                <SectionContent text={content} />
              </div>
            );
          })}

          {/* Mistake items (if any) */}
          {t.mistake_items && t.mistake_items.length > 0 && (
            <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "16px 18px", marginBottom: 12 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
                <span style={{ width: 24, height: 24, borderRadius: 6, background: `${C.red}20`, color: C.red, fontSize: 12, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>X</span>
                <span style={{ color: C.text, fontSize: 14, fontWeight: 700 }}>よくある間違い</span>
              </div>
              {t.mistake_items.map((m, i) => (
                <div key={i} style={{ padding: "8px 0", borderBottom: i < t.mistake_items.length - 1 ? `1px solid ${C.border}` : "none" }}>
                  <div style={{ color: C.red, fontSize: 12, fontWeight: 700, marginBottom: 2 }}>{m.wrong}</div>
                  <div style={{ color: C.green, fontSize: 12 }}>{m.correct}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    );
  }

  // ═══════ TODAY: Problem List ═══════
  if (view === "today" && todayData) {
    const tdTopics = todayData.topics || [];
    // Track which problems have been attempted today
    const todayAttemptIds = new Set(todayAttempts.map(a => a.problem_id));
    const newTopics = tdTopics.filter(t => t.selection_type === "new");
    const reviewTopics = tdTopics.filter(t => t.selection_type !== "new");
    const useSectionGrouping = newTopics.length > 0;

    const renderTopicCard = (topic) => (
      <div key={topic.topic_id} style={{
        background: C.surface,
        border: `1px solid ${C.border}`,
        borderLeft: topic.weak_focus?.active ? `3px solid ${C.red}` : undefined,
        borderRadius: 14,
        padding: "14px 16px",
      }}>
        {/* Topic header */}
        <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8, flexWrap: "wrap" }}>
          <span style={{ color: C.text, fontSize: 14, fontWeight: 700, flex: 1 }}>{topic.topic_name}</span>
          {topic.selection_type === "carryover" && <span style={{ fontSize: 9, padding: "2px 6px", borderRadius: 4, background: C.blueDim, color: C.blue, fontWeight: 600 }}>繰越</span>}
          <ReasonBadge reason={topic.weak_focus?.active ? "弱点集中24h" : topic.reason} />
          <RankBadge rank={topic.importance} />
        </div>
        <div style={{ color: C.text3, fontSize: 10, marginBottom: 10 }}>
          {topic.category} / 間隔Lv.{topic.interval_index}
          {topic.weak_focus?.active && topic.weak_focus?.until_at && (
            <span style={{ color: C.red, fontSize: 10, marginLeft: 8 }}>
              残り {formatRemain(topic.weak_focus.until_at)}
            </span>
          )}
        </div>

        {/* Problems under this topic */}
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          {(topic.problems || []).map(prob => {
            const done = todayAttemptIds.has(prob.problem_id);
            const pa = attempts.filter(a => a.problem_id === prob.problem_id);
            const lastResult = pa.length > 0 ? pa[0].result : null;
            return (
              <button key={prob.problem_id} onClick={() => {
                setTodayProblem(prob); setTodayTopicCtx(topic);
                setPageViewStep("view"); setPvMistakes({}); setPvTime("");
                setHintOpen(false);
                setView("page-view");
              }}
                style={{ background: done ? C.surface2 : C.surface3, border: `1px solid ${done ? C.border : C.border}`, borderRadius: 10, padding: "10px 14px", cursor: "pointer", fontFamily: font, textAlign: "left", display: "flex", alignItems: "center", gap: 10, opacity: done ? 0.7 : 1 }}>
                <div style={{ minWidth: 30, textAlign: "center" }}>
                  {done ? (
                    <span style={{ color: lastResult === "○" ? C.green : C.red, fontSize: 16, fontWeight: 700 }}>{lastResult}</span>
                  ) : (
                    <span style={{ color: C.text3, fontSize: 11 }}>{prob.number?.replace(/^問題\s*/, "") || "-"}</span>
                  )}
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ color: C.text, fontSize: 12, fontWeight: 500, lineHeight: 1.4 }}>{prob.title || `${BOOK_SHORT[prob.book] || prob.book} ${prob.number}`}</div>
                  <div style={{ display: "flex", gap: 6, marginTop: 3, alignItems: "center" }}>
                    <span style={{ color: C.accent, fontSize: 10 }}>{BOOK_SHORT[prob.book] || prob.book}</span>
                    <RankBadge rank={prob.rank} />
                    {prob.type && <span style={{ color: C.text3, fontSize: 9 }}>{prob.type}</span>}
                    {prob.time_min > 0 && <span style={{ color: C.text3, fontSize: 9 }}>{prob.time_min}分</span>}
                  </div>
                </div>
                {prob.page_image_key && (
                  <span style={{ color: C.blue, fontSize: 10, flexShrink: 0 }}>📄</span>
                )}
              </button>
            );
          })}
        </div>
      </div>
    );

    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView("home")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 戻る</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 4px" }}>今日の問題</h2>
          <div style={{ color: C.text3, fontSize: 11, marginBottom: 16 }}>
            {todayData.generated_date} / {todayData.total_topics}論点 {todayData.total_problems}問
          </div>

          {tdTopics.length === 0 ? (
            <div style={{ color: C.text3, textAlign: "center", padding: 40, fontSize: 14 }}>今日の問題はありません</div>
          ) : (
            useSectionGrouping ? (
              <>
                {newTopics.length > 0 && (
                  <div style={{ marginBottom: 16 }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
                      <span style={{ color: C.accent, fontSize: 13, fontWeight: 700 }}>今週の新規</span>
                      <span style={{ background: C.accentDim, color: C.accent, fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 10 }}>{newTopics.reduce((s, t) => s + (t.problems?.length || 0), 0)}問</span>
                    </div>
                    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                      {newTopics.map(topic => renderTopicCard(topic))}
                    </div>
                  </div>
                )}
                {reviewTopics.length > 0 && (
                  <div>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
                      <span style={{ color: C.blue, fontSize: 13, fontWeight: 700 }}>復習</span>
                      <span style={{ background: C.blueDim, color: C.blue, fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 10 }}>{reviewTopics.reduce((s, t) => s + (t.problems?.length || 0), 0)}問</span>
                    </div>
                    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                      {reviewTopics.map(topic => renderTopicCard(topic))}
                    </div>
                  </div>
                )}
              </>
            ) : (
              <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                {tdTopics.map(topic => renderTopicCard(topic))}
              </div>
            )
          )}
        </div>
      </div>
    );
  }

  // ═══════ PAGE VIEW: PDF Image + Result Entry ═══════
  if (view === "page-view" && todayProblem) {
    const mistakeTypes = getMistakeTypes(todayProblem.type || "計算");
    const imageUrl = todayProblem.page_image_key
      ? `${apiBase(apiUrl)}/api/komekome/page-image/${todayProblem.page_image_key}`
      : null;

    // Step: "view" = show image + ○/×, "mistakes" = show mistake selection for ×, "review" = review after ×
    if (pageViewStep === "review") {
      // Find the topic data for this problem
      const topicId = todayTopicCtx?.topic_id;
      const topicData = topicId ? topics.find(t => t.topic_id === topicId) : null;
      const reviewSections = [
        { key: "mistakes", title: "間違えやすいポイント", icon: "!", color: C.red },
        { key: "steps", title: "計算手順", icon: "C", color: C.accent },
        { key: "judgment", title: "判断ポイント", icon: "J", color: C.green },
      ];
      // Resolve related topics
      const relatedTopics = (topicData?.related || []).filter(r => r).map(name => {
        const match = topics.find(t => t.topic === name || t.topic_id.endsWith("/" + name) || t.topic_id.includes(name));
        return match ? { name, topic: match } : { name, topic: null };
      });

      return (
        <div style={{ background: C.bg, minHeight: "100vh", display: "flex", flexDirection: "column", fontFamily: font }}>
          <div style={{ flex: 1, overflow: "auto", WebkitOverflowScrolling: "touch", padding: "20px 16px" }}>
            <div style={{ maxWidth: 480, margin: "0 auto" }}>
              <div style={{ color: C.red, fontSize: 18, fontWeight: 700, textAlign: "center", marginBottom: 4 }}>× 不正解</div>
              <div style={{ color: C.text2, fontSize: 13, textAlign: "center", marginBottom: 16 }}>{todayProblem.title || `${BOOK_SHORT[todayProblem.book]} ${todayProblem.number}`}</div>

              {topicData ? (
                <>
                  {/* Topic header */}
                  <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "12px 16px", marginBottom: 12 }}>
                    <div style={{ display: "flex", gap: 6, alignItems: "center", marginBottom: 4, flexWrap: "wrap" }}>
                      <span style={{ color: C.accent, fontSize: 11, fontWeight: 600 }}>{topicData.category}</span>
                      <RankBadge rank={topicData.importance} />
                    </div>
                    <div style={{ color: C.text, fontSize: 15, fontWeight: 700, lineHeight: 1.4 }}>{topicData.display_name || topicData.topic}</div>
                  </div>

                  {/* Review sections */}
                  {reviewSections.map(sec => {
                    const content = topicData[sec.key];
                    if (!content) return null;
                    return (
                      <div key={sec.key} style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 16px", marginBottom: 12 }}>
                        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 10 }}>
                          <span style={{ width: 22, height: 22, borderRadius: 6, background: `${sec.color}20`, color: sec.color, fontSize: 11, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>{sec.icon}</span>
                          <span style={{ color: C.text, fontSize: 13, fontWeight: 700 }}>{sec.title}</span>
                        </div>
                        <SectionContent text={content} />
                      </div>
                    );
                  })}

                  {/* Related topics */}
                  {relatedTopics.length > 0 && (
                    <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 16px", marginBottom: 12 }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 10 }}>
                        <span style={{ width: 22, height: 22, borderRadius: 6, background: `${C.blue}20`, color: C.blue, fontSize: 11, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>R</span>
                        <span style={{ color: C.text, fontSize: 13, fontWeight: 700 }}>関連論点</span>
                      </div>
                      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                        {relatedTopics.map((rt, i) => (
                          <button key={i} onClick={() => { if (rt.topic) { setTopicItem(rt.topic); setTopicCat(rt.topic.category); resetPageView(); setView("topics-detail"); } }}
                            disabled={!rt.topic}
                            style={{ background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, padding: "10px 14px", cursor: rt.topic ? "pointer" : "default", fontFamily: font, textAlign: "left", display: "flex", alignItems: "center", gap: 8, opacity: rt.topic ? 1 : 0.5 }}>
                            <span style={{ color: C.blue, fontSize: 12 }}>→</span>
                            <span style={{ color: C.text, fontSize: 12 }}>{rt.topic?.display_name || rt.topic?.topic || rt.name}</span>
                          </button>
                        ))}
                      </div>
                    </div>
                  )}
                </>
              ) : (
                <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "24px 16px", marginBottom: 12, textAlign: "center" }}>
                  <div style={{ color: C.text3, fontSize: 13 }}>この問題に対応する論点データがありません</div>
                </div>
              )}
            </div>
          </div>
          <div style={{ padding: "10px 16px 14px", flexShrink: 0, background: C.bg, borderTop: `1px solid ${C.border}` }}>
            <div style={{ maxWidth: 480, margin: "0 auto" }}>
              <Btn onClick={() => { resetPageView(); setView("today"); }} bg={C.accent} color="#fff" style={{ width: "100%", padding: "16px", fontSize: 16 }}>次の問題へ</Btn>
            </div>
          </div>
        </div>
      );
    }

    if (pageViewStep === "mistakes") {
      return (
        <div style={{ background: C.bg, minHeight: "100vh", display: "flex", flexDirection: "column", fontFamily: font }}>
          <div style={{ flex: 1, overflow: "auto", WebkitOverflowScrolling: "touch", padding: "20px 16px" }}>
            <div style={{ maxWidth: 480, margin: "0 auto" }}>
              <button onClick={() => setPageViewStep("view")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 戻る</button>
              <div style={{ color: C.red, fontSize: 18, fontWeight: 700, textAlign: "center", marginBottom: 12 }}>× 不正解</div>
              <div style={{ color: C.text2, fontSize: 13, textAlign: "center", marginBottom: 16 }}>{todayProblem.title || `${BOOK_SHORT[todayProblem.book]} ${todayProblem.number}`}</div>

              {/* Time input */}
              <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 18px", marginBottom: 12 }}>
                <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 8 }}>所要時間（分）</div>
                <input type="number" inputMode="numeric" value={pvTime} onChange={e => setPvTime(e.target.value)}
                  placeholder={todayProblem.time_min > 0 ? `目安 ${todayProblem.time_min}分` : "分"}
                  style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 16, fontFamily: font, boxSizing: "border-box", outline: "none", textAlign: "center" }} />
              </div>

              {/* Mistake types */}
              <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "14px 18px", marginBottom: 20 }}>
                <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 10 }}>間違いの分類（複数可）</div>
                {mistakeTypes.map(mt => (
                  <label key={mt.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 0", cursor: "pointer", borderBottom: `1px solid ${C.border}` }}>
                    <input type="checkbox" checked={!!pvMistakes[mt.id]}
                      onChange={e => setPvMistakes(m => ({ ...m, [mt.id]: e.target.checked }))}
                      style={{ accentColor: C.accent, width: 20, height: 20, flexShrink: 0 }} />
                    <div>
                      <div style={{ color: C.text, fontSize: 14, fontWeight: 500 }}>{mt.label}</div>
                      <div style={{ color: C.text3, fontSize: 11 }}>{mt.desc}</div>
                    </div>
                  </label>
                ))}
              </div>
            </div>
          </div>
          <div style={{ padding: "10px 16px 14px", flexShrink: 0, background: C.bg, borderTop: `1px solid ${C.border}` }}>
            <div style={{ maxWidth: 480, margin: "0 auto" }}>
              <Btn onClick={() => submitPageViewAttempt("×")} bg={C.red} color="#fff" style={{ width: "100%", padding: "16px", fontSize: 16 }}>記録する</Btn>
            </div>
          </div>
        </div>
      );
    }

    // Default: pageViewStep === "view"
    return (
      <div style={{ background: C.bg, minHeight: "100vh", display: "flex", flexDirection: "column", fontFamily: font }}>
        <div style={{ flex: 1, overflow: "auto", WebkitOverflowScrolling: "touch", padding: "20px 16px" }}>
          <div style={{ maxWidth: 480, margin: "0 auto" }}>
            <button onClick={() => { resetPageView(); setView("today"); }} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 8 }}>← 今日の問題</button>

            {/* Problem info */}
            <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "12px 16px", marginBottom: 12 }}>
              <div style={{ display: "flex", gap: 6, alignItems: "center", marginBottom: 4 }}>
                <span style={{ color: C.accent, fontSize: 11, fontWeight: 700 }}>{BOOK_SHORT[todayProblem.book] || todayProblem.book}</span>
                <span style={{ color: C.text3, fontSize: 11 }}>{todayProblem.number}</span>
                <RankBadge rank={todayProblem.rank} />
              </div>
              <div style={{ color: C.text, fontSize: 15, fontWeight: 700, lineHeight: 1.4 }}>{todayProblem.title || "問題"}</div>
              {todayTopicCtx && <div style={{ color: C.text3, fontSize: 10, marginTop: 4 }}>{todayTopicCtx.topic_name} / {todayTopicCtx.reason}</div>}
            </div>

            {/* PDF page image */}
            {imageUrl ? (
              <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: 8, marginBottom: 12, touchAction: "pinch-zoom", overflow: "auto", WebkitOverflowScrolling: "touch" }}>
                <AuthImage src={imageUrl} token={apiToken} alt={`${todayProblem.book} p.${todayProblem.page}`} />
              </div>
            ) : (
              <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "40px 16px", marginBottom: 12, textAlign: "center" }}>
                <div style={{ color: C.text3, fontSize: 13 }}>ページ画像なし</div>
                <div style={{ color: C.text3, fontSize: 11, marginTop: 4 }}>p.{todayProblem.page || "-"}</div>
              </div>
            )}
            {/* Hint button */}
            {(() => {
              const topicId = todayTopicCtx?.topic_id;
              const topicData = topicId ? topics.find(t => t.topic_id === topicId) : null;
              if (!topicData) return null;
              const isTheory = (todayProblem.type || "").includes("理論");
              const hintContent = isTheory
                ? (topicData.statutes || topicData.conditions?.join("\n") || "")
                : (topicData.steps || "");
              if (!hintContent) return null;
              return (
                <div style={{ marginBottom: 12 }}>
                  <button onClick={() => setHintOpen(!hintOpen)}
                    style={{ width: "100%", background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14, padding: "12px 16px", cursor: "pointer", fontFamily: font, textAlign: "left", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                    <span style={{ color: C.purple, fontSize: 13, fontWeight: 600 }}>ヒントを見る</span>
                    <span style={{ color: C.text3, fontSize: 12 }}>{hintOpen ? "▲" : "▼"}</span>
                  </button>
                  {hintOpen && (
                    <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderTop: "none", borderRadius: "0 0 14px 14px", padding: "12px 16px" }}>
                      <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, marginBottom: 8 }}>
                        {isTheory ? "関連条文" : "計算手順"}
                      </div>
                      <SectionContent text={hintContent} />
                    </div>
                  )}
                </div>
              );
            })()}
          </div>
        </div>

        {/* ○/× buttons fixed at bottom */}
        <div style={{ padding: "10px 16px 14px", flexShrink: 0, background: C.bg, borderTop: `1px solid ${C.border}` }}>
          <div style={{ maxWidth: 480, margin: "0 auto", display: "flex", gap: 12 }}>
            <button onClick={() => submitPageViewAttempt("○")}
              style={{ flex: 1, padding: "18px", borderRadius: 14, border: `2px solid ${C.green}`, background: C.greenDim, cursor: "pointer", fontFamily: font }}>
              <div style={{ fontSize: 28, color: C.green, fontWeight: 700 }}>○</div>
              <div style={{ color: C.green, fontSize: 12, marginTop: 2 }}>正解</div>
            </button>
            <button onClick={() => setPageViewStep("mistakes")}
              style={{ flex: 1, padding: "18px", borderRadius: 14, border: `2px solid ${C.red}`, background: C.redDim, cursor: "pointer", fontFamily: font }}>
              <div style={{ fontSize: 28, color: C.red, fontWeight: 700 }}>×</div>
              <div style={{ color: C.red, fontSize: 12, marginTop: 2 }}>不正解</div>
            </button>
          </div>
        </div>
      </div>
    );
  }

  // ═══════ STATS ═══════
  if (view === "stats") {
    return <StatsView attempts={attempts} problems={problems} problemList={problemList} onBack={() => setView("home")} />;
  }

  // ═══════ DASHBOARD ═══════
  if (view === "dashboard") {
    return <DashboardView dashboardData={dashboardData} onBack={() => setView("home")} />;
  }

  // ═══════ HISTORY ═══════
  if (view === "history") {
    const recentAttempts = attempts.slice(0, 100);
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setView("home")} style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 12 }}>← 戻る</button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 16px" }}>記録履歴</h2>
          {recentAttempts.length === 0 ? (
            <div style={{ color: C.text3, textAlign: "center", padding: 40 }}>まだ記録がありません</div>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
              {recentAttempts.map(a => {
                const p = problems[a.problem_id];
                return (
                  <div key={a.id} style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10, padding: "10px 14px" }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
                      <span style={{ color: a.result === "○" ? C.green : C.red, fontSize: 18, fontWeight: 700, width: 24 }}>{a.result}</span>
                      <div style={{ flex: 1 }}>
                        <div style={{ color: C.text, fontSize: 13, fontWeight: 500, lineHeight: 1.3 }}>{p ? p.title : a.problem_id}</div>
                        <div style={{ color: C.text3, fontSize: 10, marginTop: 2 }}>
                          {p ? BOOK_SHORT[p.book] || p.book : ""} {p ? p.number : ""}
                          {a.time_min > 0 && ` / ${a.time_min}分`}
                        </div>
                      </div>
                      <span style={{ color: C.text3, fontSize: 10, flexShrink: 0 }}>{a.date.slice(5)}</span>
                    </div>
                    {a.mistakes && a.mistakes.length > 0 && (
                      <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginLeft: 32 }}>
                        {a.mistakes.map(m => (
                          <span key={m} style={{ fontSize: 9, padding: "2px 6px", borderRadius: 4, background: C.redDim, color: C.red }}>{m}</span>
                        ))}
                      </div>
                    )}
                    {a.memo && <div style={{ color: C.text3, fontSize: 11, marginLeft: 32, marginTop: 4 }}>{a.memo}</div>}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>
    );
  }

  // ═══════ HOME ═══════
  const todayCorrect = todayAttempts.filter(a => a.result === "○").length;
  const todayWrong = todayAttempts.filter(a => a.result === "×").length;
  const todayRate = todayAttempts.length > 0 ? Math.round(todayCorrect / todayAttempts.length * 100) : null;

  return (
    <div style={{ background: C.bg, minHeight: "100vh", padding: "36px 16px", fontFamily: font }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;600;700&display=swap');
        @keyframes fadeUp{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}
      `}</style>
      <div style={{ maxWidth: 480, margin: "0 auto" }}>
        {/* Header */}
        <div style={{ textAlign: "center", marginBottom: 24, animation: "fadeUp 0.5s ease" }}>
          <h1 style={{ color: C.text, fontSize: 22, fontWeight: 700, margin: 0 }}>演習記録</h1>
          <p style={{ color: C.text3, fontSize: 12, marginTop: 4 }}>法人税法 問題演習トラッカー</p>
          {apiToken && (
            <div style={{ display: "flex", justifyContent: "center", alignItems: "center", gap: 6, marginTop: 6 }}>
              <div style={{ width: 6, height: 6, borderRadius: "50%", background: syncStatus === "synced" ? C.green : syncStatus === "error" ? C.red : C.text3 }} />
              <span style={{ color: C.text3, fontSize: 10 }}>{syncStatus === "synced" ? "Synced" : syncStatus === "offline" ? "Offline" : syncStatus === "error" ? "Error" : ""}</span>
            </div>
          )}
        </div>

        {/* Main CTA */}
        <div style={{ animation: "fadeUp 0.5s ease 0.05s both" }}>
          <Btn onClick={() => { resetLog(); setView("log-book"); }}
            bg={C.accent} color="#fff"
            style={{ width: "100%", padding: "18px", fontSize: 17, borderRadius: 14, boxShadow: `0 4px 24px ${C.accent}30` }}>
            記録する
          </Btn>
        </div>

        {/* Today's problems CTA */}
        {todayData && todayData.topics && todayData.topics.length > 0 && (
          <div style={{ marginTop: 12, animation: "fadeUp 0.5s ease 0.07s both" }}>
            <Btn onClick={() => setView("today")}
              bg={C.surface} color={C.accent}
              style={{ width: "100%", padding: "16px", fontSize: 15, border: `1px solid ${C.accent}40`, borderRadius: 14, display: "flex", justifyContent: "center", alignItems: "center", gap: 10 }}>
              <span>今日の問題</span>
              <span style={{ background: C.accent, color: "#fff", fontSize: 12, fontWeight: 700, padding: "2px 8px", borderRadius: 10 }}>{todayData.total_problems}</span>
            </Btn>
          </div>
        )}

        {/* Today's stats */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr 1fr", gap: 8, marginTop: 16, animation: "fadeUp 0.5s ease 0.1s both" }}>
          {[
            { v: todayAttempts.length, l: "今日", c: C.accent },
            { v: todayCorrect, l: "正解", c: C.green },
            { v: todayWrong, l: "不正解", c: C.red },
            { v: todayRate !== null ? `${todayRate}%` : "-", l: "正答率", c: todayRate >= 80 ? C.green : todayRate >= 60 ? C.blue : todayRate !== null ? C.red : C.text3 },
          ].map((s, i) => (
            <div key={i} style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "14px 8px", textAlign: "center" }}>
              <div style={{ color: s.c, fontSize: 22, fontWeight: 700 }}>{s.v}</div>
              <div style={{ color: C.text3, fontSize: 10, marginTop: 2 }}>{s.l}</div>
            </div>
          ))}
        </div>

        {/* Recent attempts */}
        {todayAttempts.length > 0 && (
          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "14px 18px", marginTop: 12, animation: "fadeUp 0.5s ease 0.15s both" }}>
            <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 10 }}>今日の記録</div>
            {todayAttempts.slice(0, 5).map(a => {
              const p = problems[a.problem_id];
              return (
                <div key={a.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 0", borderBottom: `1px solid ${C.border}` }}>
                  <span style={{ color: a.result === "○" ? C.green : C.red, fontSize: 16, fontWeight: 700, width: 20 }}>{a.result}</span>
                  <span style={{ color: C.text2, fontSize: 12, flex: 1 }}>{p ? p.title : a.problem_id}</span>
                  {a.time_min > 0 && <span style={{ color: C.text3, fontSize: 10 }}>{a.time_min}分</span>}
                </div>
              );
            })}
            {todayAttempts.length > 5 && (
              <div style={{ color: C.text3, fontSize: 11, textAlign: "center", marginTop: 8 }}>他 {todayAttempts.length - 5}件</div>
            )}
          </div>
        )}

        {/* Topics CTA */}
        {topics.length > 0 && (
          <div style={{ marginTop: 16, animation: "fadeUp 0.5s ease 0.15s both" }}>
            <Btn onClick={() => setView("topics-cat")}
              bg={C.surface} color={C.blue}
              style={{ width: "100%", padding: "16px", fontSize: 15, border: `1px solid ${C.blue}40`, borderRadius: 14 }}>
              論点学習 ({topics.length})
            </Btn>
          </div>
        )}

        {/* Navigation */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 10, marginTop: 10, animation: "fadeUp 0.5s ease 0.2s both" }}>
          <Btn onClick={() => setView("stats")} bg={C.surface} color={C.text2} style={{ border: `1px solid ${C.border}` }}>分析</Btn>
          <Btn onClick={() => setView("dashboard")} bg={C.surface} color={C.text2} style={{ border: `1px solid ${C.border}` }}>カテゴリ進捗</Btn>
          <Btn onClick={() => setView("history")} bg={C.surface} color={C.text2} style={{ border: `1px solid ${C.border}` }}>履歴</Btn>
        </div>
        <div style={{ marginTop: 10, animation: "fadeUp 0.5s ease 0.25s both" }}>
          <Btn onClick={() => setView("settings")} bg={C.surface} color={C.text3}
            style={{ width: "100%", border: `1px solid ${C.border}`, fontSize: 12, padding: "10px" }}>設定</Btn>
        </div>

        {/* Problem count */}
        <div style={{ textAlign: "center", marginTop: 20, animation: "fadeUp 0.5s ease 0.3s both" }}>
          <span style={{ color: C.text3, fontSize: 11 }}>{problemList.length}問 / {attempts.length}記録</span>
        </div>
      </div>
    </div>
  );
}

// ── Mount ──
const root = createRoot(document.getElementById("root"));
root.render(<App />);
