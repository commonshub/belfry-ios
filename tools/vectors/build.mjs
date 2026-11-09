// Regenerates vectors/*.json from the web chat's own code (the reference implementation).
//
//   VILLAGE=~/agents/belfry/work/village-app node tools/vectors/build.mjs
//
// The web chat's model, dm, actions, access and mime modules are bundled with esbuild, with
// their store / sync / db imports swapped for the stubs in ./stubs (an in-memory event log), and
// gen.ts runs them over the cases it defines. Needs the village-app checkout with node_modules.
import { build } from 'esbuild'
import { execFileSync } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const village = path.resolve(process.env.VILLAGE ?? path.join(here, '../../../village-app'))
const out = path.join(mkdtempSync(path.join(tmpdir(), 'belfry-vectors-')), 'gen.mjs')

await build({
  entryPoints: [path.join(here, 'gen.ts')],
  bundle: true,
  platform: 'node',
  format: 'esm',
  outfile: out,
  nodePaths: [path.join(village, 'node_modules')],
  define: { 'import.meta.env': JSON.stringify({ VITE_BELFRY_DOMAIN: 'example.org', VITE_THEME: 'belfry' }) },
  alias: { '@ref': path.join(village, 'src') },
  jsx: 'automatic',
  logLevel: 'warning',
  plugins: [{
    name: 'stubs',
    setup(b) {
      b.onResolve({ filter: /^\.\/(store|sync|db)$/ }, (args) =>
        args.importer.includes(path.join('src', 'core')) ? { path: path.join(here, 'stubs', args.path.slice(2) + '.ts') } : undefined)
    },
  }],
})
execFileSync('node', [out, path.resolve(here, '../../vectors')], { stdio: 'inherit' })
