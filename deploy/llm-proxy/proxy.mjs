// Token-gated reverse proxy in front of the NAS Ollama, so its OpenAI-
// compatible API can be safely exposed via Tailscale Funnel for the Supabase
// edge functions to call. Ollama itself has NO auth; this adds a bearer check.
// Only /v1/* (chat/completions, models) is forwarded — nothing else. Zero deps.
import http from 'node:http';

const KEY = process.env.LOCAL_LLM_KEY || '';
const OLLAMA = process.env.OLLAMA_URL || 'http://127.0.0.1:11434';
const PORT = Number(process.env.PROXY_PORT || 11435);
if (!KEY) { console.error('LOCAL_LLM_KEY required'); process.exit(1); }

const log = (m) => console.log(`[llm-proxy] ${new Date().toISOString()} ${m}`);

http.createServer((req, res) => {
  const auth = req.headers['authorization'] || '';
  if (auth !== `Bearer ${KEY}`) { res.writeHead(401).end('unauthorized'); return; }
  if (!req.url.startsWith('/v1/')) { res.writeHead(404).end('not found'); return; }
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const u = new URL(OLLAMA + req.url);
    const p = http.request(u, { method: req.method, headers: { 'content-type': 'application/json' } }, (up) => {
      res.writeHead(up.statusCode || 502, { 'content-type': 'application/json' });
      up.pipe(res);
    });
    p.on('error', (e) => { log(`upstream error: ${e.message}`); res.writeHead(502).end('bad gateway'); });
    p.end(body);
  });
}).listen(PORT, '0.0.0.0', () => log(`up on :${PORT} -> ${OLLAMA}`));
