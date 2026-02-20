import { useState, useEffect, useCallback, useRef } from "react";
import { createRoot } from "react-dom/client";

// ── Storage (localStorage + cookie for token persistence across PWA modes) ──
function load(key, fb) {
  try {
    const r = localStorage.getItem(key);
    return r ? JSON.parse(r) : fb;
  } catch { return fb; }
}
function save(key, v) {
  try { localStorage.setItem(key, JSON.stringify(v)); } catch (e) { console.error(e); }
}
function setCookie(name, value, days = 365) {
  const d = new Date();
  d.setTime(d.getTime() + days * 86400000);
  document.cookie = `${name}=${encodeURIComponent(value)};expires=${d.toUTCString()};path=/;SameSite=Strict;Secure`;
}
function getCookie(name) {
  const m = document.cookie.match(new RegExp(`(?:^|;)\\s*${name}=([^;]*)`));
  return m ? decodeURIComponent(m[1]) : "";
}

// ── API Sync ──
function apiBase(url) {
  // 空 or 未設定 → 相対パス（同一オリジン、CORS不要）
  if (!url) return "";
  return url.replace(/\/+$/, "");
}

async function apiFetch(url, token, options = {}) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 15000);
  try {
    const res = await fetch(url, {
      ...options,
      signal: controller.signal,
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        ...(options.headers || {}),
      },
    });
    if (!res.ok) throw new Error(`API error: ${res.status}`);
    return res.json();
  } finally {
    clearTimeout(timeoutId);
  }
}

function vaultToLocal(q) {
  const displayName = q.display_name || q.topic_name.replace(/_/g, " ");
  return {
    id: `vault_${q.topic_id.replace(/\//g, "_")}`,
    question: displayName,
    type: (q.type || [])[0] || "計算",
    sources: q.sources || [],
    summary: q.summary || "",
    steps: q.steps || "",
    judgment: q.judgment || "",
    mistakes: q.mistakes || "",
    mistakeItems: q.mistake_items || [],
    deck: q.category || "Vault",
    komeTotal: 0,
    intervalIndex: q.intervalIndex || 0,
    nextReview: null,
    lastReviewed: null,
    graduated: false,
    graduatedAt: null,
    history: [],
    createdAt: today(),
    source: "vault",
    topicId: q.topic_id,
  };
}

function buildResultsPayload(problems) {
  const now = today();
  const sessionId = `pwa_${Date.now().toString(36)}`;
  const vaultProblems = problems.filter(p => p.source === "vault" && p.history && p.history.length > 0);
  const results = vaultProblems
    .filter(p => {
      const lastEntry = p.history[p.history.length - 1];
      return lastEntry && lastEntry.date === now;
    })
    .map(p => {
      const lastEntry = p.history[p.history.length - 1];
      return {
        topic_id: p.topicId,
        kome_count: p.komeTotal || 0,
        correct: lastEntry.result === "○",
        time_seconds: lastEntry.timeSeconds || 0,
        mistakes: lastEntry.result !== "○" && lastEntry.memo ? [lastEntry.memo] : [],
        intervalIndex: p.intervalIndex || 0,
      };
    });
  return { session_date: now, session_id: sessionId, results };
}

// ── Helpers ──
function fmtTimer(sec) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}:${s < 10 ? "0" : ""}${s}`;
}

// ── Constants ──
const INTERVALS = [3, 7, 14, 28];
const SESSION_KOME_MAX = 4;
const REINSERT_GAP = 3;
const font = "'Noto Sans JP', -apple-system, sans-serif";

function today() { return new Date().toISOString().split("T")[0]; }
function addDays(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x.toISOString().split("T")[0]; }
function shuffle(a) { const b = [...a]; for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; }
function fmtDate(d) { if (!d) return "-"; const [, m, day] = d.split("-"); return `${+m}/${+day}`; }

const C = {
  bg: "#0f1419", surface: "#1a1f2e", surface2: "#222838", surface3: "#2a3142",
  border: "#333b4f", kome: "#ff8b3d", komeDim: "rgba(255,139,61,0.12)",
  green: "#3dd68c", greenDim: "rgba(61,214,140,0.12)",
  red: "#ff6b6b", redDim: "rgba(255,107,107,0.12)",
  blue: "#5b9cf6", blueDim: "rgba(91,156,246,0.12)",
  purple: "#a78bfa",
  text: "#e8ecf1", text2: "#9ba4b5", text3: "#5f6980", gold: "#ffc847",
};

// ── KomeDots (cumulative, never shrinks) ──
function KomeDots({ count, size = 10, max }) {
  const display = max ? Math.min(count, max) : count;
  const overflow = max && count > max;
  const dots = Math.min(display, 20);
  return (
    <div style={{ display: "flex", gap: 3, alignItems: "center", flexWrap: "wrap" }}>
      {Array.from({ length: dots }).map((_, i) => (
        <div key={i} style={{
          width: size, height: size, borderRadius: 2,
          background: C.kome, border: `1px solid ${C.kome}`,
          transition: "all 0.3s",
        }} />
      ))}
      {overflow && <span style={{ color: C.kome, fontSize: size - 1, fontWeight: 700 }}>+{count - max}</span>}
    </div>
  );
}

// ── Session Kome (cycle progress toward 4) ──
function SessionDots({ count }) {
  return (
    <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
      {Array.from({ length: SESSION_KOME_MAX }).map((_, i) => (
        <div key={i} style={{
          width: 12, height: 12, borderRadius: 2,
          background: i < count ? C.kome : C.surface3,
          border: `1.5px solid ${i < count ? C.kome : C.border}`,
          transition: "all 0.3s", transform: i < count ? "scale(1.15)" : "scale(1)",
        }} />
      ))}
      <span style={{ color: C.text3, fontSize: 10, marginLeft: 4 }}>今回 {count}/4</span>
    </div>
  );
}

function IntervalBadge({ intervalIndex }) {
  const labels = ["初回", "3日後", "7日後", "14日後", "28日後", "卒業"];
  const colors = [C.text3, C.blue, C.blue, C.kome, C.kome, C.green];
  const idx = Math.min(intervalIndex || 0, 5);
  return (
    <span style={{
      fontSize: 10, padding: "2px 8px", borderRadius: 4,
      background: `${colors[idx]}20`, color: colors[idx], fontWeight: 600,
    }}>{labels[idx]}</span>
  );
}

function Btn({ onClick, disabled, children, bg, color, style: extra = {} }) {
  const [pressed, setPressed] = useState(false);
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      onTouchStart={() => setPressed(true)}
      onTouchEnd={() => setPressed(false)}
      onMouseDown={() => setPressed(true)}
      onMouseUp={() => setPressed(false)}
      onMouseLeave={() => setPressed(false)}
      style={{
        background: bg, color, border: "none", borderRadius: 10,
        padding: "14px 24px", fontSize: 15, fontWeight: 600,
        cursor: disabled ? "default" : "pointer", fontFamily: font,
        transition: "all 0.1s",
        opacity: disabled ? 0.5 : pressed ? 0.7 : 1,
        transform: pressed ? "scale(0.96)" : "scale(1)",
        ...extra,
      }}
    >{children}</button>
  );
}

// ═══════ MAIN APP ═══════
function KomeKomeV2() {
  const [problems, setProblems] = useState([]);
  const [queue, setQueue] = useState([]);
  const [curIdx, setCurIdx] = useState(0);
  const [sessionKomeMap, setSessionKomeMap] = useState({});
  const [showAns, setShowAns] = useState(false);
  const [stats, setStats] = useState({ correct: 0, wrong: 0, cycleComplete: 0 });
  const [timerStart, setTimerStart] = useState(null);
  const [timerElapsed, setTimerElapsed] = useState(0);
  const [checkedMistakes, setCheckedMistakes] = useState({});
  const [mistakeMemo, setMistakeMemo] = useState("");
  const [view, setView] = useState("home");
  const [sessionActive, setSessionActive] = useState(false);
  const [feedback, setFeedback] = useState(null);
  const [loaded, setLoaded] = useState(false);
  const [newQ, setNewQ] = useState("");
  const [newA, setNewA] = useState("");
  const [newDeck, setNewDeck] = useState("デフォルト");
  const [decks, setDecks] = useState(["デフォルト"]);
  const [deckFilter, setDeckFilter] = useState("all");
  const [bulkMode, setBulkMode] = useState(false);
  const [bulkText, setBulkText] = useState("");
  const [editId, setEditId] = useState(null);
  const [editQ, setEditQ] = useState("");
  const [editA, setEditA] = useState("");
  const [exportText, setExportText] = useState(null);
  const [historyView, setHistoryView] = useState(null);
  const [syncStatus, setSyncStatus] = useState("idle");
  const [syncMsg, setSyncMsg] = useState("");
  const [showSettings, setShowSettings] = useState(false);
  const [apiToken, setApiToken] = useState("");
  const [apiTokenInput, setApiTokenInput] = useState("");
  const [apiUrl, setApiUrl] = useState("");
  const [apiUrlInput, setApiUrlInput] = useState("");
  const fbTimer = useRef(null);

  // ── API sync: fetch import on load, merge vault questions ──
  const syncFromAPI = useCallback(async (currentProblems, token, url) => {
    if (!token) return currentProblems;
    setSyncStatus("syncing");
    try {
      const importData = await apiFetch(`${apiBase(url)}/api/komekome/import`, token);
      const questions = importData.questions || [];
      // キャッシュ保存（オフライン用）
      save("kk2-api-cache", importData);

      // マージ: 新規追加 + 既存問題のテキスト更新（学習進捗は保持）
      let merged = [...currentProblems];
      let added = 0, updated = 0;
      for (const q of questions) {
        const vaultId = `vault_${q.topic_id.replace(/\//g, "_")}`;
        const fresh = vaultToLocal(q);
        const idx = merged.findIndex(p => p.id === vaultId);
        if (idx === -1) {
          merged.push(fresh);
          added++;
        } else {
          // テキスト更新、学習進捗は保持
          const old = merged[idx];
          if (old.question !== fresh.question || old.answer !== fresh.answer) {
            merged[idx] = { ...old, question: fresh.question, type: fresh.type, sources: fresh.sources, summary: fresh.summary, steps: fresh.steps, judgment: fresh.judgment, mistakes: fresh.mistakes, mistakeItems: fresh.mistakeItems, deck: fresh.deck };
            updated++;
          }
        }
      }
      setSyncStatus("synced");
      const msgs = [];
      if (added) msgs.push(`${added}問追加`);
      if (updated) msgs.push(`${updated}問更新`);
      setSyncMsg(msgs.length ? msgs.join(", ") : "最新");
      return merged;
    } catch (e) {
      console.error("API sync error:", e);
      // オフラインフォールバック: キャッシュから読む
      try {
        const cached = load("kk2-api-cache", null);
        if (cached && cached.questions) {
          let merged = [...currentProblems];
          let added = 0, updated = 0;
          for (const q of cached.questions) {
            const vaultId = `vault_${q.topic_id.replace(/\//g, "_")}`;
            const fresh = vaultToLocal(q);
            const idx = merged.findIndex(p => p.id === vaultId);
            if (idx === -1) {
              merged.push(fresh);
              added++;
            } else {
              const old = merged[idx];
              if (old.question !== fresh.question || old.answer !== fresh.answer) {
                merged[idx] = { ...old, question: fresh.question, type: fresh.type, sources: fresh.sources, summary: fresh.summary, steps: fresh.steps, judgment: fresh.judgment, mistakes: fresh.mistakes, mistakeItems: fresh.mistakeItems, deck: fresh.deck };
                updated++;
              }
            }
          }
          setSyncStatus("offline");
          const offMsgs = [];
          if (added) offMsgs.push(`${added}問追加`);
          if (updated) offMsgs.push(`${updated}問更新`);
          setSyncMsg(`オフライン${offMsgs.length ? `（${offMsgs.join(", ")}）` : ""}`);
          return merged;
        }
      } catch {}
      setSyncStatus("error");
      setSyncMsg(e.message || "同期エラー");
      return currentProblems;
    }
  }, []);

  // ── API sync: push results after session ──
  const pushResultsToAPI = useCallback(async (currentProblems) => {
    const token = load("kk2-api-token", "");
    const url = load("kk2-api-url", "");
    if (!token) return;
    try {
      const payload = buildResultsPayload(currentProblems);
      if (!payload.results.length) return;
      await apiFetch(`${apiBase(url)}/api/komekome/result`, token, {
        method: "POST",
        body: JSON.stringify(payload),
      });
      setSyncMsg("結果送信済み");
      // pendingSync をクリア
      save("kk2-pendingSync", null);
    } catch (e) {
      console.error("Push results error:", e);
      // オフライン: pendingSync にキュー保存
      const payload = buildResultsPayload(currentProblems);
      const pending = load("kk2-pendingSync", []);
      pending.push(payload);
      save("kk2-pendingSync", pending);
      setSyncStatus("error");
      setSyncMsg("結果送信失敗（次回リトライ）");
    }
  }, []);

  // ── Retry pending sync on load ──
  const retryPendingSync = useCallback(async (token, url) => {
    if (!token) return;
    const pending = load("kk2-pendingSync", []);
    if (!pending || !pending.length) return;
    const remaining = [];
    for (const payload of pending) {
      try {
        await apiFetch(`${apiBase(url)}/api/komekome/result`, token, {
          method: "POST",
          body: JSON.stringify(payload),
        });
      } catch {
        remaining.push(payload);
      }
    }
    save("kk2-pendingSync", remaining.length ? remaining : null);
  }, []);

  useEffect(() => {
    // URL hash でトークン自動セットアップ: komekome.pages.dev/#token=xxx
    // Cookie にも保存 → ホーム画面追加後も引き継がれる
    const hash = location.hash;
    if (hash.startsWith("#token=")) {
      const t = decodeURIComponent(hash.slice(7));
      if (t) {
        save("kk2-api-token", t);
        save("kk2-api-url", "");
        setCookie("kk2_token", t);
        history.replaceState(null, "", location.pathname);
      }
    }

    // localStorage → cookie fallback（Safari → standalone 移行対応）
    let savedToken = load("kk2-api-token", "");
    if (!savedToken) {
      const cookieToken = getCookie("kk2_token");
      if (cookieToken) {
        savedToken = cookieToken;
        save("kk2-api-token", savedToken);
      }
    }
    const savedUrl = load("kk2-api-url", "");
    setApiToken(savedToken);
    setApiTokenInput(savedToken);
    setApiUrl(savedUrl);
    setApiUrlInput(savedUrl);
    let probs = load("kk2-problems", []);
    setDecks(load("kk2-decks", ["デフォルト"]));

    (async () => {
      if (savedToken) {
        await retryPendingSync(savedToken, savedUrl);
        probs = await syncFromAPI(probs, savedToken, savedUrl);
      }
      setProblems(probs);
      setLoaded(true);
    })();
  }, [syncFromAPI, retryPendingSync]);

  useEffect(() => { if (loaded) save("kk2-problems", problems); }, [problems, loaded]);
  useEffect(() => { if (loaded) save("kk2-decks", decks); }, [decks, loaded]);

  const flash = useCallback((t) => {
    setFeedback(t);
    if (fbTimer.current) clearTimeout(fbTimer.current);
    fbTimer.current = setTimeout(() => setFeedback(null), 700);
  }, []);

  // ── Timer tick ──
  useEffect(() => {
    if (!timerStart) return;
    const iv = setInterval(() => setTimerElapsed(Math.floor((Date.now() - timerStart) / 1000)), 1000);
    return () => clearInterval(iv);
  }, [timerStart]);

  // ── Build session ──
  const startSession = useCallback(() => {
    const now = today();
    const due = problems.filter(p =>
      !p.graduated && (!p.nextReview || p.nextReview <= now)
    );
    if (!due.length) return;
    setQueue(shuffle(due.map(p => p.id)));
    setCurIdx(0);
    setSessionKomeMap({});
    setShowAns(false);
    setStats({ correct: 0, wrong: 0, cycleComplete: 0 });
    setTimerStart(Date.now());
    setTimerElapsed(0);
    setCheckedMistakes({});
    setMistakeMemo("");
    setSessionActive(true);
    setView("session");
  }, [problems]);

  const curProblem = sessionActive && curIdx < queue.length
    ? problems.find(p => p.id === queue[curIdx]) : null;
  const curSessionKome = curProblem ? (sessionKomeMap[curProblem.id] || 0) : 0;
  const sessionDone = view === "session" && sessionActive && (!curProblem || curIdx >= queue.length);
  const pushDoneRef = useRef(false);

  // ── Auto-push results on session complete ──
  useEffect(() => {
    if (sessionDone && !pushDoneRef.current) {
      pushDoneRef.current = true;
      pushResultsToAPI(problems);
    }
    if (!sessionDone) pushDoneRef.current = false;
  }, [sessionDone, problems, pushResultsToAPI]);

  // ── Handle answer ──
  const advanceToNext = useCallback(() => {
    setCurIdx(i => i + 1);
    setShowAns(false);
    setTimerStart(Date.now());
    setTimerElapsed(0);
    setCheckedMistakes({});
    setMistakeMemo("");
  }, []);

  const handleAnswer = useCallback((correct) => {
    if (!curProblem) return;
    const pid = curProblem.id;
    const now = today();
    const seconds = timerElapsed;
    const selectedMistakes = Object.keys(checkedMistakes).filter(k => checkedMistakes[k]);
    const memo = mistakeMemo.trim();

    const entry = {
      date: now,
      result: correct ? "○" : "×",
      komeTotal: 0,
      time_seconds: seconds,
      ...(selectedMistakes.length ? { mistakes: selectedMistakes } : {}),
      ...(memo ? { memo } : {}),
    };

    if (correct) {
      flash("correct");
      setStats(s => ({ ...s, correct: s.correct + 1 }));

      setProblems(prev => prev.map(p => {
        if (p.id !== pid) return p;
        const np = { ...p };
        entry.komeTotal = np.komeTotal;
        np.history = [...(np.history || []), entry];
        np.lastReviewed = now;
        const nextInt = (np.intervalIndex || 0) + 1;
        if (nextInt > INTERVALS.length) {
          np.graduated = true;
          np.nextReview = null;
          np.graduatedAt = now;
        } else {
          np.intervalIndex = nextInt;
          np.nextReview = addDays(now, INTERVALS[nextInt - 1]);
        }
        return np;
      }));

      setTimeout(advanceToNext, 500);

    } else {
      flash("wrong");
      setStats(s => ({ ...s, wrong: s.wrong + 1 }));
      const newSessionKome = curSessionKome + 1;

      setProblems(prev => prev.map(p => {
        if (p.id !== pid) return p;
        const np = { ...p };
        np.komeTotal = (np.komeTotal || 0) + 1;
        entry.komeTotal = np.komeTotal;
        np.history = [...(np.history || []), entry];
        np.lastReviewed = now;
        return np;
      }));

      if (newSessionKome >= SESSION_KOME_MAX) {
        setStats(s => ({ ...s, cycleComplete: s.cycleComplete + 1 }));
        setSessionKomeMap(m => ({ ...m, [pid]: 0 }));

        setProblems(prev => prev.map(p => {
          if (p.id !== pid) return p;
          const np = { ...p };
          const nextInt = (np.intervalIndex || 0) + 1;
          if (nextInt > INTERVALS.length) {
            np.graduated = true;
            np.nextReview = null;
            np.graduatedAt = now;
          } else {
            np.intervalIndex = nextInt;
            np.nextReview = addDays(now, INTERVALS[nextInt - 1]);
          }
          return np;
        }));

        setTimeout(advanceToNext, 500);
      } else {
        setSessionKomeMap(m => ({ ...m, [pid]: newSessionKome }));
        setQueue(q => {
          const nq = [...q];
          const insertAt = Math.min(curIdx + 1 + REINSERT_GAP, nq.length);
          nq.splice(insertAt, 0, pid);
          return nq;
        });
        setTimeout(advanceToNext, 500);
      }
    }
  }, [curProblem, curSessionKome, curIdx, flash, timerElapsed, checkedMistakes, mistakeMemo, advanceToNext]);

  // ── Add problem ──
  const addProblem = useCallback(() => {
    if (!newQ.trim()) return;
    setProblems(prev => [...prev, {
      id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      question: newQ.trim(), answer: newA.trim(), deck: newDeck,
      komeTotal: 0, intervalIndex: 0, nextReview: null,
      lastReviewed: null, graduated: false, graduatedAt: null,
      history: [], createdAt: today(), source: "manual",
    }]);
    setNewQ(""); setNewA("");
  }, [newQ, newA, newDeck]);

  const addBulk = useCallback(() => {
    const lines = bulkText.split("\n").filter(l => l.trim());
    const np = lines.map(line => {
      const [q, a] = line.split("\t").length > 1 ? line.split("\t") : line.split("|");
      return {
        id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
        question: (q || line).trim(), answer: (a || "").trim(), deck: newDeck,
        komeTotal: 0, intervalIndex: 0, nextReview: null,
        lastReviewed: null, graduated: false, graduatedAt: null,
        history: [], createdAt: today(), source: "manual",
      };
    });
    setProblems(prev => [...prev, ...np]);
    setBulkText(""); setBulkMode(false);
  }, [bulkText, newDeck]);

  // ── Export to Obsidian Markdown ──
  const exportObsidian = useCallback(() => {
    const now = today();
    let md = `# コメコメ暗記 進捗レポート\n\nエクスポート日: ${now}\n\n`;
    md += `## サマリー\n\n`;
    md += `| 指標 | 値 |\n|---|---|\n`;
    md += `| 全問題数 | ${problems.length} |\n`;
    md += `| 卒業済み | ${problems.filter(p => p.graduated).length} |\n`;
    md += `| 総コメ数 | ${problems.reduce((s, p) => s + (p.komeTotal || 0), 0)} |\n`;
    md += `| 今日の対象 | ${problems.filter(p => !p.graduated && (!p.nextReview || p.nextReview <= now)).length} |\n\n`;

    const deckSet = [...new Set(problems.map(p => p.deck))];
    md += `## デッキ別\n\n`;
    md += `| デッキ | 問題数 | 卒業 | 総コメ | コメ率 |\n|---|---|---|---|---|\n`;
    deckSet.forEach(d => {
      const dp = problems.filter(p => p.deck === d);
      const totalH = dp.reduce((s, p) => s + (p.history || []).length, 0);
      const totalK = dp.reduce((s, p) => s + (p.komeTotal || 0), 0);
      const rate = totalH ? Math.round(totalK / totalH * 100) : 0;
      md += `| ${d} | ${dp.length} | ${dp.filter(p => p.graduated).length} | ${totalK} | ${rate}% |\n`;
    });

    md += `\n## 問題別コメ経過\n\n`;
    const sorted = [...problems].sort((a, b) => (b.komeTotal || 0) - (a.komeTotal || 0));
    sorted.forEach(p => {
      const komeBar = "🟧".repeat(Math.min(p.komeTotal || 0, 20));
      const statusTag = p.graduated ? " ✅卒業" : ` 次回: ${p.nextReview || "未定"}`;
      md += `### ${p.question}\n\n`;
      md += `- デッキ: ${p.deck}\n`;
      md += `- 累積コメ: **${p.komeTotal || 0}** ${komeBar}\n`;
      md += `- ステージ: ${["初回", "3日後", "7日後", "14日後", "28日後", "卒業"][Math.min(p.intervalIndex || 0, 5)]}${statusTag}\n`;

      if (p.history && p.history.length > 0) {
        md += `- 履歴:\n\n`;
        md += `| 日付 | 結果 | 累積コメ |\n|---|---|---|\n`;
        p.history.forEach(h => {
          md += `| ${h.date} | ${h.result} | ${h.komeTotal} |\n`;
        });
      }
      md += `\n`;
    });

    setExportText(md);
  }, [problems]);

  // ── Stats ──
  const now = today();
  const dueCount = problems.filter(p => !p.graduated && (!p.nextReview || p.nextReview <= now)).length;
  const graduatedCount = problems.filter(p => p.graduated).length;
  const totalKome = problems.reduce((s, p) => s + (p.komeTotal || 0), 0);
  const upcoming = INTERVALS.map(d => ({
    days: d,
    count: problems.filter(p => p.nextReview === addDays(now, d)).length,
  }));

  const filteredProblems = deckFilter === "all" ? problems : problems.filter(p => p.deck === deckFilter);

  if (!loaded) return (
    <div style={{ background: C.bg, minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center" }}>
      <span style={{ color: C.text3, fontFamily: font }}>読み込み中...</span>
    </div>
  );

  // ═══════ SETTINGS ═══════
  if (showSettings) {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 480, margin: "0 auto" }}>
          <button onClick={() => setShowSettings(false)}
            style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 12 }}>
            ← 戻る
          </button>
          <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: "0 0 20px" }}>API 同期設定</h2>

          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: 16, marginBottom: 16 }}>
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 6 }}>API URL（空欄 = 同一サーバー）</div>
            <input
              type="url"
              value={apiUrlInput}
              onChange={e => setApiUrlInput(e.target.value)}
              placeholder="空欄でOK（別サーバー時のみ入力）"
              style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 14, fontFamily: "monospace", marginBottom: 10, boxSizing: "border-box", outline: "none" }}
            />
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 6 }}>API Token</div>
            <input
              type="password"
              value={apiTokenInput}
              onChange={e => setApiTokenInput(e.target.value)}
              placeholder="your-secret-token"
              style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 14, fontFamily: "monospace", marginBottom: 10, boxSizing: "border-box", outline: "none" }}
            />
            <div style={{ display: "flex", gap: 8 }}>
              <Btn onClick={async () => {
                const newToken = apiTokenInput.trim();
                const newUrl = apiUrlInput.trim().replace(/\/+$/, "");
                setApiToken(newToken);
                setApiUrl(newUrl);
                save("kk2-api-token", newToken);
                save("kk2-api-url", newUrl);
                setCookie("kk2_token", newToken);
                if (newToken) {
                  setSyncStatus("syncing");
                  setSyncMsg("テスト中...");
                  try {
                    const ctrl = new AbortController();
                    const timer = setTimeout(() => ctrl.abort(), 10000);
                    const testUrl = `${apiBase(newUrl)}/api/komekome/import`;
                    const res = await fetch(testUrl, {
                      method: "GET",
                      headers: { Authorization: `Bearer ${newToken}` },
                      signal: ctrl.signal,
                    });
                    clearTimeout(timer);
                    if (res.status === 401) {
                      setSyncStatus("error");
                      setSyncMsg("認証エラー: トークンが不正です");
                    } else if (!res.ok) {
                      setSyncStatus("error");
                      setSyncMsg(`サーバーエラー: ${res.status}`);
                    } else {
                      await res.json();
                      setSyncStatus("synced");
                      setSyncMsg("接続OK");
                    }
                  } catch (e) {
                    setSyncStatus("error");
                    setSyncMsg(`接続失敗: ${e.message || "ネットワークエラー"}`);
                  }
                } else {
                  setSyncStatus("idle");
                  setSyncMsg("トークンを入力してください");
                }
              }} bg={syncStatus === "syncing" ? C.surface3 : C.kome} disabled={syncStatus === "syncing"} color="#fff" style={{ flex: 1, padding: "10px" }}>{syncStatus === "syncing" ? "テスト中..." : "保存 & テスト"}</Btn>
              <Btn onClick={() => {
                setApiTokenInput("");
                setApiUrlInput("");
                setApiToken("");
                setApiUrl("");
                save("kk2-api-token", "");
                save("kk2-api-url", "");
                setCookie("kk2_token", "");
                setSyncStatus("idle");
                setSyncMsg("");
              }} bg={C.surface3} color={C.text3} style={{ padding: "10px 16px" }}>クリア</Btn>
            </div>
          </div>

          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: 16 }}>
            <div style={{ color: C.text3, fontSize: 11, marginBottom: 8 }}>同期ステータス</div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <div style={{
                width: 8, height: 8, borderRadius: "50%",
                background: syncStatus === "synced" ? C.green : syncStatus === "error" ? C.red : syncStatus === "syncing" ? C.blue : syncStatus === "offline" ? C.kome : C.text3,
              }} />
              <span style={{ color: C.text2, fontSize: 13 }}>
                {syncStatus === "synced" ? "接続済み" : syncStatus === "error" ? "エラー" : syncStatus === "syncing" ? "同期中..." : syncStatus === "offline" ? "オフライン" : "未設定"}
              </span>
              {syncMsg && <span style={{ color: C.text3, fontSize: 11, marginLeft: 4 }}>({syncMsg})</span>}
            </div>
            {(() => {
              const pending = load("kk2-pendingSync", []);
              if (pending && pending.length > 0) {
                return (
                  <div style={{ color: C.kome, fontSize: 11, marginTop: 8 }}>
                    未送信セッション: {pending.length}件
                  </div>
                );
              }
              return null;
            })()}
            {apiToken && (
              <Btn onClick={async () => {
                const merged = await syncFromAPI(problems, apiToken, apiUrl);
                setProblems(merged);
              }} bg={C.surface2} color={C.text2} style={{ width: "100%", marginTop: 12, border: `1px solid ${C.border}`, padding: "10px" }}>
                今すぐ同期
              </Btn>
            )}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ SESSION ═══════
  if (view === "session" && sessionActive) {
    if (!curProblem || curIdx >= queue.length) {
      return (
        <div style={{ background: C.bg, minHeight: "100vh", padding: "40px 20px", fontFamily: font }}>
          <div style={{ maxWidth: 480, margin: "0 auto", textAlign: "center" }}>
            <div style={{ fontSize: 48, marginBottom: 16 }}>🎉</div>
            <h2 style={{ color: C.text, fontSize: 22, fontWeight: 700, margin: "0 0 20px" }}>セッション完了</h2>
            {syncMsg && (
              <div style={{ color: syncStatus === "error" ? C.red : C.green, fontSize: 12, marginBottom: 12 }}>
                同期: {syncMsg}
              </div>
            )}
            <div style={{ display: "flex", justifyContent: "center", gap: 24, margin: "24px 0" }}>
              {[
                { v: stats.correct, l: "正解", c: C.green },
                { v: stats.wrong, l: "不正解", c: C.red },
                { v: stats.cycleComplete, l: "コメ完成", c: C.kome },
              ].map((s, i) => (
                <div key={i} style={{ textAlign: "center" }}>
                  <div style={{ color: s.c, fontSize: 30, fontWeight: 700 }}>{s.v}</div>
                  <div style={{ color: C.text3, fontSize: 12 }}>{s.l}</div>
                </div>
              ))}
            </div>
            <Btn onClick={() => { setSessionActive(false); setView("home"); }}
              bg={C.kome} color="#fff" style={{ width: "100%", marginTop: 16 }}>
              ホームに戻る
            </Btn>
          </div>
        </div>
      );
    }

    const progress = curIdx / queue.length * 100;

    return (
      <div style={{ background: C.bg, minHeight: "100vh", maxHeight: "100dvh", display: "flex", flexDirection: "column", fontFamily: font, position: "relative", overflow: "hidden" }}>
        {feedback && (
          <div style={{
            position: "fixed", inset: 0, zIndex: 50, pointerEvents: "none",
            background: feedback === "correct" ? C.greenDim : C.redDim,
            display: "flex", alignItems: "center", justifyContent: "center",
            animation: "pulse 0.6s ease-out forwards",
          }}>
            <span style={{ fontSize: 64, opacity: 0.8 }}>{feedback === "correct" ? "○" : "×"}</span>
          </div>
        )}
        <style>{`
          @keyframes pulse { 0%{opacity:1} 100%{opacity:0} }
          @keyframes cardIn { from{opacity:0;transform:translateY(16px)} to{opacity:1;transform:translateY(0)} }
        `}</style>

        {/* ── ヘッダー（固定） ── */}
        <div style={{ padding: "12px 16px 0", flexShrink: 0 }}>
          <div style={{ maxWidth: 480, margin: "0 auto" }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 8 }}>
              <button onClick={() => { setSessionActive(false); setView("home"); }}
                style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8 }}>
                ✕ 終了
              </button>
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <span style={{ color: C.kome, fontSize: 16, fontWeight: 700, fontFamily: "monospace" }}>{fmtTimer(timerElapsed)}</span>
                <span style={{ color: C.text3, fontSize: 12 }}>{curIdx + 1}/{queue.length}</span>
              </div>
            </div>
            <div style={{ height: 3, background: C.surface3, borderRadius: 2, overflow: "hidden" }}>
              <div style={{ height: "100%", background: C.kome, borderRadius: 2, width: `${progress}%`, transition: "width 0.4s" }} />
            </div>
          </div>
        </div>

        {/* ── メインコンテンツ（スクロール可能） ── */}
        <div style={{ flex: 1, overflow: "auto", WebkitOverflowScrolling: "touch", padding: "10px 16px" }}>
          <div key={curIdx} style={{ maxWidth: 480, margin: "0 auto", animation: "cardIn 0.3s ease" }}>

            {/* 問題ヘッダー */}
            <div style={{
              background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14,
              padding: "16px 18px", marginBottom: 8,
            }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <span style={{ color: C.kome, fontSize: 10, fontWeight: 700, padding: "2px 8px", background: C.komeDim, borderRadius: 4 }}>{curProblem.type || "計算"}</span>
                  <span style={{ color: C.text3, fontSize: 10 }}>{curProblem.deck}</span>
                </div>
                <IntervalBadge intervalIndex={curProblem.intervalIndex} />
              </div>
              {curProblem.sources && curProblem.sources.length > 0 && (
                <div style={{ color: C.text3, fontSize: 11, marginBottom: 6 }}>{curProblem.sources[0]}</div>
              )}
              <div style={{ color: C.text, fontSize: 18, fontWeight: 700, lineHeight: 1.6 }}>
                {curProblem.question}
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 10 }}>
                <SessionDots count={curSessionKome} />
                <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 4 }}>
                  <span style={{ color: C.text3, fontSize: 10 }}>累積:</span>
                  <KomeDots count={curProblem.komeTotal || 0} size={7} max={10} />
                </div>
              </div>
            </div>

            {/* 間違えた箇所（チェックボックス） */}
            {curProblem.mistakeItems && curProblem.mistakeItems.length > 0 && (
              <div style={{
                background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14,
                padding: "14px 18px", marginBottom: 8,
              }}>
                <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 10 }}>間違えた箇所</div>
                {curProblem.mistakeItems.map((item, i) => (
                  <label key={i} style={{ display: "flex", alignItems: "flex-start", gap: 10, padding: "6px 0", cursor: "pointer" }}>
                    <input type="checkbox" checked={!!checkedMistakes[item]}
                      onChange={e => setCheckedMistakes(m => ({ ...m, [item]: e.target.checked }))}
                      style={{ marginTop: 2, accentColor: C.kome, width: 18, height: 18, flexShrink: 0 }} />
                    <span style={{ color: C.text2, fontSize: 13, lineHeight: 1.5 }}>{item}</span>
                  </label>
                ))}
              </div>
            )}

            {/* メモ欄 */}
            <div style={{
              background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14,
              padding: "14px 18px", marginBottom: 8,
            }}>
              <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 8 }}>メモ（どう間違えたか）</div>
              <textarea value={mistakeMemo} onChange={e => setMistakeMemo(e.target.value)}
                placeholder="自由記述..."
                style={{ width: "100%", minHeight: 50, background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 12px", fontSize: 13, fontFamily: font, resize: "vertical", outline: "none", boxSizing: "border-box", lineHeight: 1.5 }} />
            </div>

            {/* 解答・ポイント（折りたたみ） */}
            <div style={{
              background: C.surface, border: `1px solid ${C.border}`, borderRadius: 14,
              overflow: "hidden", marginBottom: 16,
            }}>
              <button onClick={() => setShowAns(a => !a)} style={{
                width: "100%", background: "none", border: "none", padding: "14px 18px",
                display: "flex", alignItems: "center", justifyContent: "space-between",
                cursor: "pointer", fontFamily: font,
              }}>
                <span style={{ color: C.kome, fontSize: 12, fontWeight: 600 }}>解答・ポイント</span>
                <span style={{ color: C.text3, fontSize: 14, transform: showAns ? "rotate(180deg)" : "rotate(0)", transition: "transform 0.2s" }}>▼</span>
              </button>
              {showAns && (
                <div style={{ padding: "0 18px 16px", borderTop: `1px solid ${C.border}` }}>
                  {curProblem.summary && (
                    <div style={{ marginTop: 12 }}>
                      <div style={{ color: C.blue, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 6 }}>概要</div>
                      <div style={{ color: C.text, fontSize: 13, lineHeight: 1.8, whiteSpace: "pre-wrap" }}>{curProblem.summary}</div>
                    </div>
                  )}
                  {curProblem.steps && (
                    <div style={{ marginTop: 12 }}>
                      <div style={{ color: C.blue, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 6 }}>計算手順</div>
                      <div style={{ color: C.text, fontSize: 13, lineHeight: 1.8, whiteSpace: "pre-wrap" }}>{curProblem.steps}</div>
                    </div>
                  )}
                  {curProblem.judgment && (
                    <div style={{ marginTop: 12 }}>
                      <div style={{ color: C.blue, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 6 }}>判断ポイント</div>
                      <div style={{ color: C.text, fontSize: 13, lineHeight: 1.8, whiteSpace: "pre-wrap" }}>{curProblem.judgment}</div>
                    </div>
                  )}
                  {curProblem.mistakes && (
                    <div style={{ marginTop: 12 }}>
                      <div style={{ color: C.red, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 6 }}>間違えやすいポイント</div>
                      <div style={{ color: C.text, fontSize: 13, lineHeight: 1.8, whiteSpace: "pre-wrap" }}>{curProblem.mistakes}</div>
                    </div>
                  )}
                </div>
              )}
            </div>

          </div>
        </div>

        {/* ── 正解/不正解ボタン（画面下部に固定） ── */}
        <div style={{ padding: "10px 16px 14px", flexShrink: 0, background: C.bg, borderTop: `1px solid ${C.border}` }}>
          <div style={{ maxWidth: 480, margin: "0 auto", display: "flex", gap: 12 }}>
            <Btn onClick={() => handleAnswer(false)} bg={C.redDim} color={C.red}
              style={{ flex: 1, border: `1px solid ${C.red}40`, padding: "16px" }}>✕ 不正解</Btn>
            <Btn onClick={() => handleAnswer(true)} bg={C.greenDim} color={C.green}
              style={{ flex: 1, border: `1px solid ${C.green}40`, padding: "16px" }}>○ 正解</Btn>
          </div>
        </div>
      </div>
    );
  }

  // ═══════ HISTORY MODAL ═══════
  if (historyView) {
    const p = problems.find(pr => pr.id === historyView);
    if (!p) { setHistoryView(null); return null; }
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 540, margin: "0 auto" }}>
          <button onClick={() => setHistoryView(null)}
            style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8, marginBottom: 12 }}>
            ← 戻る
          </button>

          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "20px" }}>
            <div style={{ color: C.text, fontSize: 16, fontWeight: 600, lineHeight: 1.5, marginBottom: 12 }}>{p.question}</div>
            {p.answer && <div style={{ color: C.text3, fontSize: 13, marginBottom: 16, padding: "10px 14px", background: C.surface2, borderRadius: 8 }}>{p.answer}</div>}

            <div style={{ display: "flex", gap: 16, marginBottom: 20, flexWrap: "wrap" }}>
              <div>
                <span style={{ color: C.text3, fontSize: 11 }}>累積コメ</span>
                <div style={{ marginTop: 4 }}><KomeDots count={p.komeTotal || 0} size={10} max={20} /></div>
              </div>
              <div>
                <span style={{ color: C.text3, fontSize: 11 }}>ステージ</span>
                <div style={{ marginTop: 4 }}><IntervalBadge intervalIndex={p.intervalIndex} /></div>
              </div>
              <div>
                <span style={{ color: C.text3, fontSize: 11 }}>次回復習</span>
                <div style={{ color: C.text2, fontSize: 13, marginTop: 4 }}>{p.graduated ? "卒業済み" : (p.nextReview || "未定")}</div>
              </div>
            </div>

            <div style={{ color: C.text3, fontSize: 11, fontWeight: 600, letterSpacing: 1, marginBottom: 10 }}>解答履歴</div>
            {(!p.history || p.history.length === 0) ? (
              <div style={{ color: C.text3, fontSize: 13, padding: 20, textAlign: "center" }}>まだ履歴がありません</div>
            ) : (
              <div style={{ maxHeight: 400, overflowY: "auto" }}>
                {p.history.map((h, i) => (
                  <div key={i} style={{
                    display: "flex", alignItems: "center", gap: 12, padding: "8px 0",
                    borderBottom: i < p.history.length - 1 ? `1px solid ${C.border}` : "none",
                  }}>
                    <span style={{ color: C.text3, fontSize: 12, minWidth: 56, fontFamily: "monospace" }}>{fmtDate(h.date)}</span>
                    <span style={{
                      fontSize: 16, color: h.result === "○" ? C.green : C.red,
                      width: 24, textAlign: "center",
                    }}>{h.result}</span>
                    <KomeDots count={h.komeTotal} size={6} max={16} />
                  </div>
                ))}
              </div>
            )}

            {p.history && p.history.length > 1 && (
              <div style={{ marginTop: 16 }}>
                <div style={{ color: C.text3, fontSize: 11, fontWeight: 600, letterSpacing: 1, marginBottom: 8 }}>コメ推移</div>
                <div style={{ background: C.surface2, borderRadius: 8, padding: "12px 16px" }}>
                  {p.history.map((h, i) => {
                    const barW = Math.min((h.komeTotal / Math.max(...p.history.map(x => x.komeTotal), 1)) * 100, 100);
                    return (
                      <div key={i} style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
                        <span style={{ color: C.text3, fontSize: 9, minWidth: 36, fontFamily: "monospace" }}>{fmtDate(h.date)}</span>
                        <div style={{ flex: 1, height: 8, background: C.surface3, borderRadius: 4, overflow: "hidden" }}>
                          <div style={{
                            height: "100%", borderRadius: 4, width: `${barW}%`,
                            background: h.result === "×" ? C.kome : C.green, transition: "width 0.3s",
                          }} />
                        </div>
                        <span style={{ color: C.text3, fontSize: 9, minWidth: 16 }}>{h.komeTotal}</span>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ EXPORT ═══════
  if (exportText !== null) {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <div style={{ maxWidth: 600, margin: "0 auto" }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
            <button onClick={() => setExportText(null)}
              style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8 }}>
              ← 戻る
            </button>
            <button onClick={() => { navigator.clipboard?.writeText(exportText); flash("correct"); }}
              style={{
                background: C.kome, color: "#fff", border: "none", borderRadius: 8,
                padding: "8px 16px", fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: font,
              }}>
              コピー
            </button>
          </div>
          <div style={{ color: C.text2, fontSize: 12, marginBottom: 8 }}>
            以下をObsidian Vaultにペーストまたはスクリプトで書き込み
          </div>
          <pre style={{
            background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10,
            padding: 16, color: C.text2, fontSize: 11, lineHeight: 1.6,
            overflow: "auto", maxHeight: "70vh", whiteSpace: "pre-wrap", fontFamily: "monospace",
          }}>{exportText}</pre>
        </div>
      </div>
    );
  }

  // ═══════ MANAGE ═══════
  if (view === "manage") {
    return (
      <div style={{ background: C.bg, minHeight: "100vh", padding: "20px 16px", fontFamily: font }}>
        <style>{`@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}`}</style>
        <div style={{ maxWidth: 540, margin: "0 auto" }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 16 }}>
            <button onClick={() => setView("home")}
              style={{ background: "none", border: "none", color: C.text3, fontSize: 14, cursor: "pointer", fontFamily: font, padding: 8 }}>← 戻る</button>
            <h2 style={{ color: C.text, fontSize: 18, fontWeight: 700, margin: 0 }}>問題管理</h2>
            <div style={{ width: 50 }} />
          </div>

          <div style={{ display: "flex", gap: 6, marginBottom: 14, flexWrap: "wrap" }}>
            <button onClick={() => setDeckFilter("all")}
              style={{ background: deckFilter === "all" ? C.kome : C.surface2, color: deckFilter === "all" ? "#fff" : C.text3, border: "none", borderRadius: 20, padding: "5px 14px", fontSize: 12, fontWeight: 600, cursor: "pointer", fontFamily: font }}>
              すべて ({problems.length})
            </button>
            {decks.map(d => {
              const cnt = problems.filter(p => p.deck === d).length;
              return (
                <button key={d} onClick={() => setDeckFilter(d)}
                  style={{ background: deckFilter === d ? C.kome : C.surface2, color: deckFilter === d ? "#fff" : C.text3, border: "none", borderRadius: 20, padding: "5px 14px", fontSize: 12, fontWeight: 600, cursor: "pointer", fontFamily: font }}>
                  {d} ({cnt})
                </button>
              );
            })}
          </div>

          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: 16, marginBottom: 14 }}>
            <div style={{ display: "flex", gap: 8, marginBottom: 10 }}>
              <button onClick={() => setBulkMode(false)}
                style={{ background: !bulkMode ? C.kome : C.surface2, color: !bulkMode ? "#fff" : C.text3, border: "none", borderRadius: 8, padding: "6px 14px", fontSize: 12, fontWeight: 600, cursor: "pointer", fontFamily: font, flex: 1 }}>個別追加</button>
              <button onClick={() => setBulkMode(true)}
                style={{ background: bulkMode ? C.kome : C.surface2, color: bulkMode ? "#fff" : C.text3, border: "none", borderRadius: 8, padding: "6px 14px", fontSize: 12, fontWeight: 600, cursor: "pointer", fontFamily: font, flex: 1 }}>一括追加</button>
            </div>

            <div style={{ marginBottom: 10 }}>
              <div style={{ color: C.text3, fontSize: 11, marginBottom: 4 }}>デッキ</div>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                {decks.map(d => (
                  <button key={d} onClick={() => setNewDeck(d)}
                    style={{ background: newDeck === d ? C.blueDim : C.surface3, color: newDeck === d ? C.blue : C.text3, border: `1px solid ${newDeck === d ? C.blue + "40" : C.border}`, borderRadius: 6, padding: "3px 10px", fontSize: 11, cursor: "pointer", fontFamily: font }}>
                    {d}
                  </button>
                ))}
                <input placeholder="+ 新規" style={{ background: C.surface3, border: `1px solid ${C.border}`, borderRadius: 6, color: C.text, padding: "3px 8px", fontSize: 11, fontFamily: font, width: 80, outline: "none" }}
                  onKeyDown={e => { if (e.key === "Enter" && e.target.value.trim()) { const nd = e.target.value.trim(); if (!decks.includes(nd)) setDecks(p => [...p, nd]); setNewDeck(nd); e.target.value = ""; } }} />
              </div>
            </div>

            {!bulkMode ? (
              <>
                <input value={newQ} onChange={e => setNewQ(e.target.value)} placeholder="問題文"
                  style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 14, fontFamily: font, marginBottom: 8, boxSizing: "border-box", outline: "none" }}
                  onKeyDown={e => { if (e.key === "Enter") document.getElementById("ai2")?.focus(); }} />
                <input id="ai2" value={newA} onChange={e => setNewA(e.target.value)} placeholder="解答（任意）"
                  style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 14, fontFamily: font, marginBottom: 10, boxSizing: "border-box", outline: "none" }}
                  onKeyDown={e => { if (e.key === "Enter") addProblem(); }} />
                <Btn onClick={addProblem} disabled={!newQ.trim()} bg={newQ.trim() ? C.kome : C.surface3} color={newQ.trim() ? "#fff" : C.text3} style={{ width: "100%" }}>追加</Btn>
              </>
            ) : (
              <>
                <textarea value={bulkText} onChange={e => setBulkText(e.target.value)}
                  placeholder={"1行1問（TAB or | で問題と解答を区切る）\n減価償却の意義\t固定資産の…"}
                  style={{ width: "100%", minHeight: 100, background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 8, color: C.text, padding: "10px 14px", fontSize: 13, fontFamily: font, marginBottom: 10, boxSizing: "border-box", resize: "vertical", outline: "none", lineHeight: 1.6 }} />
                <Btn onClick={addBulk} disabled={!bulkText.trim()} bg={bulkText.trim() ? C.kome : C.surface3} color={bulkText.trim() ? "#fff" : C.text3} style={{ width: "100%" }}>一括追加</Btn>
              </>
            )}
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {filteredProblems.length === 0 && (
              <div style={{ color: C.text3, textAlign: "center", padding: 40, fontSize: 14 }}>問題がありません</div>
            )}
            {filteredProblems.map(p => (
              <div key={p.id} style={{
                background: C.surface, border: `1px solid ${C.border}`, borderRadius: 10,
                padding: "12px 16px", opacity: p.graduated ? 0.6 : 1,
              }}>
                {editId === p.id ? (
                  <div>
                    <input value={editQ} onChange={e => setEditQ(e.target.value)}
                      style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 6, color: C.text, padding: "8px 10px", fontSize: 13, fontFamily: font, marginBottom: 6, boxSizing: "border-box", outline: "none" }} />
                    <input value={editA} onChange={e => setEditA(e.target.value)}
                      style={{ width: "100%", background: C.surface2, border: `1px solid ${C.border}`, borderRadius: 6, color: C.text, padding: "8px 10px", fontSize: 13, fontFamily: font, marginBottom: 8, boxSizing: "border-box", outline: "none" }} />
                    <div style={{ display: "flex", gap: 8 }}>
                      <Btn onClick={() => { setProblems(prev => prev.map(x => x.id === p.id ? { ...x, question: editQ, answer: editA } : x)); setEditId(null); }}
                        bg={C.kome} color="#fff" style={{ padding: "6px 16px", fontSize: 12 }}>保存</Btn>
                      <Btn onClick={() => setEditId(null)} bg={C.surface3} color={C.text3} style={{ padding: "6px 16px", fontSize: 12 }}>取消</Btn>
                    </div>
                  </div>
                ) : (
                  <div>
                    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8 }}>
                      <div style={{ flex: 1, cursor: "pointer" }} onClick={() => setHistoryView(p.id)}>
                        <div style={{ color: C.text, fontSize: 13, fontWeight: 500, lineHeight: 1.5 }}>{p.question}</div>
                        {p.answer && <div style={{ color: C.text3, fontSize: 12, marginTop: 2 }}>{p.answer}</div>}
                      </div>
                      <div style={{ display: "flex", gap: 4, flexShrink: 0 }}>
                        <button onClick={() => { setEditId(p.id); setEditQ(p.question); setEditA(p.answer || ""); }}
                          style={{ background: "none", border: "none", color: C.text3, cursor: "pointer", fontSize: 14, padding: 4 }}>✏</button>
                        <button onClick={() => setProblems(prev => prev.filter(x => x.id !== p.id))}
                          style={{ background: "none", border: "none", color: C.red, cursor: "pointer", fontSize: 14, padding: 4, opacity: 0.5 }}>✕</button>
                      </div>
                    </div>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
                      <KomeDots count={p.komeTotal || 0} size={7} max={12} />
                      <IntervalBadge intervalIndex={p.intervalIndex} />
                      {p.graduated && <span style={{ color: C.green, fontSize: 10, fontWeight: 600 }}>✓ 卒業</span>}
                      <span style={{ color: C.text3, fontSize: 10, marginLeft: "auto" }}>{p.deck}</span>
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  }

  // ═══════ HOME ═══════
  return (
    <div style={{ background: C.bg, minHeight: "100vh", padding: "36px 16px", fontFamily: font }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;600;700&display=swap');
        @keyframes fadeUp{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}
      `}</style>

      <div style={{ maxWidth: 480, margin: "0 auto" }}>
        <div style={{ textAlign: "center", marginBottom: 32, animation: "fadeUp 0.5s ease" }}>
          <div style={{ display: "flex", justifyContent: "center", gap: 3, marginBottom: 8 }}>
            {[1, 2, 3, 4].map(i => <div key={i} style={{ width: 8, height: 8, borderRadius: 2, background: C.kome }} />)}
          </div>
          <h1 style={{ color: C.text, fontSize: 24, fontWeight: 700, margin: 0 }}>コメコメ暗記 v2</h1>
          <p style={{ color: C.text3, fontSize: 12, marginTop: 4 }}>廣升式 記憶曲線メソッド</p>
          {apiToken && (
            <div style={{ display: "flex", justifyContent: "center", alignItems: "center", gap: 6, marginTop: 8 }}>
              <div style={{
                width: 6, height: 6, borderRadius: "50%",
                background: syncStatus === "synced" ? C.green : syncStatus === "error" ? C.red : syncStatus === "syncing" ? C.blue : syncStatus === "offline" ? C.kome : C.text3,
              }} />
              <span style={{ color: C.text3, fontSize: 10 }}>
                {syncStatus === "synced" ? "Synced" : syncStatus === "error" ? "Error" : syncStatus === "syncing" ? "Syncing..." : syncStatus === "offline" ? "Offline" : ""}
                {syncMsg ? ` (${syncMsg})` : ""}
              </span>
            </div>
          )}
        </div>

        <div style={{ animation: "fadeUp 0.5s ease 0.05s both" }}>
          <Btn onClick={startSession} disabled={dueCount === 0}
            bg={dueCount > 0 ? C.kome : C.surface3} color={dueCount > 0 ? "#fff" : C.text3}
            style={{ width: "100%", padding: "18px", fontSize: 17, borderRadius: 14, boxShadow: dueCount > 0 ? `0 4px 24px ${C.kome}30` : "none" }}>
            {dueCount > 0 ? `学習を開始（${dueCount}問）` : "今日の学習は完了 🎉"}
          </Btn>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr 1fr", gap: 8, marginTop: 16, animation: "fadeUp 0.5s ease 0.1s both" }}>
          {[
            { v: dueCount, l: "今日の対象", c: C.kome },
            { v: totalKome, l: "総コメ数", c: C.kome },
            { v: graduatedCount, l: "卒業", c: C.green },
            { v: problems.length, l: "全問題", c: C.text2 },
          ].map((s, i) => (
            <div key={i} style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "14px 8px", textAlign: "center" }}>
              <div style={{ color: s.c, fontSize: 22, fontWeight: 700 }}>{s.v}</div>
              <div style={{ color: C.text3, fontSize: 10, marginTop: 2 }}>{s.l}</div>
            </div>
          ))}
        </div>

        {upcoming.some(r => r.count > 0) && (
          <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "14px 20px", marginTop: 12, animation: "fadeUp 0.5s ease 0.15s both" }}>
            <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 10 }}>復習予定</div>
            <div style={{ display: "flex", gap: 12 }}>
              {upcoming.map((r, i) => (
                <div key={i} style={{ flex: 1, textAlign: "center" }}>
                  <div style={{ color: r.count > 0 ? C.blue : C.text3, fontSize: 18, fontWeight: 700 }}>{r.count}</div>
                  <div style={{ color: C.text3, fontSize: 10 }}>{r.days}日後</div>
                </div>
              ))}
            </div>
          </div>
        )}

        <div style={{ background: C.surface, border: `1px solid ${C.border}`, borderRadius: 12, padding: "18px 20px", marginTop: 12, animation: "fadeUp 0.5s ease 0.2s both" }}>
          <div style={{ color: C.text3, fontSize: 10, fontWeight: 600, letterSpacing: 1, marginBottom: 12 }}>コメコメ暗記法</div>
          {[
            { s: "①", t: "不正解 → コメ1本（累積）。3〜4問後に戻る", c: C.kome },
            { s: "②", t: "再挑戦。不正解ならコメ追加、正解ならスルー", c: C.kome },
            { s: "③", t: "セッション中にコメ4本で今日は完成", c: C.gold },
            { s: "④", t: "正解もスルーも、3→7→14→28日後に再出題", c: C.blue },
            { s: "⑤", t: "復習時の不正解もコメ累積（永久に残る）", c: C.red },
          ].map((r, i) => (
            <div key={i} style={{ display: "flex", gap: 10, alignItems: "flex-start", marginBottom: 8 }}>
              <span style={{ color: r.c, fontSize: 13, fontWeight: 700, flexShrink: 0 }}>{r.s}</span>
              <span style={{ color: C.text2, fontSize: 12, lineHeight: 1.5 }}>{r.t}</span>
            </div>
          ))}
        </div>

        <div style={{ display: "flex", gap: 10, marginTop: 16, animation: "fadeUp 0.5s ease 0.25s both" }}>
          <Btn onClick={() => setView("manage")} bg={C.surface} color={C.text2}
            style={{ flex: 1, border: `1px solid ${C.border}` }}>問題管理</Btn>
          <Btn onClick={exportObsidian} bg={C.surface} color={C.text2}
            style={{ flex: 1, border: `1px solid ${C.border}` }}>Obsidian出力</Btn>
        </div>
        <div style={{ marginTop: 10, animation: "fadeUp 0.5s ease 0.3s both" }}>
          <Btn onClick={() => setShowSettings(true)} bg={C.surface} color={C.text3}
            style={{ width: "100%", border: `1px solid ${C.border}`, fontSize: 12, padding: "10px" }}>
            API 同期設定
          </Btn>
        </div>
      </div>
    </div>
  );
}

// ── Mount ──
const root = createRoot(document.getElementById("root"));
root.render(<KomeKomeV2 />);
