// Token-gated reverse proxy in front of the local Ollama fleet, so its OpenAI-
// compatible API can be safely exposed via Tailscale Funnel for the Supabase
// edge functions to call. Ollama itself has NO auth; this adds a bearer check.
// Only /v1/* (chat/completions, models) is forwarded — nothing else. Zero deps.
//
// Model-aware routing: heavy models (HEAVY_MODELS) go to the Lynx GPU box
// (LYNX_OLLAMA_URL); everything else stays on the NAS Ollama (OLLAMA_URL). If the
// Lynx upstream is unreachable, the request falls back to the NAS so a powered-off
// GPU box degrades quality instead of failing outright.
import http from 'node:http';
import crypto from 'node:crypto';

const KEY = process.env.LOCAL_LLM_KEY || '';
const NAS = process.env.OLLAMA_URL || 'http://127.0.0.1:11434';
const LYNX = process.env.LYNX_OLLAMA_URL || '';           // e.g. http://100.110.143.84:11434
const HEAVY = (process.env.HEAVY_MODELS || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
const PORT = Number(process.env.PROXY_PORT || 11435);
if (!KEY) { console.error('LOCAL_LLM_KEY required'); process.exit(1); }

const log = (m) => console.log(`[llm-proxy] ${new Date().toISOString()} ${m}`);

// Which upstream should serve this request? Peek at the JSON body's "model".
function pickUpstream(body) {
  if (!LYNX || !HEAVY.length) return { url: NAS, name: 'nas' };
  let model = '';
  try { model = String(JSON.parse(body.toString('utf8') || '{}').model || '').toLowerCase(); } catch { /* not JSON */ }
  const heavy = model && HEAVY.some((h) => model.includes(h));
  return heavy ? { url: LYNX, name: 'lynx' } : { url: NAS, name: 'nas' };
}

function forward(upstreamBase, req, body, res, onError) {
  const u = new URL(upstreamBase + req.url);
  const p = http.request(u, { method: req.method, headers: { 'content-type': 'application/json' } }, (up) => {
    res.writeHead(up.statusCode || 502, { 'content-type': 'application/json' });
    up.pipe(res);
  });
  p.on('error', onError);
  p.end(body);
}

http.createServer((req, res) => {
  const auth = req.headers['authorization'] || '';
  // constant-time compare (review): this proxy is Funnel-exposed, so no
  // timing side-channel on the bearer token.
  const expect = Buffer.from(`Bearer ${KEY}`);
  const got = Buffer.from(auth);
  const ok = got.length === expect.length && crypto.timingSafeEqual(got, expect);
  if (!ok) { res.writeHead(401).end('unauthorized'); return; }
  if (!req.url.startsWith('/v1/')) { res.writeHead(404).end('not found'); return; }
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const target = pickUpstream(body);
    forward(target.url, req, body, res, (e) => {
      // Lynx down → fall back to the NAS rather than 502 the caller.
      if (target.name === 'lynx') {
        log(`lynx upstream error (${e.message}); falling back to nas`);
        forward(NAS, req, body, res, (e2) => { log(`nas upstream error: ${e2.message}`); res.writeHead(502).end('bad gateway'); });
      } else {
        log(`upstream error: ${e.message}`); res.writeHead(502).end('bad gateway');
      }
    });
  });
}).listen(PORT, '0.0.0.0', () => log(`up on :${PORT} -> nas ${NAS}${LYNX ? `, heavy [${HEAVY.join(',')}] -> lynx ${LYNX}` : ''}`));
