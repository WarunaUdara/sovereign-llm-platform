// Grounding eval, run inside the chat namespace (it reaches the model and the embedding service).
// Usage from the operator machine (port-forwards to the generator and embedding services):
//   LLM_API_KEY=$(head -n1 .secrets/api-keys) LLM_BASE=http://127.0.0.1:18100/v1 EMB_BASE=http://127.0.0.1:18101/v1 MODEL=qwen2.5-1.5b-instruct GOLDEN_JSON="$(cat eval/golden.json)" node eval/run-eval.mjs
// Env: MODEL (default qwen2.5-0.5b-instruct), RETRIEVE=1|0, GOLDEN path via stdin is not used; golden is inlined below.
import { readFileSync } from 'node:fs';
const MODEL = process.env.MODEL || 'qwen2.5-0.5b-instruct';
const RETRIEVE = process.env.RETRIEVE !== '0';
const KEY = process.env.LLM_API_KEY || (() => { throw new Error('set LLM_API_KEY'); })();
const LLM = process.env.LLM_BASE || 'http://model-endpoint.llm-serving.svc.cluster.local:8080/v1';
const EMB = process.env.EMB_BASE || 'http://embedding-endpoint.llm-serving.svc.cluster.local:8080/v1';
const G = JSON.parse(process.env.GOLDEN_JSON || '{}');
const H = { Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' };
const dot = (a, b) => a.reduce((s, x, i) => s + x * b[i], 0);
async function embed(texts) {
  const r = await fetch(EMB + '/embeddings', { method: 'POST', headers: H, body: JSON.stringify({ input: texts }) });
  const j = await r.json();
  return j.data.sort((a, b) => a.index - b.index).map((d) => d.embedding);
}
async function chat(messages) {
  const r = await fetch(LLM + '/chat/completions', { method: 'POST', headers: H,
    body: JSON.stringify({ model: MODEL, messages, max_tokens: 96, temperature: 0 }) });
  const j = await r.json();
  return j.choices ? j.choices[0].message.content : 'ERROR ' + JSON.stringify(j).slice(0, 80);
}
const REFUSE = /does not (contain|say|mention|state|specify)|not (in|mentioned|specified|provided|stated|contained|in the)|does not (say|mention|state|specify)|don'?t know|do not know|cannot (answer|determine|find)|no information|not available|isn'?t (in|mentioned)/i;
const P = G.passages, items = G.items;
const pEmb = RETRIEVE ? await embed(P.map((p) => 'title: none | text: ' + p.text)) : null;
let correct = 0, answerable = 0, ans_ok = 0, refusals = 0, refuse_ok = 0, rows = [];
for (const it of items) {
  let context = '';
  if (RETRIEVE) {
    const [qe] = await embed(['task: search result | query: ' + it.q]);
    const K = Number(process.env.TOPK || 1);
    const best = P.map((p, i) => [dot(qe, pEmb[i]), p]).sort((a, b) => b[0] - a[0]).slice(0, K).map((x) => x[1]);
    context = 'Context: ' + best.map((p) => p.text).join(' ') + '\n\n';
  }
  const sys = 'You answer questions. ' + (RETRIEVE ? 'Use ONLY the context. If the context does not contain the answer, reply exactly: "The context does not say."' : 'Answer briefly.');
  const reply = await chat([{ role: 'system', content: sys }, { role: 'user', content: context + 'Question: ' + it.q }]);
  let ok;
  if (it.refuse) { refusals++; ok = REFUSE.test(reply); if (ok) refuse_ok++; }
  else { answerable++; ok = it.answer_keys.some((k) => reply.toLowerCase().includes(k.toLowerCase())); if (ok) ans_ok++; }
  if (ok) correct++;
  rows.push({ q: it.q.slice(0, 50), refuse: it.refuse, ok, reply: reply.replace(/\s+/g, ' ').slice(0, 90) });
}
console.log(JSON.stringify({ model: MODEL, retrieval: RETRIEVE, total: items.length, correct,
  answerable_correct: `${ans_ok}/${answerable}`, refusals_correct: `${refuse_ok}/${refusals}`, rows }, null, 1));
