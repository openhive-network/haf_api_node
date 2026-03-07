// Hivemind (Social Graph API) benchmark
// JSON-RPC at root / via drone/jussi

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  HIVEMIND_URL, DEFAULT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  jsonRpc, JSON_HEADERS, TEST_DATA, randomItem,
} from "./config.js";

const errorRate = new Rate("hivemind_errors");
const latency = new Trend("hivemind_duration", true);

export const options = {
  scenarios: {
    hivemind: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: RAMP_UP, target: VUS },
        { duration: DURATION, target: VUS },
        { duration: RAMP_DOWN, target: 0 },
      ],
    },
  },
  thresholds: DEFAULT_THRESHOLDS,
};

function rpc(method, params, name) {
  const res = http.post(
    HIVEMIND_URL + "/",
    jsonRpc(method, params),
    { headers: JSON_HEADERS, tags: { app: "hivemind", endpoint: name || method } }
  );
  const ok = res.status === 200;
  check(res, {
    [`${method} status 200`]: () => ok,
    [`${method} no error`]: (r) => {
      try { return !JSON.parse(r.body).error; } catch { return false; }
    },
  });
  errorRate.add(!ok);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);

  group("bridge_api", () => {
    rpc("bridge.get_ranked_posts", { sort: "trending", tag: "", limit: 5 });
    rpc("bridge.get_profile", { account });
    rpc("bridge.get_account_posts", { sort: "blog", account, limit: 5 });
    rpc("bridge.account_notifications", { account, limit: 5 });
    rpc("bridge.get_trending_topics", {});
  });

  group("condenser_api", () => {
    rpc("condenser_api.get_followers", [account, "", "blog", 5]);
    rpc("condenser_api.get_following", [account, "", "blog", 5]);
    rpc("condenser_api.get_follow_count", [account]);
    rpc("condenser_api.get_content", ["gtg", TEST_DATA.permlinks.gtg]);
  });

  group("database_api", () => {
    rpc("database_api.list_votes", {
      start: ["gtg", "witness-gtg", ""], limit: 5, order: "by_comment_voter",
    });
    rpc("database_api.find_comments", {
      comments: [["gtg", "witness-gtg"]],
    });
  });

  group("hive_api", () => {
    rpc("hive.db_head_state", {});
  });

  sleep(Math.random() * 0.3);
}
