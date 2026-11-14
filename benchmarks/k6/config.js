// Shared configuration for HAF stack k6 benchmarks

import http from "k6/http";

// Stack base URL (Caddy entrypoint). Requests through it pass Caddy, Varnish/Drone and
// HAProxy, so repeated URLs are answered from the HTTP cache.
export const STACK_URL = __ENV.STACK_URL || "http://localhost:8080";

// Per-app base URLs. Setting one targets that app's backend directly (e.g. its
// postgrest-rewriter port published by the exposed/ overlay), bypassing Caddy, Varnish,
// Drone and HAProxy; run.sh sets them from --app-url. See benchmarks/README.md.
export const HAFAH_URL = __ENV.HAFAH_URL || `${STACK_URL}/hafah-api`;
export const HIVEMIND_URL = __ENV.HIVEMIND_URL || STACK_URL; // JSON-RPC at root
export const BALANCE_URL = __ENV.BALANCE_URL || `${STACK_URL}/balance-api`;
export const REPUTATION_URL = __ENV.REPUTATION_URL || `${STACK_URL}/reputation-api`;
export const HAFBE_URL = __ENV.HAFBE_URL || `${STACK_URL}/hafbe-api`;
export const NFT_URL = __ENV.NFT_URL || `${STACK_URL}/nft-tracker-api`;
export const HAF_STATS_URL = __ENV.HAF_STATS_URL || `${STACK_URL}/haf-stats-api`;
export const HAF_FYP_URL = __ENV.HAF_FYP_URL || `${STACK_URL}/haf-fyp-api`;

// Test parameters
export const VUS = parseInt(__ENV.VUS || "10");
export const DURATION = __ENV.DURATION || "2m";
export const RAMP_UP = __ENV.RAMP_UP || "30s";
export const RAMP_DOWN = __ENV.RAMP_DOWN || "10s";
export const MAX_VUS = parseInt(__ENV.MAX_VUS || "50");

// Default thresholds
export const DEFAULT_THRESHOLDS = {
  http_req_duration: ["p(95)<2000", "p(99)<5000"],
  http_req_failed: ["rate<0.01"],
};

export const STRICT_THRESHOLDS = {
  http_req_duration: ["p(95)<500", "p(99)<1000"],
  http_req_failed: ["rate<0.01"],
};

// Last block an app has processed, read once in setup() so the block numbers drawn per
// iteration span whatever range the target stack holds. A REST app answers its
// /headblock or /last-synced-block with a bare integer.
export function fetchLastBlock(url) {
  const res = http.get(url, { tags: { endpoint: "setup" } });
  const block = parseInt(res.body);
  if (res.status !== 200 || !(block > 0)) {
    throw new Error(`cannot read the last block from ${url}: ${res.status} ${res.body}`);
  }
  return block;
}

// JSON-RPC 2.0 helper
let reqId = 0;
export function jsonRpc(method, params) {
  return JSON.stringify({
    jsonrpc: "2.0",
    id: ++reqId,
    method,
    params,
  });
}

export const JSON_HEADERS = { "Content-Type": "application/json" };

// Test data. The default accounts were all created before block 5,000,000 (so they
// exist in the 5M-block CI dataset as well as on a mainnet node): the 150 most-followed
// accounts created before 2016-08-15, read from hivemind on steem-20. Override with
// ACCOUNTS=a,b,c. A pool this size, combined with block numbers drawn per iteration
// (randomBlock), keeps most requests from repeating a URL the HTTP cache has seen.
const DEFAULT_ACCOUNTS = [
  "abasinkanga", "abit", "ace108", "acidyo", "adamkokesh", "adsactly", "aggroed",
  "alexbeyman", "alexpmorris", "allasyummyfood", "allmonitors", "always1success",
  "anahilarski", "andrarchy", "anwenbaumeister", "anyx", "arcange", "arnoldwish",
  "ash", "ats-david", "ausbitbank", "barrydutton", "beanz", "berniesanders", "bert0",
  "bitcoiner", "blocktrades", "blueorgy", "bullionstackers", "bustillo", "calaber24p",
  "canadian-coconut", "cheetah", "clayop", "corbettreport", "craig-grant", "crypt0",
  "cryptoctopus", "cryptogee", "damarth", "dan", "dana-edwards", "dantheman",
  "daveks", "deanliu", "doitvoluntarily", "dollarvigilante", "donkeypong",
  "dragonslayer109", "dwinblood", "englishtchrivy", "ericvancewalton", "exyle",
  "firepower", "foxkoit", "fulltimegeek", "furion", "fyrstikken", "gardenofeden",
  "gargon", "gavvet", "ghasemkiani", "glitterfart", "good-karma", "gtg",
  "hanshotfirst", "heiditravels", "heimindanger", "helene", "hilarski", "hr1",
  "infovore", "instructor2121", "jamtaylor", "jeffberwick", "jesta", "jlufer",
  "joseph", "joshsigurdson", "joythewanderer", "jrcornel", "justtryme90",
  "kafkanarchy84", "kaylinart", "kevinwong", "kingscrown", "klye", "knircky",
  "knozaki2015", "kommienezuspadt", "krnel", "kus-knee", "kyriacos", "levycore",
  "liberosist", "lichtblick", "liondani", "lukestokes", "lukewearechange",
  "mammasitta", "meesterboom", "mrs.steemit", "mynameisbrian", "nanzo-scoop", "ned",
  "neoxian", "noganoo", "noisy", "officialfuzzy", "oflyhigh", "oldtimer",
  "onceuponatime", "onealfa", "opheliafu", "papa-pepper", "penguinpablo", "pfunk",
  "pharesim", "pressfortruth", "qst", "quickfingersluc", "rea", "roelandp",
  "rok-sivante", "sauravrungta", "shaka", "sirwinchester", "skyefox", "slowwalker",
  "someguy123", "stan", "steemitblog", "steemlinks", "steempower", "steevc",
  "stellabelle", "stephenkendal", "surfermarly", "sweetsssj", "teamsteem",
  "the-alien", "thecryptofiend", "timcliff", "timsaid", "transisto", "trevonjb",
  "tuck-fheman", "ubg", "uwelang", "xeldal",
];

export const TEST_DATA = {
  accounts: __ENV.ACCOUNTS ? __ENV.ACCOUNTS.split(",") : DEFAULT_ACCOUNTS,
  coin_types: ["HIVE", "HBD", "VESTS"],
  ranked_sorts: ["trending", "hot", "created"],
  tags: ["", "hive", "photography", "life", "travel", "food", "steemit", "bitcoin"],
};

// Utilities
export function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

export function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function randomBlock(lastBlock) {
  return randomInt(1, lastBlock);
}
