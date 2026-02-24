#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const MODULE_PATH = path.join(__dirname, 'komekome-pwa', 'node_modules');
const puppeteer = require(path.join(MODULE_PATH, 'puppeteer'));
const markedModule = require(path.join(MODULE_PATH, 'marked'));
const katex = require(path.join(MODULE_PATH, 'katex'));

const marked = markedModule.marked || markedModule;

function parseArgs() {
  const args = process.argv.slice(2);
  let resume = false;
  let max = Infinity;
  let category = null;
  let vaultPath = null;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--resume') resume = true;
    else if (args[i] === '--max') max = parseInt(args[++i], 10);
    else if (args[i] === '--category') category = args[++i];
    else if (args[i] === '--vault') vaultPath = args[++i];
  }

  if (!Number.isFinite(max) || max <= 0) max = Infinity;
  return { resume, max, category, vaultPath };
}

function walkMdFiles(rootDir, out = []) {
  const entries = fs.readdirSync(rootDir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      walkMdFiles(full, out);
    } else if (entry.isFile() && entry.name.endsWith('.md') && entry.name !== 'README.md' && entry.name !== 'CLAUDE.md') {
      out.push(full);
    }
  }
  return out;
}

function extractCalcSection(text) {
  const header = '## 計算手順';
  const idx = text.indexOf(header);
  if (idx < 0) return null;
  const after = text.substring(idx + header.length);
  // Find next ## heading
  const nextH2 = after.search(/\n## [^\n]/);
  const section = nextH2 >= 0 ? after.substring(0, nextH2) : after;
  const content = section.trim();
  return content.length >= 100 ? content : null;
}

function processLatex(md) {
  md = md.replace(/\$\$([\s\S]*?)\$\$/g, (_, tex) => {
    try {
      return katex.renderToString(tex.trim(), {
        displayMode: true,
        throwOnError: false,
        strict: false
      });
    } catch (_err) {
      return `<pre>${escapeHtml(tex)}</pre>`;
    }
  });

  md = md.replace(/(?<!\$)\$(?!\$)([^\n$]+?)\$(?!\$)/g, (_, tex) => {
    try {
      return katex.renderToString(tex.trim(), {
        displayMode: false,
        throwOnError: false,
        strict: false
      });
    } catch (_err) {
      return `<code>${escapeHtml(tex)}</code>`;
    }
  });

  return md;
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function loadKatexCss() {
  const cssPath = path.join(MODULE_PATH, 'katex', 'dist', 'katex.min.css');
  const fontsDir = path.join(MODULE_PATH, 'katex', 'dist', 'fonts');
  const fontsUrlBase = 'file://' + fontsDir.replace(/\\/g, '/');
  let css = fs.readFileSync(cssPath, 'utf8');

  css = css.replace(/url\((['"]?)(fonts\/[^)'"]+)\1\)/g, (_m, quote, relPath) => {
    const q = quote || '';
    return `url(${q}${fontsUrlBase}/${relPath.replace(/^fonts\//, '')}${q})`;
  });
  return css;
}

function renderHtml(contentHtml, katexCss) {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>${katexCss}</style>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    width: 400px;
    font-family: "Hiragino Kaku Gothic ProN", "Noto Sans JP", "Yu Gothic", sans-serif;
    font-size: 13px;
    line-height: 1.6;
    color: #1a1a1a;
    background: white;
    padding: 16px;
  }
  h3 { font-size: 14px; margin: 12px 0 6px; color: #333; border-bottom: 1px solid #e0e0e0; padding-bottom: 2px; }
  h3:first-child { margin-top: 0; }
  h4 { font-size: 13px; margin: 10px 0 4px; color: #555; }
  table { width: 100%; border-collapse: collapse; margin: 8px 0; font-size: 12px; }
  th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; }
  th { background: #f5f5f5; font-weight: 600; }
  ul, ol { padding-left: 20px; margin: 6px 0; }
  li { margin: 2px 0; }
  code { background: #f0f0f0; padding: 1px 4px; border-radius: 3px; font-size: 12px; }
  pre { background: #f7f7f7; padding: 8px 12px; border-radius: 6px; margin: 8px 0; overflow-x: auto; font-size: 12px; }
  pre code { background: none; padding: 0; }
  strong { color: #1a1a1a; }
  .katex-display { margin: 8px 0; overflow-x: auto; }
  .katex { font-size: 1em; }
  p { margin: 4px 0; }
</style>
</head>
<body>
<div id="content">
${contentHtml}
</div>
</body>
</html>`;
}

function toTopicId(baseDir, filePath) {
  return path.relative(baseDir, filePath).replace(/\\/g, '/').replace(/\.md$/i, '');
}

function loadProgress(progressPath) {
  if (!fs.existsSync(progressPath)) {
    return { processed: [], errors: {}, last_run: null };
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(progressPath, 'utf8'));
    return {
      processed: Array.isArray(parsed.processed) ? parsed.processed : [],
      errors: parsed && typeof parsed.errors === 'object' && parsed.errors ? parsed.errors : {},
      last_run: parsed.last_run || null
    };
  } catch (_err) {
    return { processed: [], errors: {}, last_run: null };
  }
}

function saveProgress(progressPath, progress) {
  progress.last_run = new Date().toISOString();
  fs.mkdirSync(path.dirname(progressPath), { recursive: true });
  fs.writeFileSync(progressPath, JSON.stringify(progress, null, 2), 'utf8');
}

async function main() {
  const opts = parseArgs();
  const home = process.env.HOME || '/home/masa';
  const vault = opts.vaultPath || process.env.VAULT || path.join(home, 'vault', 'houjinzei');
  const notesRoot = path.join(vault, '10_論点');
  const outRoot = path.join(vault, '02_extracted', 'calc_images');
  const progressPath = path.join(vault, 'logs', 'calc_images_progress.json');
  const progress = loadProgress(progressPath);
  const processedSet = new Set(progress.processed);
  const katexCss = loadKatexCss();

  let files = walkMdFiles(notesRoot).sort();
  if (opts.category) {
    const prefix = opts.category.replace(/\\/g, '/').replace(/\/+$/, '') + '/';
    files = files.filter((f) => toTopicId(notesRoot, f).startsWith(prefix));
  }

  const candidates = [];
  for (const file of files) {
    const topicId = toTopicId(notesRoot, file);
    const outPath = path.join(outRoot, topicId + '.webp');
    if (opts.resume && (processedSet.has(topicId) || fs.existsSync(outPath))) continue;
    // Pre-check: only include files with valid calc section
    const text = fs.readFileSync(file, 'utf8');
    const calcMd = extractCalcSection(text);
    if (!calcMd) continue;
    candidates.push({ file, topicId, outPath, calcMd });
    if (candidates.length >= opts.max) break;
  }

  console.log(`Found ${candidates.length} notes with 計算手順 (100+ chars)`);

  let browser;
  let page;
  let interrupted = false;
  const onInterrupt = () => {
    interrupted = true;
    try { saveProgress(progressPath, progress); } catch (_err) {}
  };
  process.on('SIGINT', onInterrupt);
  process.on('SIGTERM', onInterrupt);

  try {
    browser = await puppeteer.launch({
      headless: 'new',
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-breakpad',
        '--disable-crash-reporter'
      ]
    });
    page = await browser.newPage();
    await page.setViewport({ width: 400, height: 800, deviceScaleFactor: 2 });

    for (let i = 0; i < candidates.length; i++) {
      if (interrupted) break;
      const item = candidates[i];
      const start = Date.now();
      try {
        const latexProcessed = processLatex(item.calcMd);
        const htmlContent = marked.parse(latexProcessed);
        const html = renderHtml(htmlContent, katexCss);

        await page.setContent(html, { waitUntil: 'domcontentloaded' });
        const el = await page.$('#content');
        if (!el) throw new Error('Missing #content element');

        const screenshot = await el.screenshot({ type: 'webp', quality: 85 });
        fs.mkdirSync(path.dirname(item.outPath), { recursive: true });
        fs.writeFileSync(item.outPath, screenshot);

        if (!processedSet.has(item.topicId)) {
          progress.processed.push(item.topicId);
          processedSet.add(item.topicId);
        }
        delete progress.errors[item.topicId];
        saveProgress(progressPath, progress);

        const relOut = path.relative(outRoot, item.outPath).replace(/\\/g, '/');
        const secs = ((Date.now() - start) / 1000).toFixed(1);
        console.log(`[${i + 1}/${candidates.length}] ${relOut} (${secs}s)`);
      } catch (err) {
        progress.errors[item.topicId] = err && err.message ? err.message : String(err);
        saveProgress(progressPath, progress);
        console.error(`Error: ${item.topicId}: ${progress.errors[item.topicId]}`);
      }
    }
  } finally {
    process.off('SIGINT', onInterrupt);
    process.off('SIGTERM', onInterrupt);
    saveProgress(progressPath, progress);
    if (page) {
      try { await page.close(); } catch (_err) {}
    }
    if (browser) {
      try { await browser.close(); } catch (_err) {}
    }
  }
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exitCode = 1;
});
