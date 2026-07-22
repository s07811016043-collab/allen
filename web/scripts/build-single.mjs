// Bundle the Vite build output into one self-contained HTML file.
// Usage: npm run build:single  ->  dist/eval-studio-standalone.html
import fs from 'node:fs'
import path from 'node:path'

const dist = path.resolve(import.meta.dirname, '../dist')
const assets = path.join(dist, 'assets')
const files = fs.readdirSync(assets)
const js = fs.readFileSync(path.join(assets, files.find((f) => f.endsWith('.js'))), 'utf8')
const css = fs.readFileSync(path.join(assets, files.find((f) => f.endsWith('.css'))), 'utf8')

// Escape sequences that would terminate the inline <script> block early.
const safeJs = js.replace(/<\/script/gi, '<\\/script').replace(/<!--/g, '<\\!--')

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Model Evaluation Studio</title>
<style>
${css}
</style>
</head>
<body>
<div id="root"></div>
<script type="module">
${safeJs}
</script>
</body>
</html>
`

const out = path.join(dist, 'eval-studio-standalone.html')
fs.writeFileSync(out, html)
console.log(`written ${out} (${(html.length / 1024).toFixed(0)} KB)`)
