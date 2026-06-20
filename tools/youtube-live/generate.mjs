// Regenerates the YouTube live snapshot the app downloads to show a streamer's
// YouTube presence alongside Twitch — without ever calling the YouTube Data API
// from a viewer's device. YouTube quota is per-project (shared by every user), so
// per-client calls don't scale; this single backend job checks a shared catalog
// once and publishes `youtube-live.json` + `twitch-youtube-aliases.json` to the
// `data` branch, where the app fetches them from raw.githubusercontent.com.
//
// Quota-efficient + ToS-compliant (no scraping):
//   1. Read the curated catalog (Twitch login -> YouTube channel ID / @handle).
//   2. Resolve any @handles to channel IDs via channels.list (forHandle).
//   3. For each channel, read up to 3 recent uploads from its uploads playlist
//      (playlistId = "UU" + channelId.slice(2), deterministic — no extra call)
//      via playlistItems.list (1 unit each).
//   4. Batch videos.list(part=snippet,liveStreamingDetails) 50 ids/1 unit to find
//      which recent videos are actually live now and read concurrentViewers.
//
// Cost ≈ (1 playlistItems unit per channel) + (1 videos.list unit per 50 videos).
// For ~150 channels that's a few hundred units per run — well under the 10k/day
// default. Tune the workflow cron to the catalog size. Everything degrades
// gracefully: any failure still writes a valid (possibly empty) snapshot.

import { readFile, writeFile } from "node:fs/promises";

const API = "https://www.googleapis.com/youtube/v3";
const API_KEY = process.env.YOUTUBE_API_KEY;

const CATALOG_PATH = "tools/youtube-live/channels.json";
const LIVE_OUTPUT_PATH = process.env.YOUTUBE_LIVE_OUTPUT ?? "youtube-live.json";
const ALIAS_OUTPUT_PATH = process.env.TWITCH_YOUTUBE_ALIASES_OUTPUT ?? "twitch-youtube-aliases.json";
const RECENT_UPLOADS_PER_CHANNEL = 3;

async function api(path, params) {
  const url = new URL(`${API}/${path}`);
  url.searchParams.set("key", API_KEY);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`YouTube ${path} ${res.status}: ${body.slice(0, 300)}`);
  }
  return res.json();
}

/** Resolve a @handle to a channel ID (channel IDs pass through untouched). */
async function resolveChannelID(entry) {
  if (entry.youtubeChannelId) return entry.youtubeChannelId.trim();
  const handle = (entry.youtubeHandle ?? "").trim().replace(/^@/, "");
  if (!handle) return null;
  try {
    const data = await api("channels", { part: "id", forHandle: handle });
    return data.items?.[0]?.id ?? null;
  } catch (err) {
    console.warn(`Could not resolve @${handle}: ${err.message}`);
    return null;
  }
}

/** Most recent upload video IDs for a channel via its deterministic uploads playlist. */
async function recentVideoIDs(channelID) {
  const uploadsPlaylist = "UU" + channelID.slice(2);
  try {
    const data = await api("playlistItems", {
      part: "contentDetails",
      maxResults: String(RECENT_UPLOADS_PER_CHANNEL),
      playlistId: uploadsPlaylist,
    });
    return (data.items ?? [])
      .map((i) => i.contentDetails?.videoId)
      .filter(Boolean);
  } catch (err) {
    console.warn(`No uploads for ${channelID}: ${err.message}`);
    return [];
  }
}

/** Batched videos.list -> map videoId -> { live, viewers, title }. */
async function liveVideoDetails(videoIDs) {
  const result = new Map();
  for (let i = 0; i < videoIDs.length; i += 50) {
    const batch = videoIDs.slice(i, i + 50);
    let data;
    try {
      data = await api("videos", {
        part: "snippet,liveStreamingDetails",
        id: batch.join(","),
      });
    } catch (err) {
      console.warn(`videos.list batch failed: ${err.message}`);
      continue;
    }
    for (const v of data.items ?? []) {
      const isLive = v.snippet?.liveBroadcastContent === "live";
      if (!isLive) continue;
      const viewersRaw = v.liveStreamingDetails?.concurrentViewers;
      result.set(v.id, {
        live: true,
        viewers: viewersRaw != null ? Number(viewersRaw) : null,
        title: v.snippet?.title ?? null,
      });
    }
  }
  return result;
}

async function main() {
  if (!API_KEY) {
    console.error("YOUTUBE_API_KEY is not set — writing empty snapshot.");
    await writeFile(
      LIVE_OUTPUT_PATH,
      JSON.stringify({ generatedAt: new Date().toISOString(), streams: {} }, null, 2)
    );
    await writeFile(ALIAS_OUTPUT_PATH, JSON.stringify({ map: {} }, null, 2));
    return;
  }

  const catalog = JSON.parse(await readFile(CATALOG_PATH, "utf8"));
  const entries = Array.isArray(catalog) ? catalog : catalog.channels ?? [];

  const aliasMap = {};
  const resolved = []; // { twitchLogin, channelID }
  for (const entry of entries) {
    const twitchLogin = (entry.twitchLogin ?? "").trim().toLowerCase();
    if (!twitchLogin) continue;
    const channelID = await resolveChannelID(entry);
    if (!channelID) continue;
    aliasMap[twitchLogin] = channelID;
    resolved.push({ twitchLogin, channelID });
  }

  // Discover candidate videos, then confirm live + viewers in one batched pass.
  const channelVideos = new Map(); // channelID -> [videoId]
  const allVideoIDs = [];
  for (const { channelID } of resolved) {
    const ids = await recentVideoIDs(channelID);
    channelVideos.set(channelID, ids);
    allVideoIDs.push(...ids);
  }

  const details = await liveVideoDetails(allVideoIDs);

  const streams = {};
  for (const { channelID } of resolved) {
    const ids = channelVideos.get(channelID) ?? [];
    const liveID = ids.find((id) => details.has(id));
    if (!liveID) continue;
    const d = details.get(liveID);
    streams[channelID] = {
      live: true,
      viewers: d.viewers,
      videoId: liveID,
      title: d.title,
    };
  }

  await writeFile(
    LIVE_OUTPUT_PATH,
    JSON.stringify({ generatedAt: new Date().toISOString(), streams }, null, 2)
  );
  await writeFile(ALIAS_OUTPUT_PATH, JSON.stringify({ map: aliasMap }, null, 2));

  console.log(
    `Tracked ${resolved.length} channels, ${Object.keys(streams).length} live now.`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
