// Smoke test: quick health check across all apps in the stack.
// Verifies each app responds, reports which are available.
// Use this before running heavier benchmarks.

import http from "k6/http";
import { check, group } from "k6";
import {
  HAFAH_URL, HIVEMIND_URL, BALANCE_URL, REPUTATION_URL, HAFBE_URL, NFT_URL,
  jsonRpc, JSON_HEADERS,
} from "./config.js";

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    checks: ["rate>0.5"], // at least half the apps should be up
  },
};

export default function () {
  group("hafah", () => {
    const res = http.get(`${HAFAH_URL}/version`);
    check(res, {
      "hafah responds": (r) => r.status === 200,
      "hafah returns version": (r) => r.body.length > 2,
    });
  });

  group("hivemind", () => {
    const res = http.post(
      HIVEMIND_URL + "/",
      jsonRpc("hive.db_head_state", {}),
      { headers: JSON_HEADERS }
    );
    check(res, {
      "hivemind responds": (r) => r.status === 200,
      "hivemind valid jsonrpc": (r) => {
        try { return JSON.parse(r.body).jsonrpc === "2.0"; } catch { return false; }
      },
    });
  });

  group("balance_tracker", () => {
    const res = http.get(`${BALANCE_URL}/version`);
    check(res, {
      "balance_tracker responds": (r) => r.status === 200,
    });
  });

  group("reputation_tracker", () => {
    const res = http.get(`${REPUTATION_URL}/version`);
    check(res, {
      "reputation_tracker responds": (r) => r.status === 200,
    });
  });

  group("haf_block_explorer", () => {
    const res = http.get(`${HAFBE_URL}/version`);
    check(res, {
      "haf_block_explorer responds": (r) => r.status === 200,
    });
  });

  group("nft_tracker", () => {
    const res = http.get(`${NFT_URL}/version`);
    check(res, {
      "nft_tracker responds": (r) => r.status === 200,
    });
  });
}
