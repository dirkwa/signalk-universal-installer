// Render the repo README into the published site's index.html.
//
//   tsx scripts/render-index.ts <src-readme> <dest-html> <installer-version>
//
// Pages deploys this repo as a workflow artifact of static files. Nothing in
// that path converts Markdown, so staging the README as index.md alone left the
// site root a 404 while every file beneath it served -- and the root is what the
// repo's homepage field and the README's "quick start" links point at.
//
// The README is the single source: rendering it here means the landing page
// cannot drift from the documentation the way a hand-written copy would.

import MarkdownIt from 'markdown-it'
import { readFileSync, writeFileSync } from 'node:fs'

const [src, dest, version] = process.argv.slice(2)

if (!src || !dest || !version) {
    console.error(
        'usage: render-index.ts <src-readme> <dest-html> <installer-version>'
    )
    process.exit(2)
}

// html: false — the README is ours, but rendering it as trusted HTML would make
// any future embedded markup a way to inject script into the site root. Nothing
// in the README needs raw HTML, so the safe setting costs nothing.
const md = new MarkdownIt({ html: false, linkify: true, typographer: false })

const ENTITIES: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
}

const escapeHtml = (s: string): string =>
    s.replace(/[&<>"]/g, (c) => ENTITIES[c] ?? c)

const body = md.render(readFileSync(src, 'utf8'))

// Relative links in the README point at paths in the GitHub repo, not at the
// published tree (docs/halpi2.md exists in both, .devcontainer/ in only one).
// Rewriting them to absolute GitHub URLs keeps every link on the landing page
// resolvable. Anchors and absolute URLs are left alone.
const REPO = 'https://github.com/dirkwa/signalk-universal-installer/blob/master/'
const withLinks = body.replace(
    /href="(?!https?:|#|mailto:)([^"]+)"/g,
    (_m, path: string) => `href="${REPO}${path.replace(/^\.\//, '')}"`
)

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Signal K Universal Installer</title>
<style>
  :root { color-scheme: light dark; }
  body { max-width: 46rem; margin: 3rem auto; padding: 0 1.5rem;
         font: 16px/1.65 system-ui, -apple-system, sans-serif;
         color: #1a1a1a; background: #fff; }
  h1, h2, h3 { line-height: 1.25; margin-top: 2rem; }
  h1 { margin-top: 0; }
  pre { background: #f4f4f4; padding: .8rem 1rem; overflow-x: auto;
        border-radius: 6px; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
         font-size: .9em; }
  :not(pre) > code { background: #f4f4f4; padding: .15em .35em;
                     border-radius: 3px; }
  table { border-collapse: collapse; display: block; overflow-x: auto; }
  th, td { border: 1px solid #d0d0d0; padding: .4rem .6rem; text-align: left; }
  a { color: #0366d6; }
  footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #d0d0d0;
           font-size: .9em; color: #666; }
  @media (prefers-color-scheme: dark) {
    body { background: #121212; color: #e8e8e8; }
    pre, :not(pre) > code { background: #1e1e1e; }
    th, td { border-color: #3a3a3a; }
    a { color: #7ab8ff; }
    footer { border-top-color: #3a3a3a; color: #999; }
  }
</style>
</head>
<body>
${withLinks}<footer>Installer version <code>${escapeHtml(version)}</code>.
<a href="https://github.com/dirkwa/signalk-universal-installer">Source on GitHub</a>.</footer>
</body>
</html>
`

writeFileSync(dest, page)
console.log(`rendered ${src} -> ${dest} as ${version}`)
