import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';

const PORT = parseInt(process.env.PORT || '8080', 10);
const EMBEDDING_BASE = process.env.EMBEDDING_BASE || 'http://embedding-endpoint.llm-serving.svc.cluster.local:8080/v1';
const LLM_BASE = process.env.LLM_BASE || 'http://gemma-chat.llm-serving.svc.cluster.local:8080/v1';
const MODEL_NAME = process.env.MODEL || 'gemma-4-e2b-it';
const TOP_K = parseInt(process.env.TOP_K || '1', 10);
const KNOWLEDGE_PATH = process.env.KNOWLEDGE_PATH || './knowledge.json';

// Read API key from file or environment
function getApiKey() {
  if (process.env.LLM_API_KEY) return process.env.LLM_API_KEY.trim();
  const keyFiles = ['/etc/llm/api-keys/api-keys', '.secrets/api-keys'];
  for (const f of keyFiles) {
    if (existsSync(f)) {
      const line = readFileSync(f, 'utf8').split('\n')[0].trim();
      if (line) return line;
    }
  }
  return '';
}

const API_KEY = getApiKey();
const AUTH_HEADER = API_KEY ? { Authorization: `Bearer ${API_KEY}` } : {};

// Load knowledge passages
let passages = [];
try {
  const raw = JSON.parse(readFileSync(KNOWLEDGE_PATH, 'utf8'));
  passages = raw.passages || [];
  console.log(`Loaded ${passages.length} knowledge passages from ${KNOWLEDGE_PATH}`);
} catch (err) {
  console.error(`Failed to load knowledge passages: ${err.message}`);
}

let passageEmbeddings = null;
let isReady = false;

function dot(a, b) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
}

async function embed(texts) {
  const res = await fetch(`${EMBEDDING_BASE}/embeddings`, {
    method: 'POST',
    headers: { ...AUTH_HEADER, 'Content-Type': 'application/json' },
    body: JSON.stringify({ input: texts }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Embedding request failed (${res.status}): ${errText}`);
  }
  const data = await res.json();
  return data.data.sort((a, b) => a.index - b.index).map((d) => d.embedding);
}

async function warmKnowledgeEmbeddings() {
  if (passages.length === 0) {
    isReady = true;
    return;
  }
  console.log(`Pre-computing embeddings for ${passages.length} passages...`);
  try {
    const texts = passages.map((p) => `title: none | text: ${p.text}`);
    passageEmbeddings = await embed(texts);
    isReady = true;
    console.log(`Knowledge base warmed up and ready.`);
  } catch (err) {
    console.warn(`Warmup deferred (embedding endpoint not yet ready): ${err.message}`);
    // Retry in 5s
    setTimeout(warmKnowledgeEmbeddings, 5000);
  }
}

// Start warmup
warmKnowledgeEmbeddings();

async function retrieve(query, k = TOP_K) {
  if (!isReady || !passageEmbeddings) {
    // If embeddings not ready, attempt one-off fetch
    await warmKnowledgeEmbeddings();
  }
  if (!passageEmbeddings || passageEmbeddings.length === 0) {
    return [];
  }
  const [qEmb] = await embed([`task: search result | query: ${query}`]);
  const scored = passages.map((p, idx) => ({
    passage: p,
    score: dot(qEmb, passageEmbeddings[idx]),
  }));
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, k);
}

const server = http.createServer(async (req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && (url.pathname === '/health' || url.pathname === '/readyz')) {
    res.writeHead(isReady ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: isReady ? 'ok' : 'initializing', passages: passages.length }));
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/v1/models' || url.pathname === '/models')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      object: 'list',
      data: [
        {
          id: 'gemma-4-e2b-grounded',
          object: 'model',
          created: 1730000000,
          owned_by: 'sovereign-llm',
        },
        {
          id: 'gemma-4-e2b-it',
          object: 'model',
          created: 1730000000,
          owned_by: 'sovereign-llm',
        },
      ],
    }));
    return;
  }

  if (req.method === 'POST' && url.pathname === '/v1/chat/completions') {
    let bodyText = '';
    req.on('data', (chunk) => { bodyText += chunk; });
    req.on('end', async () => {
      try {
        const body = JSON.parse(bodyText);
        const messages = body.messages || [];
        
        // Find latest user prompt
        let lastUserMsg = '';
        for (let i = messages.length - 1; i >= 0; i--) {
          if (messages[i].role === 'user') {
            lastUserMsg = messages[i].content;
            break;
          }
        }

        // Retrieve top passages
        let contextText = '';
        if (lastUserMsg) {
          const results = await retrieve(lastUserMsg, TOP_K);
          if (results.length > 0) {
            contextText = results
              .map((r, i) => `[Source ${r.passage.id}]: ${r.passage.text}`)
              .join('\n\n');
          }
        }

        // Build grounded prompt
        const systemPrompt =
          'You are an authoritative sovereign AI assistant. ' +
          'Answer the user question strictly using ONLY the facts provided in the Context below. ' +
          'If the Context does not state the answer, reply exactly: "The context does not contain this information." ' +
          'Cite each fact using its [Source ID]. Never speculate or introduce external unverified facts.\n\n' +
          (contextText ? `Context:\n${contextText}\n\n` : 'Context: [No relevant documents found]\n\n');

        const forwardMessages = [
          { role: 'system', content: systemPrompt },
          ...messages.filter((m) => m.role !== 'system'),
        ];

        const forwardBody = {
          ...body,
          model: MODEL_NAME,
          messages: forwardMessages,
          temperature: body.temperature !== undefined ? body.temperature : 0.0,
        };

        const isStream = Boolean(body.stream);
        const llmRes = await fetch(`${LLM_BASE}/chat/completions`, {
          method: 'POST',
          headers: {
            ...AUTH_HEADER,
            'Content-Type': 'application/json',
            ...(isStream ? { Accept: 'text/event-stream' } : {}),
          },
          body: JSON.stringify(forwardBody),
        });

        if (!llmRes.ok) {
          const errDetail = await llmRes.text();
          res.writeHead(llmRes.status, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `LLM generator error: ${errDetail}` }));
          return;
        }

        if (isStream) {
          res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
          });
          const reader = llmRes.body.getReader();
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            res.write(value);
          }
          res.end();
        } else {
          const jsonRes = await llmRes.json();
          // Rewrite model id to grounded alias
          if (jsonRes.model) jsonRes.model = 'gemma-4-e2b-grounded';
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(jsonRes));
        }
      } catch (err) {
        console.error('Error handling chat completion:', err);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Grounded Answer Retrieval Service listening on port ${PORT}`);
});
