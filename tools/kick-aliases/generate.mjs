// Regenerates the Twitch -> Kick alias table the app uses to merge Kick chat
// when a streamer's Kick name differs from their Twitch login and nothing in
// their Twitch profile links the two (e.g. zackrawrr -> asmongold). These
// mappings can't be derived from profile data, so we lean on world knowledge.
//
// Pipeline (all free, runs in GitHub Actions):
//   1. Pull the CURRENT top streamers from Twitch's anonymous GQL.
//   2. Ask GitHub Models which of them stream on Kick under a DIFFERENT handle,
//      returning twitch-login -> kick-slug (only when it's confident).
//   3. Validate each suggested Kick slug against Kick's public channel API,
//      dropping ones that definitively don't exist (404) to kill hallucinations.
//   4. Merge over the curated seed shipped in the app and write the result.
//
// The model/validation steps are best-effort: if the token/quota is unavailable
// the curated seed is still published, so the output is always valid.

import { readFile, writeFile } from "node:fs/promises";

const TWITCH_GQL = "https://gql.twitch.tv/gql";
const TWITCH_CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"; // public web client id
const MODELS_ENDPOINT = "https://models.github.ai/inference/chat/completions";
const MODEL = "openai/gpt-4o-mini";
const KICK_CHANNEL_API = "https://kick.com/api/v2/channels/";
const KICK_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

const SEED_PATH = "Twizz/Resources/KickAliases.json";
const OUTPUT_PATH = process.env.KICK_ALIASES_OUTPUT ?? "kick-aliases.json";
const TOP_GAMES = 28;
const PER_GAME = 30;
const MAX_TARGETS = 200;

async function twitchGQL(query, variables) {
  const res = await fetch(TWITCH_GQL, {
    method: "POST",
    headers: { "Client-ID": TWITCH_CLIENT_ID, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Twitch GQL ${res.status}`);
  return res.json();
}

// Anonymous Twitch GQL caps `first` at 30, so widen coverage by harvesting the
// top streamers of the top categories (same approach as the affinity job).
async function fetchTopStreamers() {
  const byLogin = new Map();
  const add = (login, displayName) => {
    const l = login?.toLowerCase();
    if (!l || byLogin.has(l)) return;
    byLogin.set(l, { login: l, displayName: displayName ?? l });
  };

  try {
    const top = await twitchGQL(
      `query { streams(first: ${PER_GAME}, options: { sort: VIEWER_COUNT }) {
         edges { node { broadcaster { login displayName } } } } }`,
      {}
    );
    for (const e of top?.data?.streams?.edges ?? []) {
      add(e?.node?.broadcaster?.login, e?.node?.broadcaster?.displayName);
    }
  } catch (err) {
    console.warn(`  overall top fetch failed: ${err.message}`);
  }

  let games = [];
  try {
    const data = await twitchGQL(
      `query { games(first: ${TOP_GAMES}, options: { sort: VIEWER_COUNT }) {
         edges { node { name } } } }`,
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
        add(e?.node?.broadcaster?.login, e?.node?.broadcaster?.displayName);
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

const normalizeSlug = (raw) =>
  String(raw ?? "")
    .toLowerCase()
    .trim()
    .replace(/^@/, "")
    .replace(/[^a-z0-9_-]/g, "");

// Ask GitHub Models which streamers in the batch stream on Kick under a handle
// that DIFFERS from their Twitch login.
async function modelAliases(batch, token) {
  const roster = batch
    .map(
      (s) =>
        `${s.login}${
          s.displayName && s.displayName.toLowerCase() !== s.login ? ` (aka ${s.displayName})` : ""
        }`
    )
    .join(", ");
  const prompt =
    `Some Twitch streamers also stream on Kick under a DIFFERENT username than their Twitch login. ` +
    `For each Twitch login below, if you are confident the same person streams on Kick under a different handle, ` +
    `give their Kick username. If their Kick name is the same as their Twitch login, or you are unsure, OMIT them.\n\n` +
    `A well-known example: twitch "zackrawrr" -> kick "asmongold".\n\n` +
    `TWITCH LOGINS: ${roster}\n\n` +
    `Respond with ONLY a JSON object mapping twitch login (lowercase) -> kick username (lowercase). No prose.`;

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
      temperature: 0.1,
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

// Returns true if the Kick channel exists, false if it definitively doesn't
// (404), and null when we can't tell (network error / Cloudflare block) so the
// caller can keep a confident model suggestion rather than dropping everything.
async function kickChannelExists(slug) {
  try {
    const res = await fetch(`${KICK_CHANNEL_API}${encodeURIComponent(slug)}`, {
      headers: { "User-Agent": KICK_UA, Accept: "application/json" },
    });
    if (res.status === 404) return false;
    if (!res.ok) return null;
    const body = await res.json();
    return Boolean(body?.chatroom?.id);
  } catch {
    return null;
  }
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

  const seedRaw = JSON.parse(await readFile(SEED_PATH, "utf8"));
  const seedMap = seedRaw.map ?? {};

  // 1) Curated seed first — hand-verified, always retained.
  const merged = new Map();
  for (const [login, slug] of Object.entries(seedMap)) {
    const k = login.toLowerCase();
    const v = normalizeSlug(slug);
    if (k && v && k !== v) merged.set(k, v);
  }

  // 2) Model-suggested aliases for the current top streamers, validated.
  if (token && top.length) {
    const targets = top.slice(0, MAX_TARGETS);
    const batches = chunk(targets, 40);
    for (let i = 0; i < batches.length; i++) {
      let suggestions = {};
      try {
        suggestions = await modelAliases(batches[i], token);
      } catch (err) {
        console.warn(`  batch ${i + 1}/${batches.length} failed: ${err.message}`);
        continue;
      }

      let added = 0;
      for (const [rawLogin, rawSlug] of Object.entries(suggestions)) {
        const login = String(rawLogin).toLowerCase().trim();
        const slug = normalizeSlug(rawSlug);
        // Skip empties, no-op aliases, and anything already curated in the seed.
        if (!login || !slug || login === slug || merged.has(login)) continue;
        const exists = await kickChannelExists(slug);
        if (exists === false) continue; // definitively wrong -> drop
        merged.set(login, slug);
        added++;
      }
      console.log(`  batch ${i + 1}/${batches.length}: +${added} aliases`);
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
    aliasCount: Object.keys(map).length,
    map,
  };

  await writeFile(OUTPUT_PATH, JSON.stringify(document, null, 2) + "\n", "utf8");
  console.log(`Wrote ${OUTPUT_PATH} with ${document.aliasCount} aliases.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
