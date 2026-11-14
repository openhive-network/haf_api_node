// Hivemind (Social Graph API) benchmark
// JSON-RPC at root / via drone
//
// Methods and parameters checked against hivemind on steem-20 (2026-11-14), both
// through the stack and on its backend port. Each iteration draws an account, a ranked
// feed and one of the account's own posts, so Drone's short per-method cache rarely
// answers twice for the same request.

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

function resultOf(res) {
  try { return JSON.parse(res.body).result; } catch { return undefined; }
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);
  let post;

  group("bridge_api", () => {
    rpc("bridge.get_ranked_posts", {
      sort: randomItem(TEST_DATA.ranked_sorts), tag: randomItem(TEST_DATA.tags), limit: 5,
    });
    rpc("bridge.get_profile", { account });
    const posts = resultOf(rpc("bridge.get_account_posts", { sort: "posts", account, limit: 5 }));
    if (Array.isArray(posts) && posts.length > 0) {
      post = randomItem(posts);
    }
    rpc("bridge.account_notifications", { account, limit: 5 });
    rpc("bridge.get_trending_topics", {});
  });

  group("condenser_api", () => {
    rpc("condenser_api.get_followers", [account, "", "blog", 5]);
    rpc("condenser_api.get_following", [account, "", "blog", 5]);
    rpc("condenser_api.get_follow_count", [account]);
    if (post) {
      rpc("condenser_api.get_content", [post.author, post.permlink]);
    }
  });

  if (post) {
    group("database_api", () => {
      rpc("database_api.list_votes", {
        start: [post.author, post.permlink, ""], limit: 5, order: "by_comment_voter",
      });
      rpc("database_api.find_comments", {
        comments: [[post.author, post.permlink]],
      });
    });
  }

  group("hive_api", () => {
    rpc("hive.db_head_state", {});
  });

  sleep(Math.random() * 0.3);
}
