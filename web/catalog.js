
"use strict";
// ---------------------------------------------------------------------------
// Same minimal markdown renderer as dev.html, sized to exactly what the
// catalogue guide uses — plus a link resolver that knows some of its links
// point at directories (crates, games/), not files.
// ---------------------------------------------------------------------------
const REPO = "https://github.com/ontola/gamenight";
// A sentinel char for protecting code spans, built at runtime rather than
// written as a literal escape — keeps this file itself plain text.
const NUL = String.fromCharCode(0);

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
// The guide's links are relative to catalog/ — rewrite them to GitHub,
// guessing blob vs tree from whether the leaf name looks like a file.
function resolveHref(href) {
  if (/^(https?:|#|mailto:)/.test(href)) return href;
  const parts = ("catalog/" + href).split("/");
  const out = [];
  for (const p of parts) {
    if (p === "..") out.pop();
    else if (p !== ".") out.push(p);
  }
  const leaf = out[out.length - 1] || "";
  const kind = leaf.includes(".") ? "blob" : "tree";
  return REPO + "/" + kind + "/main/" + out.join("/");
}
function inline(s) {
  // Protect code spans from further formatting.
  const codes = [];
  s = esc(s).replace(/`([^`]+)`/g, function (_, c) {
    codes.push(c);
    return NUL + (codes.length - 1) + NUL;
  });
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[\s(])\*([^*]+)\*/g, "$1<em>$2</em>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,
    function (_, text, href) { return '<a href="' + resolveHref(href) + '">' + text + "</a>"; });
  const nulPattern = new RegExp(NUL + "(\\d+)" + NUL, "g");
  s = s.replace(nulPattern, function (_, i) { return "<code>" + codes[+i] + "</code>"; });
  return s;
}
function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}
function splitRow(line) {
  // Cells of a table row, honouring escaped \|.
  return line.replace(/^\||\|\s*$/g, "").split(/(?<!\\)\|/)
    .map(function (c) { return c.trim().replace(/\\\|/g, "|"); });
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
      out.push("<pre><code>" + esc(buf.join("\n")) + "</code></pre>");
      continue;
    }
    const h = line.match(/^(#{1,4}) (.*)/);              // headings
    if (h) {
      const level = h[1].length;
      out.push("<h" + level + ' id="' + slug(h[2]) + '">' + inline(h[2]) + "</h" + level + ">");
      i++;
      continue;
    }
    if (/^-{3,}\s*$/.test(line)) { out.push("<hr>"); i++; continue; }
    if (line.startsWith("> ")) {                         // blockquote
      const buf = [];
      while (i < lines.length && lines[i].startsWith(">"))
        buf.push(lines[i++].replace(/^>\s?/, ""));
      out.push("<blockquote>" + buf.map(inline).join("<br>") + "</blockquote>");
      continue;
    }
    if (line.startsWith("|") && /^\|[\s:|-]+\|?\s*$/.test(lines[i + 1] ?? "")) {
      const header = splitRow(line);                     // table
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].startsWith("|")) rows.push(splitRow(lines[i++]));
      out.push("<table><thead><tr>"
        + header.map(function (c) { return "<th>" + inline(c) + "</th>"; }).join("")
        + "</tr></thead><tbody>"
        + rows.map(function (r) { return "<tr>" + r.map(function (c) { return "<td>" + inline(c) + "</td>"; }).join("") + "</tr>"; }).join("")
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
      out.push("<" + tag + ">" + items.map(function (x) { return "<li>" + inline(x) + "</li>"; }).join("") + "</" + tag + ">");
      continue;
    }
    if (line.trim() === "") { i++; continue; }
    const buf = [line];                                  // paragraph
    i++;
    while (i < lines.length && lines[i].trim() !== ""
      && !/^(#|```|\||>|-|\d+\.|-{3,})/.test(lines[i])) buf.push(lines[i++]);
    out.push("<p>" + inline(buf.join(" ")) + "</p>");
  }
  return out.join("\n");
}

// Deployed layout puts the guide next to this page; the repo layout keeps it
// in catalog/. Try both, so `python3 -m http.server` from the repo root works.
(async function () {
  const paths = ["catalog.md", "../catalog/README.md"];
  for (const path of paths) {
    try {
      const res = await fetch(path);
      if (!res.ok) continue;
      let md = await res.text();
      document.getElementById("guide").innerHTML = renderMarkdown(md);
      return;
    } catch (_) { /* try the next path */ }
  }
  document.getElementById("guide").innerHTML =
    '<p>Couldn\'t load the guide here — read it on ' +
    '<a href="' + REPO + '/blob/main/catalog/README.md">GitHub</a>.</p>';
})();
