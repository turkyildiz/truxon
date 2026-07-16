// Local receiver for the ITS Dispatch file transfer: the browser page fetches
// each stored document and POSTs it here; we write it under files/<loadEditId>/.
import { createServer } from 'node:http'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join, basename } from 'node:path'

const ROOT = new URL('./files/', import.meta.url).pathname
let saved = 0

createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', '*')
  if (req.method === 'OPTIONS') return res.end()
  if (req.method !== 'POST') { res.statusCode = 405; return res.end() }
  const u = new URL(req.url, 'http://localhost')
  const dir = (u.searchParams.get('dir') || 'misc').replace(/[^A-Za-z0-9_-]/g, '_')
  const name = basename(u.searchParams.get('name') || 'file.bin').replace(/[^A-Za-z0-9. _()-]/g, '_')
  const chunks = []
  req.on('data', (c) => chunks.push(c))
  req.on('end', () => {
    const buf = Buffer.concat(chunks)
    mkdirSync(join(ROOT, dir), { recursive: true })
    writeFileSync(join(ROOT, dir, name), buf)
    saved++
    if (saved % 100 === 0) console.log(`saved ${saved} files`)
    res.end(JSON.stringify({ ok: true, bytes: buf.length }))
  })
}).listen(8123, '127.0.0.1', () => console.log('receiver listening on 127.0.0.1:8123'))
