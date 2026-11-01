// Streaming chat load test: concurrency sweep for the sovereign LLM endpoint.
//
// Shape: five constant-VU levels (1, 2, 4, 6, 8 users), 40 s each, 5 s apart. Constant VUs rather
// than a ramp so every level carries its own tag, its own threshold, and its own row in the results
// table. The sweep is the experiment: it finds the point where requests start queueing.
//
// What this harness can and cannot see:
//   - http_req_waiting / ttfb_ms is time to the first byte of the response, and llama-server sends
//     its SSE headers before generating anything. It is NOT time to first token. True TTFT needs a
//     client that reads the first streamed chunk; that is load/ttft-stream.py, run separately.
//   - Stream duration is the whole reply, at max_tokens 48, temperature 0, so runs are comparable.
//
// Run in-cluster: kubectl apply -k deploy/loadtest   (see load/run-in-cluster.sh)
import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const BASE = __ENV.K6_BASE || 'http://127.0.0.1:18080';
const KEY = __ENV.K6_KEY;
const MODEL = __ENV.K6_MODEL || 'qwen2.5-0.5b-instruct';

const LEVELS = [1, 2, 4, 6, 8];
const STAGE = 40; // seconds per concurrency level
const GAP = 5; // seconds of idle between levels, so the queue drains

const streamChunks = new Counter('stream_chunks');
const ttfb = new Trend('ttfb_ms', true);

// Level-specific metrics, created in the init context so they are registered before the test starts.
// Module state does not survive into handleSummary (every VU has its own runtime), so the report has
// to read named metrics rather than an in-memory array.
const durByLevel = {};
const waitByLevel = {};
const chunksByLevel = {};
const failByLevel = {};
const reqByLevel = {};
for (const vus of LEVELS) {
  durByLevel[vus] = new Trend(`dur_users_${vus}`, true);
  waitByLevel[vus] = new Trend(`ttfb_users_${vus}`, true);
  chunksByLevel[vus] = new Counter(`chunks_users_${vus}`);
  failByLevel[vus] = new Rate(`fail_users_${vus}`);
  // Trend metrics carry no count in the summary, so requests are counted explicitly.
  reqByLevel[vus] = new Counter(`req_users_${vus}`);
}

const scenarios = {};
for (const [i, vus] of LEVELS.entries()) {
  scenarios[`users_${vus}`] = {
    executor: 'constant-vus',
    vus,
    duration: `${STAGE}s`,
    startTime: `${i * (STAGE + GAP)}s`,
    exec: 'chat',
    tags: { users: String(vus) },
  };
}

const thresholds = {
  // Abort the whole run if the endpoint is clearly broken, instead of producing five levels of noise.
  http_req_failed: [{ threshold: 'rate<0.5', abortOnFail: true, delayAbortEval: '20s' }],
};
for (const vus of LEVELS) {
  // Higher concurrency is allowed to be slower, but never to drop requests.
  thresholds[`http_req_failed{users:${vus}}`] = ['rate<0.01'];
}

export const options = {
  scenarios,
  thresholds,
};

export function chat() {
  // The scenario name is the concurrency level; k6 does not pass an argument to custom exec functions.
  const level = exec.scenario.name.split('_')[1];
  const body = JSON.stringify({
    model: MODEL,
    stream: true,
    max_tokens: 48,
    temperature: 0,
    messages: [{ role: 'user', content: 'Describe the sea in one short sentence.' }],
  });
  const res = http.post(`${BASE}/v1/chat/completions`, body, {
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    timeout: '300s',
    tags: { endpoint: 'chat' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
  ttfb.add(res.timings.waiting);
  const chunks = (res.body || '').split('\n').filter((l) => l.startsWith('data: ')).length;
  streamChunks.add(chunks);
  durByLevel[level].add(res.timings.duration);
  waitByLevel[level].add(res.timings.waiting);
  chunksByLevel[level].add(chunks);
  failByLevel[level].add(res.status !== 200);
  reqByLevel[level].add(1);
  // Think time keeps the test a measurement of concurrency, not a flood.
  sleep(1);
}

// Replace the default end-of-test summary with a table a reader can paste into a report.
// In handleSummary, each metric exposes its aggregates under `values`; the JSON export flattens them.
export function handleSummary(data) {
  const val = (name, key, fallback = 0) => {
    const m = data.metrics[name];
    if (!m || !m.values || m.values[key] === undefined) return fallback;
    return m.values[key];
  };
  const f = (n, d = 0) => (n === undefined || Number.isNaN(n) ? '-' : n.toFixed(d));
  const lines = [
    '',
    '  CONCURRENCY SWEEP (each level runs ' + STAGE + ' s, 1 s think time per VU)',
    '',
    '  users | req | fail | req/s | p50 (s) | p95 (s) | max (s) | ttfb p50 (ms) | ttfb p95 (ms) | chunks/s',
    '  ------+-----+------+-------+---------+---------+---------+---------------+--------------+---------',
  ];
  for (const vus of LEVELS) {
    const reqs = val(`req_users_${vus}`, 'count');
    const failRate = val(`fail_users_${vus}`, 'rate');
    lines.push(
      `  ${String(vus).padStart(5)} | ${String(reqs).padStart(3)} | ${String(Math.round(failRate * reqs)).padStart(4)} | ` +
        `${f(reqs / STAGE, 2).padStart(5)} | ${f(val(`dur_users_${vus}`, 'med') / 1000, 2).padStart(7)} | ` +
        `${f(val(`dur_users_${vus}`, 'p(95)') / 1000, 2).padStart(7)} | ${f(val(`dur_users_${vus}`, 'max') / 1000, 2).padStart(7)} | ` +
        `${f(val(`ttfb_users_${vus}`, 'med')).padStart(13)} | ${f(val(`ttfb_users_${vus}`, 'p(95)')).padStart(12)} | ` +
        `${f(val(`chunks_users_${vus}`, 'count') / STAGE, 2).padStart(8)}`,
    );
  }
  lines.push('');
  lines.push('  ttfb is time to first byte, not time to first token (see load/ttft-stream.py).');
  lines.push('');
  return { stdout: lines.join('\n') + '\n' };
}
