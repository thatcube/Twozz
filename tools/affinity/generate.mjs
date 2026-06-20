// Regenerates the "similar streamers" affinity graph that powers cross-category
// recommendations in the app (e.g. Ludwig -> Squeex).
//
// Pipeline (all free, runs in GitHub Actions):
//   1. Pull the CURRENT top streamers from Twitch's anonymous GQL, so the graph
//      tracks who is actually big right now.
//   2. Ask GitHub Models (free tier) for each streamer's similar streamers,
//      constrained to that live top-list.
//   3. Validate every suggested login against the top-list (kills hallucinated
//      or stale handles).
//   4. Merge over the curated seed shipped in the app and write the result.
//
// The model step is best-effort: if the token/quota is unavailable the curated
// seed (re-validated against the current top-list) is still published, so the
// output is always a valid, useful map.

import { readFile, writeFile } from "node:fs/promises";

const TWITCH_GQL = "https://gql.twitch.tv/gql";
const TWITCH_CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"; // public web client id
const MODELS_ENDPOINT = "https://models.github.ai/inference/chat/completions";
const MODEL = "openai/gpt-4o-mini";

const SEED_PATH = "Twizz/Resources/StreamerAffinity.json";
const OUTPUT_PATH = process.env.AFFINITY_OUTPUT ?? "streamer-affinity.json";
const TOP_GAMES = 28; // top categories to harvest streamers from
const PER_GAME = 30; // Twitch caps anonymous queries at 30 / page
const MAX_NEIGHBORS = 8;
const MAX_TARGETS = 200; // streamers we generate "similar to" lists for

async function twitchGQL(query, variables) {
  const res = await fetch(TWITCH_GQL, {
    method: "POST",
    headers: { "Client-ID": TWITCH_CLIENT_ID, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Twitch GQL ${res.status}`);
  return res.json();
}

// Anonymous Twitch GQL caps `first` at 30 and integrity-gates deep pagination,
// so we widen coverage by harvesting the top streamers of the top categories.
async function fetchTopStreamers() {
  const byLogin = new Map();
  const add = (login, displayName, game) => {
    const l = login?.toLowerCase();
    if (!l || byLogin.has(l)) return;
    byLogin.set(l, { login: l, displayName: displayName ?? l, game: game ?? "" });
  };

  // Overall top live streams.
  try {
    const top = await twitchGQL(
      `query { streams(first: ${PER_GAME}, options: { sort: VIEWER_COUNT }) {
         edges { node { broadcaster { login displayName } game { displayName } } } } }`,
      {}
    );
    for (const e of top?.data?.streams?.edges ?? []) {
      add(e?.node?.broadcaster?.login, e?.node?.broadcaster?.displayName, e?.node?.game?.displayName);
    }
  } catch (err) {
    console.warn(`  overall top fetch failed: ${err.message}`);
  }

  // Top categories, then top streamers per category.
  let games = [];
  try {
    const data = await twitchGQL(
      `query { games(first: ${TOP_GAMES}, options: { sort: VIEWER_COUNT }) {
         edges { node { name displayName } } } }`,
      {}
    );
    games = (data?.data?.games?.edges ?? []).map((e) => e?.node).filter(Boolean);
  } catch (err) {
    console.warn(`  top-games fetch failed: ${err.message}`);
  }

  const gameQuery = `query G($name: String!, $first: Int!) {
    game(name: $name) { streams(first: $first, sort: VIEWER_COUNT) {
      edges { node { broadcaster { login displayName } } } } } }`;
  for (const game of games) {
    try {
      const data = await twitchGQL(gameQuery, { name: game.name, first: PER_GAME });
      for (const e of data?.data?.game?.streams?.edges ?? []) {
        add(e?.node?.broadcaster?.login, e?.node?.broadcaster?.displayName, game.displayName);
      }
    } catch (err) {
      console.warn(`  game "${game.name}" fetch failed: ${err.message}`);
    }
  }

  return [...byLogin.values()];
}

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

// Ask GitHub Models for similar streamers, constrained to the provided list.
async function modelSimilar(batch, allLogins, token) {
  const roster = batch
    .map((s) => `${s.login}${s.game ? ` (${s.game})` : ""}`)
    .join(", ");
  const prompt =
    `You are mapping audience overlap between Twitch streamers ("viewers of X also watch Y"). ` +
    `From ONLY this allowed list of currently-live streamers, for each TARGET streamer give up to ${MAX_NEIGHBORS} ` +
    `OTHER streamers whose audiences overlap most — friends, frequent collaborators/co-streamers, or very similar ` +
    `content/community. Use exact lowercase logins from the list. Omit a target if you are unsure.\n\n` +
    `ALLOWED LIST: ${allLogins.join(", ")}\n\n` +
    `TARGETS: ${roster}\n\n` +
    `Respond with ONLY a JSON object mapping target login -> array of similar logins. No prose.`;

  const res = await fetch(MODELS_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0.2,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "You output strict JSON only." },
        { role: "user", content: prompt },
      ],
    }),
  });
  if (!res.ok) throw new Error(`GitHub Models ${res.status}: ${await res.text()}`);
  const json = await res.json();
  const content = json?.choices?.[0]?.message?.content ?? "{}";
  const cleaned = content.replace(/^```(?:json)?/i, "").replace(/```$/i, "").trim();
  return JSON.parse(cleaned);
}

function mergeNeighbors(into, key, values, allowed) {
  const k = key.toLowerCase();
  if (!allowed.has(k)) return;
  const existing = into.get(k) ?? [];
  const seen = new Set([k, ...existing]);
  for (const raw of values) {
    const v = String(raw).toLowerCase().trim();
    if (!v || seen.has(v) || !allowed.has(v)) continue;
    seen.add(v);
    existing.push(v);
    if (existing.length >= MAX_NEIGHBORS) break;
  }
  if (existing.length) into.set(k, existing);
}

async function main() {
  const token = process.env.GITHUB_TOKEN || process.env.MODELS_TOKEN;

  console.log("Fetching current top streamers from Twitch...");
  let top = [];
  try {
    top = await fetchTopStreamers();
  } catch (err) {
    console.warn(`Top-streamer fetch failed: ${err.message}`);
  }
  console.log(`  ${top.length} streamers.`);

  // Allowed universe = current top streamers + curated seed keys, so seed
  // relationships survive even if a streamer briefly drops off the live list.
  const seedRaw = JSON.parse(await readFile(SEED_PATH, "utf8"));
  const seedMap = seedRaw.map ?? {};
  const allowed = new Set(top.map((s) => s.login));
  for (const [k, vs] of Object.entries(seedMap)) {
    allowed.add(k.toLowerCase());
    for (const v of vs) allowed.add(String(v).toLowerCase());
  }

  const merged = new Map();

  // 1) Curated seed first (validated against the allowed universe).
  for (const [k, vs] of Object.entries(seedMap)) mergeNeighbors(merged, k, vs, allowed);

  // 2) Model-generated relationships for the current top streamers.
  if (token && top.length) {
    const allLogins = top.map((s) => s.login);
    const targets = top.slice(0, MAX_TARGETS);
    const batches = chunk(targets, 40);
    for (let i = 0; i < batches.length; i++) {
      try {
        const result = await modelSimilar(batches[i], allLogins, token);
        let added = 0;
        for (const [k, vs] of Object.entries(result)) {
          if (Array.isArray(vs)) {
            mergeNeighbors(merged, k, vs, allowed);
            added++;
          }
        }
        console.log(`  batch ${i + 1}/${batches.length}: +${added} targets`);
      } catch (err) {
        console.warn(`  batch ${i + 1}/${batches.length} failed: ${err.message}`);
      }
    }
  } else {
    console.warn("No model token or top list; publishing curated seed only.");
  }

  const map = {};
  for (const key of [...merged.keys()].sort()) map[key] = merged.get(key);

  const document = {
    version: 1,
    generatedAt: new Date().toISOString(),
    source: token ? "ci-models" : "ci-seed",
    streamerCount: Object.keys(map).length,
    map,
  };

  await writeFile(OUTPUT_PATH, JSON.stringify(document, null, 2) + "\n", "utf8");
  console.log(`Wrote ${OUTPUT_PATH} with ${document.streamerCount} mapped streamers.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
