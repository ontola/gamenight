
"use strict";
// ---------------------------------------------------------------------------
// Minimal markdown renderer, sized to exactly what the guide uses:
// headings, hr, paragraphs, lists (ul/ol/checklists), tables, fenced code,
// blockquotes, and inline code/bold/italic/links.
// ---------------------------------------------------------------------------
const REPO = "https://github.com/ontola/gamenight/blob/main/";

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
// The guide's links are relative to docs/ — rewrite them to GitHub.
function resolveHref(href) {
  if (/^(https?:|#|mailto:)/.test(href)) return href;
  const parts = ("docs/" + href).split("/");
  const out = [];
  for (const p of parts) {
    if (p === "..") out.pop();
    else if (p !== ".") out.push(p);
  }
  return REPO + out.join("/");
}
function inline(s) {
  // Protect code spans from further formatting.
  const codes = [];
  s = esc(s).replace(/`([^`]+)`/g, (_, c) => {
    codes.push(c);
    return "\u0000" + (codes.length - 1) + "\u0000";
  });
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[\s(])\*([^*]+)\*/g, "$1<em>$2</em>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,
    (_, text, href) => `<a href="${resolveHref(href)}">${text}</a>`);
  s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
  return s;
}
function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}
function splitRow(line) {
  // Cells of a table row, honouring escaped \|.
  return line.replace(/^\||\|\s*$/g, "").split(/(?<!\\)\|/)
    .map((c) => c.trim().replace(/\\\|/g, "|"));
}

function renderMarkdown(md) {
  const lines = md.split("\n");
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];

    if (line.startsWith("```")) {                        // fenced code
      const buf = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) buf.push(lines[i++]);
      i++;
      out.push(`<pre><code>${esc(buf.join("\n"))}</code></pre>`);
      continue;
    }
    const h = line.match(/^(#{1,4}) (.*)/);              // headings
    if (h) {
      const level = h[1].length;
      out.push(`<h${level} id="${slug(h[2])}">${inline(h[2])}</h${level}>`);
      i++;
      continue;
    }
    if (/^-{3,}\s*$/.test(line)) { out.push("<hr>"); i++; continue; }
    if (line.startsWith("> ")) {                         // blockquote
      const buf = [];
      while (i < lines.length && lines[i].startsWith(">"))
        buf.push(lines[i++].replace(/^>\s?/, ""));
      out.push(`<blockquote>${buf.map(inline).join("<br>")}</blockquote>`);
      continue;
    }
    if (line.startsWith("|") && /^\|[\s:|-]+\|?\s*$/.test(lines[i + 1] ?? "")) {
      const header = splitRow(line);                     // table
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].startsWith("|")) rows.push(splitRow(lines[i++]));
      out.push("<table><thead><tr>"
        + header.map((c) => `<th>${inline(c)}</th>`).join("")
        + "</tr></thead><tbody>"
        + rows.map((r) => "<tr>" + r.map((c) => `<td>${inline(c)}</td>`).join("") + "</tr>").join("")
        + "</tbody></table>");
      continue;
    }
    const li = line.match(/^(-|\d+\.) (.*)/);            // lists
    if (li) {
      const ordered = li[1] !== "-";
      const items = [];
      while (i < lines.length) {
        const m = lines[i].match(/^(-|\d+\.) (.*)/);
        if (!m || (m[1] !== "-") !== ordered) break;
        let item = m[2];
        i++;
        while (i < lines.length && /^ {2,}\S/.test(lines[i]) && !lines[i].match(/^ *(-|\d+\.) /))
          item += " " + lines[i++].trim();               // wrapped lines
        items.push(item.replace(/^\[ \] /, "☐ "));
      }
      const tag = ordered ? "ol" : "ul";
      out.push(`<${tag}>` + items.map((x) => `<li>${inline(x)}</li>`).join("") + `</${tag}>`);
      continue;
    }
    if (line.trim() === "") { i++; continue; }
    const buf = [line];                                  // paragraph
    i++;
    while (i < lines.length && lines[i].trim() !== ""
      && !/^(#|```|\||>|-|\d+\.|-{3,})/.test(lines[i])) buf.push(lines[i++]);
    out.push(`<p>${inline(buf.join(" "))}</p>`);
  }
  return out.join("\n");
}

// Deployed layout puts the guide next to this page; the repo layout keeps it
// in docs/. Try both, so `python3 -m http.server` from the repo root works.
(async () => {
  const paths = ["integrating-your-game.md", "../docs/integrating-your-game.md"];
  for (const path of paths) {
    try {
      const res = await fetch(path);
      if (!res.ok) continue;
      let md = await res.text();
      // The page's hero already says this; drop the doc's own H1 + intro line.
      document.getElementById("guide").innerHTML = renderMarkdown(md);
      return;
    } catch (_) { /* try the next path */ }
  }
  document.getElementById("guide").innerHTML =
    `<p>Couldn't load the guide here — read it on
     <a href="${REPO}docs/integrating-your-game.md">GitHub</a>.</p>`;
})();
