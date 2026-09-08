// HAF Stats API benchmark
// REST API at /haf-stats-api/
//
// READ THIS BEFORE CHANGING THE URLS. haf_stats is not shaped like the other apps
// benchmarked here: most of its endpoints are date-windowed aggregations over rollup
// tables, and the NETWORK TIME-SERIES family treats an OMITTED from_date as "since
// genesis" -- 2016-03-24 (hive/haf_stats#35, which unified those defaults to full
// history; #34 covers get_daily_active_users alone). So `/network/content-volume` with
// no parameters is not a light default case, it is close to the most expensive query
// the app can serve, and a benchmark written the obvious way measures that worst case
// on every iteration and reports it as typical.
//
// That is why the network requests below carry an explicit bounded window. WINDOW_DAYS
// is the knob: raise it deliberately to characterise how cost scales with width.
//
// IT IS NOT UNIFORM, AND SENDING A WINDOW WHERE IT DOES NOT BELONG IS A 404. Two of
// these endpoints take NO ARGUMENTS AT ALL:
//
//     get_network_hp_distribution()             endpoint_schema.sql
//     get_governance_influence_concentration()
//
// PostgREST resolves an RPC by its query-parameter names, so passing from_date to a
// zero-argument function is PGRST202 -> 404, not an ignored parameter. Those two are
// called bare below. Two others default to something already narrow rather than to
// genesis -- get_account_content_stats to 30 days, get_account_financial_summary to
// one year -- so a window there changes the shape of the measurement rather than
// rescuing it from a pathological default.

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
    // NO WINDOW: zero-argument function, a date param here is PGRST202 -> 404.
    restGet(`/network/hp-distribution`, "hp_distribution");
    // json_id is REQUIRED here -- omitting it is 400, not a default (endpoint_schema.sql).
    restGet(`/network/custom-json-usage?json_id=${jsonId}&${WINDOW}`, "custom_json_usage");
  });

  group("governance", () => {
    // NO WINDOW: zero-argument function, same as hp-distribution.
    restGet(`/governance/influence-concentration`, "influence_concentration");
    restGet(`/witnesses/missed-blocks?${WINDOW}`, "missed_blocks");
  });

  // Per-account endpoints. These read the same *_daily rollups as the network family
  // but filtered on account_id, which is the leading index column -- so they SEEK where
  // the network path scans, and are generally the cheaper half of this profile. The
  // genuinely expensive per-account endpoint is get_account_interactions, deliberately
  // not called here.
  group("account", () => {
    restGet(`/account/${account}/content-stats?${WINDOW}`, "account_content_stats");
    restGet(`/account/${account}/community-activity?${WINDOW}`, "account_community_activity");
    restGet(`/account/${account}/financial-summary?${WINDOW}`, "account_financial_summary");
  });

  sleep(Math.random() * 0.3);
}
