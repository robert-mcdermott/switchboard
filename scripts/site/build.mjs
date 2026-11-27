#!/usr/bin/env node
// Builds Switchboard's website from docs/GUIDE.md, two sections of the README, the release
// notes in docs/releases, and a hand-written home page. Needs Node.js 22 and nothing else.
//
//   node scripts/site/build.mjs                 build into build/site
//   node scripts/site/build.mjs --out DIR       build somewhere else
//   node scripts/site/build.mjs --publish DIR   build, then copy into DIR (a checkout of gh-pages)
//
// The guide stays the source. Each of its ## sections becomes a page, and links between
// sections, written as GitHub reads them (#from-the-zip), are pointed at the right page.
// The build checks every local link, anchor, and image, and fails on a broken one.

import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, extname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const DOCS = join(REPO, "docs");
const GITHUB = "https://github.com/robert-mcdermott/switchboard";
const SITE = "https://robert-mcdermott.github.io/switchboard/"; // where the site is published
const BASE = new URL(SITE).pathname; // for the 404 page, which can be served at any depth

// Reading order, in groups. Each page is [file name, menu label, source], where the source is
// "home", "releases", "guide:<a ## heading of docs/GUIDE.md>", or "readme:<one of README.md>".
export const MENU = [
  ["Start", [["index", "Overview", "home"], ["installing", "Installing", "guide:Installing"]]],
  ["Use", [
    ["standalone-and-full", "Standalone and Full", "guide:Standalone and Full"],
    ["the-window", "The window", "guide:The window"],
    ["filtering", "Filtering", "guide:Filtering"],
    ["the-log", "The log", "guide:The log"],
    ["location", "Location data", "guide:Location and network owner"],
    ["workspaces", "Workspaces and walls", "guide:Workspaces and wall displays"],
    ["keys", "Keys", "guide:Keys"],
  ]],
  ["Help", [["troubleshooting", "Troubleshooting", "guide:Troubleshooting"], ["privacy", "Privacy", "guide:Privacy"]]],
  ["Reference", [
    ["command-line", "Command line", "readme:The command line tool"],
    ["how-it-works", "How it works", "readme:How it works"],
    ["releases", "Releases", "releases"],
  ]],
];

// What search engines show for pages whose first paragraph does not say what they are about.
// Other pages use their first paragraph.
const DESCRIPTIONS = {
  index: "A free, open-source network monitor for macOS: a live picture of every connection on your Mac, by program, with hostnames, places, and a searchable history.",
  "standalone-and-full": "What Switchboard sees with no password and nothing installed, and what its optional root collector adds: every account's connections and their hostnames.",
  "the-window": "The Switchboard window: the graph and its six layouts, the timeline, the panels, and the inspector, and how to read what they show.",
  keys: "Every keyboard shortcut in Switchboard: layouts, the filter, profiles, themes, kiosk mode, and flying through cyberspace.",
  troubleshooting: "What to do when Switchboard looks wrong: installer errors, no hostnames or countries, a blank graph, high CPU, and missing sources after a macOS update.",
  "how-it-works": "How Switchboard is built: the engine, its data sources, the optional root collector, the SQLite log, the Metal graph, and the SwiftUI window.",
};

// Pictures, by the name pages use. Every one shows simulated traffic (--source sim:developer).
const IMAGES = {
  console: "docs/spikes/m3-console.jpg",
  flow: "docs/spikes/m7-flow.jpg",
  lanes: "docs/spikes/m7-lanes.jpg",
  globe: "docs/spikes/m7-globe.jpg",
  hierarchy: "docs/spikes/m7-hierarchy.jpg",
  cyberspace: "docs/cyberspace.jpg",
  themes: "docs/themes.jpg",
  hostnames: "docs/spikes/m4-hostnames.jpg",
  log: "docs/spikes/m5-log.jpg",
};

// Where links to the README's sections go on the site.
const README_ANCHORS = {
  install: "installing.html", "build-from-source": "installing.html#from-source", "two-modes": "standalone-and-full.html",
  "location-data": "location.html", filtering: "filtering.html", "on-a-wall": "workspaces.html",
  "the-command-line-tool": "command-line.html", "how-it-works": "how-it-works.html",
};

// Sections of the release notes that belong on GitHub's release page rather than here.
const RELEASE_ONLY = new Set(["Install", "Install or update", "Licence", "Files"]);

// --- Markdown (the subset the guide uses) ------------------------------------------------------

export function slug(text) {
  return text.trim().toLowerCase().replace(/`/g, "").replace(/[^\p{L}\p{N}_\- ]/gu, "").replace(/ /g, "-");
}

export function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Inline Markdown to HTML: code, images, links, autolinks, bold, italics. */
export function inline(text, link = (href) => href) {
  const codes = [];
  let out = text.replace(/`([^`]+)`/g, (_, code) => `\u0000${codes.push(`<code>${escapeHtml(code)}</code>`) - 1}\u0000`);
  out = escapeHtml(out);
  out = out.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_, alt, src) => `<img src="${link(src)}" alt="${alt}" loading="lazy">`);
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, href) => {
    const target = link(href.replace(/&amp;/g, "&"));
    return `<a href="${escapeHtml(target)}"${/^https?:/.test(target) ? ' rel="noopener"' : ""}>${label}</a>`;
  });
  out = out.replace(/&lt;(https?:\/\/[^&\s]+)&gt;/g, (_, url) => `<a href="${url}" rel="noopener">${url}</a>`);
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/(^|[\s(])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
  out = out.replace(/(^|[\s(])_([^_\s][^_]*)_(?=[\s.,;:)]|$)/g, "$1<em>$2</em>");
  return out.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[Number(i)]);
}

function splitRow(line) {
  const cells = [];
  let cell = "";
  let code = false;
  for (const ch of line.trim().replace(/^\|/, "").replace(/\|$/, "")) {
    if (ch === "`") code = !code;
    if (ch === "|" && !code) { cells.push(cell.trim()); cell = ""; } else cell += ch;
  }
  cells.push(cell.trim());
  return cells;
}

/** Block Markdown to HTML. Returns { html, headings: [{level, text, id}] }. */
export function markdown(source, { link = (href) => href } = {}) {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const headings = [];
  const used = new Map();
  const out = [];
  let i = 0;
  const isBlockStart = (line) => /^(#{1,6}\s|```|>|\s*([-*]|\d+\.)\s|\|)/.test(line) || /^(-{3,}|\*{3,})$/.test(line.trim());
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    let m;
    if ((m = line.match(/^```(\w*)\s*$/))) {
      const body = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) body.push(lines[i++]);
      i++;
      out.push(`<div class="code"><pre><code class="language-${m[1] || "text"}">${escapeHtml(body.join("\n"))}</code></pre></div>`);
      continue;
    }
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
      const level = m[1].length;
      const text = m[2].trim();
      let id = slug(text);
      if (used.has(id)) { used.set(id, used.get(id) + 1); id = `${id}-${used.get(id) - 1}`; } else used.set(id, 1);
      headings.push({ level, text: text.replace(/`/g, ""), id });
      const anchor = level > 1 ? `<a class="anchor" href="#${id}" aria-label="Link to this section">#</a>` : "";
      out.push(`<h${level} id="${id}">${inline(text, link)}${anchor}</h${level}>`);
      i++;
      continue;
    }
    if (/^(-{3,}|\*{3,})$/.test(line.trim())) { out.push("<hr>"); i++; continue; }
    if (line.startsWith("|") && i + 1 < lines.length && /^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
      const head = splitRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trim().startsWith("|")) rows.push(splitRow(lines[i++]));
      out.push(`<div class="table-wrap"><table><thead><tr>${head.map((c) => `<th>${inline(c, link)}</th>`).join("")}</tr></thead>`
        + `<tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c, link)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`);
      continue;
    }
    if (line.startsWith(">")) {
      const body = [];
      while (i < lines.length && lines[i].startsWith(">")) body.push(lines[i++].replace(/^>\s?/, ""));
      out.push(`<blockquote>${markdown(body.join("\n"), { link }).html}</blockquote>`);
      continue;
    }
    if ((m = line.match(/^(\s*)([-*]|\d+\.)\s+/))) {
      const ordered = /\d/.test(m[2]);
      const start = ordered ? parseInt(m[2], 10) : 1;
      const items = [];
      while (i < lines.length) {
        const item = lines[i].match(/^\s*([-*]|\d+\.)\s+(.*)$/);
        if (item && /\d/.test(item[1]) === ordered) {
          items.push([item[2]]);
          i++;
        } else if (lines[i].trim() && /^\s{2,}\S/.test(lines[i]) && items.length) {
          items[items.length - 1].push(lines[i++].trim());
        } else if (!lines[i].trim() && i + 1 < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i + 1])) {
          i++;
        } else break;
      }
      const tag = ordered ? "ol" : "ul";
      out.push(`<${tag}${ordered && start !== 1 ? ` start="${start}"` : ""}>${items.map((p) => `<li>${inline(p.join(" "), link)}</li>`).join("")}</${tag}>`);
      continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !(para.length && isBlockStart(lines[i]))) para.push(lines[i++]);
    out.push(`<p>${inline(para.join("\n"), link)}</p>`);
  }
  return { html: out.join("\n"), headings };
}

/** The ## sections of a Markdown file by heading, each with its headings raised one level. */
function sectionsOf(file) {
  const found = new Map();
  let current = null;
  let fence = false;
  for (const line of readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n")) {
    if (/^```/.test(line)) fence = !fence;
    const h2 = !fence && line.match(/^## (.+)$/);
    if (h2) { current = []; found.set(h2[1].trim(), current); }
    if (current) current.push(!fence && /^#{2,6} /.test(line) ? line.slice(1) : line);
  }
  return new Map([...found].map(([heading, lines]) => [heading, `${lines.join("\n").trim()}\n`]));
}

// --- Pictures -----------------------------------------------------------------------------------

/** A JPEG's or PNG's width and height, so pages keep their layout while pictures load. */
function imageSize(file) {
  const data = readFileSync(file);
  if (data.readUInt32BE(0) === 0x89504e47) return [data.readUInt32BE(16), data.readUInt32BE(20)];
  let at = 2;
  while (at < data.length) {
    const marker = data[at + 1];
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return [data.readUInt16BE(at + 7), data.readUInt16BE(at + 5)];
    at += 2 + data.readUInt16BE(at + 2);
  }
  throw new Error(`Cannot read the size of ${file}`);
}

function picture(name, alt, { eager = false } = {}) {
  const file = IMAGES[name];
  if (!file) throw new Error(`No picture named "${name}"; add it to IMAGES in scripts/site/build.mjs`);
  const [width, height] = imageSize(join(REPO, file));
  return `<img src="images/${name}${extname(file)}" alt="${escapeHtml(alt)}" width="${width}" height="${height}"`
    + `${eager ? ' fetchpriority="high"' : ' loading="lazy"'} decoding="async">`;
}

/** The home page's placeholders: {{shot:name|alt}}, {{img:name|alt}}, {{version}}. */
function placeholders(html, ver) {
  let first = true;
  return html
    .replace(/\{\{shot:([\w-]+)\|([^}]*)\}\}/g, (_, name, alt) => {
      const img = picture(name, alt, { eager: first });
      first = false;
      return `<figure class="shot">${img}</figure>`;
    })
    .replace(/\{\{img:([\w-]+)\|([^}]*)\}\}/g, (_, name, alt) => picture(name, alt))
    .replace(/\{\{version\}\}/g, ver);
}

// --- Pages -----------------------------------------------------------------------------------

function version() {
  const match = readFileSync(join(REPO, "Sources/SwitchboardCore/Switchboard.swift"), "utf8").match(/static let version = "([^"]+)"/);
  if (!match) throw new Error("No version in Sources/SwitchboardCore/Switchboard.swift");
  return match[1];
}

/** Where a link in a page's Markdown, written relative to `fromFile`, points on the site. */
function linker(fromFile, place) {
  return (href) => {
    if (/^[a-z]+:/.test(href)) return href;
    const [path, anchor] = href.split("#");
    const target = relative(REPO, path ? resolve(dirname(fromFile), path) : fromFile).replaceAll("\\", "/");
    if (target === "docs/GUIDE.md") return anchor ? place(anchor) : "index.html";
    if (target === "README.md") return README_ANCHORS[anchor] ?? "index.html";
    const notes = target.match(/^docs\/releases\/(.+)\.md$/);
    if (notes) return `releases.html#${slug(`Switchboard ${notes[1]}`)}`;
    const picture = Object.entries(IMAGES).find(([, file]) => file === target);
    if (picture) return `images/${picture[0]}${extname(picture[1])}`;
    const kind = existsSync(join(REPO, target)) && !/\.\w+$/.test(target) && !["LICENSE", "NOTICE"].includes(target) ? "tree" : "blob";
    return `${GITHUB}/${kind}/main/${target}${anchor ? `#${anchor}` : ""}`;
  };
}

/** When a version was released: its tag's date, or else the day its notes were added. */
function released(ver) {
  const git = (...args) => {
    try { return execFileSync("git", ["-C", REPO, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return ""; }
  };
  const day = git("log", "-1", "--format=%cs", `refs/tags/v${ver}`) || git("log", "--diff-filter=A", "--format=%cs", "--", `docs/releases/${ver}.md`).split("\n").pop();
  return day ? new Date(`${day}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }) : "";
}

/** Every release's notes, newest first, without the parts that are about its GitHub page. */
function releasesMarkdown() {
  const order = (v) => v.split(".").map(Number);
  const versions = readdirSync(join(DOCS, "releases")).filter((f) => /^\d+\.\d+\.\d+\.md$/.test(f)).map((f) => f.slice(0, -3))
    .sort((a, b) => { const [x, y] = [order(a), order(b)]; return y[0] - x[0] || y[1] - x[1] || y[2] - x[2]; });
  let md = "# Releases\n\nEvery release of Switchboard, newest first. Each one's zip, installer, and checksums are on its GitHub page; [Installing](../GUIDE.md#installing) has the one command that installs the latest.\n\n";
  for (const ver of versions) {
    const when = released(ver);
    md += `## Switchboard ${ver}\n\n${when ? `${when} · ` : ""}[The release on GitHub](${GITHUB}/releases/tag/v${ver})\n\n`;
    let skipping = false;
    let fence = false;
    for (const line of readFileSync(join(DOCS, "releases", `${ver}.md`), "utf8").split("\n")) {
      if (/^```/.test(line)) fence = !fence;
      const h2 = !fence && line.match(/^## (.+)$/);
      if (h2) skipping = RELEASE_ONLY.has(h2[1].trim());
      if (!skipping) md += `${!fence && /^#{2,5} /.test(line) ? `#${line}` : line}\n`;
    }
    md += "\n";
  }
  return md;
}

function plain(html) {
  return html.replace(/<\/?(a|code|strong|em|kbd|span)\b[^>]*>/g, "").replace(/<[^>]+>/g, " ").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
}

/** A page's description for search engines: its first paragraph, cut at a word near 160 characters. */
function describe(html, fallback) {
  const first = plain(html.match(/<p class="lead">(.*?)<\/p>/s)?.[1] || html.match(/<p>(.*?)<\/p>/s)?.[1] || fallback);
  if (first.length <= 160) return first;
  return `${first.slice(0, 157).replace(/\s+\S*$/, "")}…`;
}

function shell({ name, title, body, headings, description, ver, prev, next }) {
  const url = `${SITE}${name === "index" ? "" : `${name}.html`}`;
  const menu = MENU.map(([group, items]) => `<div class="menu-group"><div class="menu-title">${group}</div><ul>${items
    .map(([page, label]) => `<li><a href="${page}.html"${page === name ? ' aria-current="page"' : ""}>${label}</a></li>`).join("")}</ul></div>`).join("");
  const toc = headings.filter((h) => h.level === 2 || h.level === 3);
  const software = name === "index" ? `<script type="application/ld+json">${JSON.stringify({
    "@context": "https://schema.org", "@type": "SoftwareApplication", name: "Switchboard", url: SITE,
    description, applicationCategory: "UtilitiesApplication", operatingSystem: "macOS 15 or later, on Apple silicon",
    softwareVersion: ver, license: "https://www.apache.org/licenses/LICENSE-2.0", image: `${SITE}images/console.jpg`,
    downloadUrl: `${GITHUB}/releases/latest`, codeRepository: GITHUB, offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    author: { "@type": "Person", name: "Robert McDermott" },
  })}</script>\n` : "";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${name === "404" ? `<base href="${BASE}">\n<meta name="robots" content="noindex">\n` : `<link rel="canonical" href="${url}">\n`}<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(description)}">
<meta property="og:site_name" content="Switchboard">
<meta property="og:title" content="${escapeHtml(title)}">
<meta property="og:description" content="${escapeHtml(description)}">
<meta property="og:type" content="website">
<meta property="og:url" content="${url}">
<meta property="og:image" content="${SITE}images/console.jpg">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="#f6f8fb" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#070b16" media="(prefers-color-scheme: dark)">
<link rel="icon" type="image/png" href="assets/icon.png">
<link rel="apple-touch-icon" href="assets/icon.png">
<link rel="stylesheet" href="assets/site.css">
<script src="assets/theme.js"></script>
<script src="assets/site.js" defer></script>
${software}</head>
<body class="page-${name}">
<a class="skip" href="#content">Skip to content</a>
<header class="top">
  <button class="menu-button" type="button" aria-label="Menu" aria-expanded="false" aria-controls="menu">☰</button>
  <a class="brand" href="index.html"><img src="assets/icon.png" alt="" width="28" height="28"><span>Switchboard</span><span class="version">v${ver}</span></a>
  <div class="search" role="search">
    <input id="search" type="search" placeholder="Search the guide" aria-label="Search the guide" autocomplete="off" spellcheck="false">
    <kbd>/</kbd>
    <div class="results" id="results" role="listbox" hidden></div>
  </div>
  <div class="theme" role="group" aria-label="Theme">
    <button type="button" data-theme-choice="light" title="Light" aria-label="Light">☀</button><button type="button" data-theme-choice="system" title="Follow the system" aria-label="Follow the system">◐</button><button type="button" data-theme-choice="dark" title="Dark" aria-label="Dark">☾</button>
  </div>
  <a class="github" href="${GITHUB}" rel="noopener">GitHub</a>
</header>
<div class="layout">
  <nav class="menu" id="menu" aria-label="Guide">${menu}</nav>
  <main id="content" class="content">
${body}
    ${prev || next ? `<nav class="pager" aria-label="Pages">${prev ? `<a class="prev" href="${prev[0]}.html"><span>Previous</span>${prev[1]}</a>` : "<span></span>"}${next ? `<a class="next" href="${next[0]}.html"><span>Next</span>${next[1]}</a>` : ""}</nav>` : ""}
    <footer class="foot">Describes Switchboard ${ver}. Apache License 2.0. Screenshots show simulated traffic. Location data is IP Geolocation by DB-IP, CC BY 4.0.</footer>
  </main>
  ${toc.length > 2 ? `<aside class="toc" aria-label="On this page"><div class="menu-title">On this page</div><ul>${toc
    .map((h) => `<li class="l${h.level}"><a href="#${h.id}">${escapeHtml(h.text)}</a></li>`).join("")}</ul></aside>` : ""}
</div>
</body>
</html>
`;
}

/** Search entries: one per section of every page. */
function searchSections(name, title, html) {
  return html.replace(/<a class="anchor"[^>]*>#<\/a>/g, "").split(/(?=<h[23] id=")/).map((part) => {
    const head = part.match(/^<h[23] id="([^"]+)">(.*?)<\/h[23]>/);
    return {
      page: name, title, heading: head ? plain(head[2]) : title,
      url: `${name}.html${head ? `#${head[1]}` : ""}`, text: plain(head ? part.slice(head[0].length) : part).slice(0, 700),
    };
  }).filter((s) => s.text || s.heading !== title);
}

// --- Checks ----------------------------------------------------------------------------------

export function check(out) {
  const problems = [];
  const pages = readdirSync(out).filter((f) => f.endsWith(".html"));
  const ids = new Map(pages.map((p) => [p, new Set([...readFileSync(join(out, p), "utf8").matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]))]));
  for (const page of pages) {
    const html = readFileSync(join(out, page), "utf8");
    for (const [, attr, target] of html.matchAll(/\s(href|src)="([^"]+)"/g)) {
      if (/^(https?:|mailto:|data:)/.test(target)) continue;
      const [file, anchor] = target.replace(BASE, "").split("#");
      const path = file || page;
      if (file && !existsSync(join(out, file))) { problems.push(`${page}: ${attr} ${target} is missing`); continue; }
      if (anchor && path.endsWith(".html") && !ids.get(path)?.has(anchor)) problems.push(`${page}: no #${anchor} in ${path}`);
    }
  }
  return problems;
}

// --- Build -----------------------------------------------------------------------------------

export function build(out) {
  const ver = version();
  rmSync(out, { recursive: true, force: true });
  mkdirSync(join(out, "assets"), { recursive: true });
  mkdirSync(join(out, "images"));
  for (const file of ["site.css", "site.js", "theme.js"]) cpSync(join(HERE, "assets", file), join(out, "assets", file));
  cpSync(join(DOCS, "icon.png"), join(out, "assets", "icon.png"));
  for (const [name, file] of Object.entries(IMAGES)) cpSync(join(REPO, file), join(out, "images", `${name}${extname(file)}`));

  const order = MENU.flatMap(([, items]) => items);
  const guideFile = join(DOCS, "GUIDE.md");
  const guide = sectionsOf(guideFile);
  const readme = sectionsOf(join(REPO, "README.md"));
  const missing = [...guide.keys()].filter((h) => !order.some(([, , source]) => source === `guide:${h}`));
  if (missing.length) throw new Error(`docs/GUIDE.md has sections with no page: ${missing.join(", ")}. Add them to MENU.`);

  // Which page holds each heading of the guide, so links between sections can find it.
  const places = new Map();
  for (const [name, , source] of order) {
    if (!source.startsWith("guide:")) continue;
    for (const h of markdown(guide.get(source.slice(6)) ?? "").headings) places.set(h.id, h.level === 1 ? `${name}.html` : `${name}.html#${h.id}`);
  }
  const place = (id) => places.get(id) ?? `#${id}`; // an unknown anchor fails the link check

  const search = [];
  for (const [index, [name, label, source]] of order.entries()) {
    let rendered;
    if (source === "home") {
      const html = placeholders(readFileSync(join(HERE, "pages", "index.html"), "utf8"), ver);
      const headings = [...html.matchAll(/<h([1-3]) id="([^"]+)">(.*?)<\/h\1>/g)].map((m) => ({ level: Number(m[1]), id: m[2], text: plain(m[3]) }));
      rendered = { html, headings };
    } else {
      const [kind, heading] = [source.split(":")[0], source.slice(source.indexOf(":") + 1)];
      const text = kind === "guide" ? guide.get(heading) : kind === "readme" ? readme.get(heading) : releasesMarkdown();
      if (!text) throw new Error(`No section "${heading}" for ${name}.html`);
      const from = kind === "guide" ? guideFile : kind === "readme" ? join(REPO, "README.md") : join(DOCS, "releases", "notes.md");
      rendered = markdown(text, { link: linker(from, place) });
    }
    const { html, headings } = rendered;
    const title = name === "index" ? "Switchboard: see every network connection on your Mac" : `${headings.find((h) => h.level === 1)?.text || label} · Switchboard`;
    writeFileSync(join(out, `${name}.html`), shell({
      name, title, body: html, headings, description: DESCRIPTIONS[name] ?? describe(html, label), ver, prev: order[index - 1], next: order[index + 1],
    }));
    search.push(...searchSections(name, label, html));
  }

  writeFileSync(join(out, "404.html"), shell({
    name: "404", title: "Page not found · Switchboard", headings: [], ver, description: "This page is not on Switchboard's website.",
    body: `<h1 id="not-found">Page not found</h1>\n<p>Nothing is at this address. Try the search above, or start from the <a href="index.html">overview</a>.</p>`,
  }));
  writeFileSync(join(out, "assets", "search.json"), JSON.stringify(search));
  writeFileSync(join(out, "robots.txt"), `User-agent: *\nAllow: /\n\nSitemap: ${SITE}sitemap.xml\n`);
  writeFileSync(join(out, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${order
    .map(([name]) => `  <url><loc>${SITE}${name === "index" ? "" : `${name}.html`}</loc></url>`).join("\n")}\n</urlset>\n`);
  writeFileSync(join(out, ".nojekyll"), "");
  return { pages: order.length, sections: search.length, problems: check(out) };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
  const out = resolve(flag("--out") || join(REPO, "build", "site"));
  const result = build(out);
  if (result.problems.length) {
    console.error(`Broken links:\n  ${result.problems.join("\n  ")}`);
    process.exit(1);
  }
  console.log(`Built ${result.pages} pages (${result.sections} searchable sections) in ${relative(process.cwd(), out) || "."}`);
  const target = flag("--publish");
  if (target) {
    const dest = resolve(target);
    if (!existsSync(join(dest, ".git"))) {
      console.error(`${dest} is not a checkout of the gh-pages branch; nothing was published.`);
      process.exit(1);
    }
    for (const entry of readdirSync(dest)) if (entry !== ".git") rmSync(join(dest, entry), { recursive: true, force: true });
    cpSync(out, dest, { recursive: true });
    console.log(`Copied into ${dest}. Look it over, then commit and push the gh-pages branch to publish.`);
  }
}
