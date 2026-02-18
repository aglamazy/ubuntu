// scripts/check-openai-key.ts
/**
 * Minimal OpenAI API key checker.
 * - Loads OPENAI_API_KEY from .env.local
 * - Sends a tiny request to /v1/responses
 * - Prints status, any error, and rate-limit headers (limit/remaining/reset)
 *
 * Run:
 *   npx tsx scripts/check-openai-key.ts
 */

import fs from "node:fs";
import path from "node:path";

// --- Load .env.local (no dependency on dotenv) ---
(function loadEnvLocal() {
  const envPath = path.resolve(process.cwd(), ".env.local");
  if (!fs.existsSync(envPath)) return;
  const lines = fs.readFileSync(envPath, "utf8").split(/\r?\n/);
  for (const line of lines) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    const key = m[1];
    // Strip surrounding quotes if present
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = val;
  }
})();

// --- Read env vars ---
const apiKey = process.env.OPENAI_API_KEY;
const orgId = process.env.OPENAI_ORG_ID || process.env.OPENAI_ORGANIZATION; // optional

if (!apiKey) {
  console.error("❌ Missing OPENAI_API_KEY (set it in .env.local)");
  process.exit(1);
}

// --- Helper to pretty-print any X-RateLimit headers ---
function dumpRateLimitHeaders(headers: Headers) {
  const wanted = [
    "x-ratelimit-limit-requests",
    "x-ratelimit-remaining-requests",
    "x-ratelimit-reset-requests",
    "x-ratelimit-limit-tokens",
    "x-ratelimit-remaining-tokens",
    "x-ratelimit-reset-tokens",
  ];
  const found: Record<string, string> = {};
  for (const name of wanted) {
    const v = headers.get(name);
    if (v) found[name] = v;
  }
  if (Object.keys(found).length === 0) {
    console.log("ℹ️  No X-RateLimit headers present.");
  } else {
    console.log("📊 Rate limit headers:");
    for (const [k, v] of Object.entries(found)) {
      console.log(`   • ${k}: ${v}`);
    }
  }
}

// --- Minimal request to verify key & surface quota/rate details ---
// Using /v1/responses with a tiny completion keeps token use near-zero.
async function main() {
  const url = "https://api.openai.com/v1/responses";

  const body = {
    model: "gpt-4o-mini",          // small, widely available model
    input: "ping",                 // tiny prompt
    max_output_tokens: 16           // keep usage minimal
  };

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${apiKey}`,
  };
  if (orgId) headers["OpenAI-Organization"] = orgId;

  console.log("▶️  Sending test request to OpenAI /v1/responses …");
  let res: Response;

  try {
    res = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
  } catch (e: any) {
    console.error("❌ Network or fetch error:", e?.message || e);
    process.exit(1);
  }

  const text = await res.text();
  const maybeJson = (() => {
    try { return JSON.parse(text); } catch { return null; }
  })();

  console.log(`\nHTTP ${res.status} ${res.statusText}`);

  dumpRateLimitHeaders(res.headers);

  if (res.ok) {
    console.log("✅ Key works. Received a successful response.");
    // (Optional) show the tiny output
    if (maybeJson?.output?.[0]?.content?.[0]?.text) {
      console.log("\nTiny output:", maybeJson.output[0].content[0].text);
    }
    process.exit(0);
  }

  // Not OK — print structured error if available
  if (maybeJson?.error) {
    const err = maybeJson.error;
    console.error("\n❌ OpenAI error:");
    console.error("   type   :", err.type);
    if (err.code) console.error("   code   :", err.code);
    if (err.param) console.error("   param  :", err.param);
    console.error("   message:", err.message);

    // Friendly hints for common cases
    if (res.status === 401) {
      console.error("\nHint: 401 usually means a bad/expired key or wrong organization.");
    } else if (res.status === 429 && (err.code === "insufficient_quota" || err.type === "insufficient_quota")) {
      console.error("\nHint: 429 insufficient_quota = billing/quota exhausted for this key/org/project.");
      console.error("      Check your plan/billing and make sure you're using the correct organization/project.");
    } else if (res.status === 429) {
      console.error("\nHint: 429 can also mean you hit a rate limit. See the rate-limit headers above for timing.");
    }
  } else {
    console.error("\n❌ Non-JSON error body:\n", text);
  }

  process.exit(2);
}

main().catch((e) => {
  console.error("❌ Unhandled error:", e);
  process.exit(1);
});

