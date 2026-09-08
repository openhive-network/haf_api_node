// HAF Stats API benchmark
// REST API at /haf-stats-api/
//
// READ THIS BEFORE CHANGING THE URLS. haf_stats is not shaped like the other apps
// benchmarked here. Its endpoints are date-windowed aggregations over rollup tables, and
// every one of them treats an OMITTED from_date as "since genesis" -- 2016-03-24
// (hive/haf_stats#34, #35). So `/network/content-volume` with no parameters is not a
// light default case, it is the single most expensive query the app can serve, and a
// benchmark written the obvious way measures nothing but that worst case on every
// iteration.
//
// Every request below therefore carries an explicit, bounded window. WINDOW_DAYS is the
// knob: raise it deliberately to characterise how cost scales with window width, rather
// than discovering genesis-width numbers by accident and reading them as typical.

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  HAF_STATS_URL, STRICT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  randomItem,
} from "./config.js";

const errorRate = new Rate("haf_stats_errors");
const latency = new Trend("haf_stats_duration", true);

const ACCOUNTS = (__ENV.HAF_STATS_ACCOUNTS || "mcfarhat,blocktrades,arcange").split(",");
const JSON_IDS = (__ENV.HAF_STATS_JSON_IDS || "follow,sm_claim_daily").split(",");

// Bounded window, ending today. See the note above.
const WINDOW_DAYS = parseInt(__ENV.HAF_STATS_WINDOW_DAYS || "30");
const to = new Date();
const from = new Date(to.getTime() - WINDOW_DAYS * 86400000);
const iso = (d) => d.toISOString().slice(0, 10);
const WINDOW = `from_date=${iso(from)}&to_date=${iso(to)}`;

export const options = {
  scenarios: {
    haf_stats: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: RAMP_UP, target: VUS },
        { duration: DURATION, target: VUS },
        { duration: RAMP_DOWN, target: 0 },
      ],
    },
  },
  thresholds: STRICT_THRESHOLDS,
};

function restGet(path, name) {
  const res = http.get(`${HAF_STATS_URL}${path}`, {
    tags: { app: "haf_stats", endpoint: name },
  });
  check(res, { [`${name} status 200`]: (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const account = randomItem(ACCOUNTS);
  const jsonId = randomItem(JSON_IDS);

  // Cheap, constant-cost endpoints. Separated so their latency does not average with
  // the aggregates below and flatter the numbers.
  group("metadata", () => {
    restGet(`/version`, "get_version");
    restGet(`/health`, "get_health");
    restGet(`/sync-status`, "get_sync_status");
  });

  // Network-wide aggregations over rollups. These dominate the profile.
  group("network", () => {
    restGet(`/network/content-volume?${WINDOW}`, "content_volume");
    restGet(`/network/engagement?${WINDOW}`, "engagement");
    restGet(`/network/daily-active-users?${WINDOW}`, "daily_active_users");
    restGet(`/network/top-accounts?${WINDOW}`, "top_accounts");
    restGet(`/network/hp-distribution?${WINDOW}`, "hp_distribution");
    // json_id is REQUIRED here -- omitting it is 400, not a default (endpoint_schema.sql).
    restGet(`/network/custom-json-usage?json_id=${jsonId}&${WINDOW}`, "custom_json_usage");
  });

  group("governance", () => {
    restGet(`/governance/influence-concentration?${WINDOW}`, "influence_concentration");
    restGet(`/witnesses/missed-blocks?${WINDOW}`, "missed_blocks");
  });

  // Per-account endpoints. Note these are NOT free at genesis width either -- the
  // per-account path does not get the same rollup shortcuts the network path does.
  group("account", () => {
    restGet(`/account/${account}/content-stats?${WINDOW}`, "account_content_stats");
    restGet(`/account/${account}/community-activity?${WINDOW}`, "account_community_activity");
    restGet(`/account/${account}/financial-summary?${WINDOW}`, "account_financial_summary");
  });

  sleep(Math.random() * 0.3);
}
