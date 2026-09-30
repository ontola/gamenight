#!/usr/bin/env python3
"""Build the website docs from canonical Markdown and source excerpts.

Install docs/site/requirements.txt. --check fails when docs or watched code drift.
No network, timestamps or Git working-tree state are used in generated output.
"""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import textwrap
import unicodedata
from urllib.parse import quote, unquote, urlsplit
from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[1]
PAGES = json.loads((ROOT / "docs/site/pages.json").read_text())
REPO = "https://github.com/ontola/gamenight/blob/main/"


def route(slug):
    return "/docs" + ("/" + slug if slug else "")


def filename(slug):
    return "docs" + ("-" + slug if slug else "") + ".html"


def slugify(text):
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9 _-]", "", text).replace(" ", "-")).strip("-")


def source(path):
    file = (ROOT / path).resolve()
    if not file.is_relative_to(ROOT) or not file.is_file():
        raise ValueError(f"Missing or invalid documentation source: {path}")
    return file.read_text(encoding="utf-8")


def expand(markdown, watched):
    def excerpt(match):
        language, path, rest = match.groups()
        text = source(path)
        watched.add(path)
        markers = []
        while rest.strip():
            marker, length = json.JSONDecoder().raw_decode(rest.lstrip())
            markers.append(marker)
            rest = rest.lstrip()[length:]
        if len(markers) not in (0, 2):
            raise ValueError(f"Expected both start and end markers: {path}")
        start, end = 0, len(text)
        if markers:
            start = text.find(markers[0])
            end = text.find(markers[1], start + len(markers[0]))
            if start < 0 or end < 0:
                raise ValueError(f"Code excerpt moved or disappeared: {path}: {markers}")
        line = text.count("\n", 0, start) + 1
        code = textwrap.dedent(text[start:end]).strip()
        return f"```{language}\n{code}\n```\n\n[Source: {path}]({REPO}{path}#L{line})"
    return re.sub(r"^::: source (\w+) (\S+)(.*)$", excerpt, markdown, flags=re.M)


def render(page):
    watched = set(page.get("watch", [])) | {page["source"]}
    markdown = expand(source(page["source"]), watched)
    md = MarkdownIt("commonmark", {"html": False}).enable("table")
    tokens = md.parse(markdown)
    headings, used = [], set()
    links = []
    mapped = {(ROOT / p["source"]).resolve(): route(p["slug"]) for p in PAGES}
    for index, token in enumerate(tokens):
        if token.type == "heading_open":
            title = tokens[index + 1].content
            anchor = base = slugify(title)
            number = 1
            while anchor in used:
                anchor = f"{base}-{number}"
                number += 1
            used.add(anchor)
            token.attrSet("id", anchor)
            if token.tag == "h2":
                headings.append((anchor, title))
        for child in token.children or []:
            if child.type != "link_open":
                continue
            href = child.attrGet("href")
            url = urlsplit(href)
            if not url.scheme and not href.startswith(("/", "#")):
                target = (ROOT / page["source"]).parent.joinpath(unquote(url.path)).resolve()
                if not target.is_relative_to(ROOT) or not target.exists():
                    raise ValueError(f"Broken source link in {page['source']}: {href}")
                href = mapped.get(target, REPO + quote(target.relative_to(ROOT).as_posix()))
                if url.fragment:
                    href += "#" + url.fragment
                child.attrSet("href", href)
            if href.startswith("#"):
                href = route(page["slug"]) + href
            if href.startswith("/docs"):
                links.append(href)
    fingerprint = hashlib.sha256()
    for path in sorted(watched):
        fingerprint.update(path.encode() + b"\0" + source(path).encode())
    body = md.renderer.render(tokens, md.options, {})
    body = re.sub(r'(<pre><code(?: class="language-[^"]+")?>)([\s\S]*?)(</code></pre>)',
                  r'<div class="docs-code"><button type="button" class="docs-copy" aria-label="Copy code example">Copy</button>\1\2\3</div>', body)
    nav, group = [], None
    for item in PAGES:
        if group != item["group"]:
            if group is not None:
                nav.append("</ul>")
            group = item["group"]
            nav.append(f'<h2>{html.escape(group)}</h2><ul>')
        current = ' aria-current="page"' if page == item else ""
        nav.append(f'<li><a href="{route(item["slug"])}"{current}>{html.escape(item["title"])}</a></li>')
    nav.append("</ul>")
    toc = "".join(f'<a href="#{anchor}">{html.escape(title)}</a>' for anchor, title in headings)
    position = PAGES.index(page)
    pager = "".join(f'<a href="{route(PAGES[i]["slug"])}"><small>{label}</small>{html.escape(PAGES[i]["title"])}</a>'
                    for i, label in [(position - 1, "Previous"), (position + 1, "Next")]
                    if 0 <= i < len(PAGES))
    title = html.escape(page["title"])
    result = f'''<!doctype html>
<!-- Generated by scripts/build-docs.py. Edit {page['source']} instead. -->
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} | GameNight Docs</title><meta name="description" content="GameNight integration guide: {title}.">
<link rel="icon" href="/favicon.ico"><link rel="stylesheet" href="/web/site.css"><link rel="stylesheet" href="/web/docs.css">
<script src="/web/shell.js" defer></script><script src="/web/docs.js" defer></script></head><body>
<div id="site-shell"></div><main class="docs-page">
<a class="docs-skip" href="#docs-article">Skip to article</a>
<button class="docs-menu-toggle" type="button" aria-expanded="false" aria-controls="docs-nav-{page['slug'] or 'start'}">Documentation <span aria-hidden="true">☰</span></button>
<nav class="docs-sidebar" id="docs-nav-{page['slug'] or 'start'}" aria-label="Documentation">{''.join(nav)}</nav>
<article class="docs-article" id="docs-article"><p class="docs-eyebrow">GAMENIGHT / DOCUMENTATION</p>{body}
<footer class="docs-source"><a href="{REPO}{page['source']}">Edit this page</a><span data-source-fingerprint="{fingerprint.hexdigest()}">Built from repository sources</span></footer>
<nav class="docs-pager" aria-label="Adjacent documentation pages">{pager}</nav></article>
<aside class="docs-toc" aria-label="On this page"><strong>On this page</strong>{toc}</aside>
<p class="docs-copy-status" role="status" aria-live="polite"></p></main></body></html>
'''
    return result, used | {"docs-article"}, links


def outputs():
    pages = {route(p["slug"]): render(p) for p in PAGES}
    for name, (_, _, links) in pages.items():
        for link in links:
            url = urlsplit(link)
            if url.path not in pages or (url.fragment and unquote(url.fragment) not in pages[url.path][1]):
                raise ValueError(f"Broken docs link on {name}: {link}")
    generated = {ROOT / "web" / filename(p["slug"]): pages[route(p["slug"])][0] for p in PAGES}
    arms = "\n".join(f'        "{p["slug"]}" => Some(include_str!("{filename(p["slug"])}")),' for p in PAGES)
    generated[ROOT / "web/docs-routes.rs"] = '// Generated by scripts/build-docs.py.\npub fn page(slug: &str) -> Option<&\'static str> {\n    match slug {\n' + arms + '\n        _ => None,\n    }\n}\n'
    return generated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for path, content in outputs().items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(content, encoding="utf-8", newline="\n")
    if stale:
        raise SystemExit("Docs or watched implementation changed. Review the prose and examples, then run python scripts/build-docs.py:\n" + "\n".join(stale))
    print(f"{'Checked' if args.check else 'Built'} {len(PAGES)} documentation pages, source excerpts and local links.")


if __name__ == "__main__":
    main()
