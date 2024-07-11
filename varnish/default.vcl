# specify the VCL syntax version to use
vcl 4.1;

import std;
import bodyaccess;

backend hafah {
    .host = "haproxy";
    .port = "7003";
}

backend reputation_tracker {
    .host = "haproxy";
    .port = "7009";
}

backend hivemind_rtracker {
    .host = "haproxy";
    .port = "7010";
}

backend balance_tracker {
    .host = "haproxy";
    .port = "7004";
}

backend haf_block_explorer {
    .host = "haproxy";
    .port = "7005";
}

backend hafah_rest {
    .host = "haproxy";
    .port = "7011";
}

# backend haf_block_explorer_swagger { 
#     .host = "block-explorer-swagger";
#     .port = "80";
# }

sub recv_cachable_post {
    # many of the POST requests to PostgREST are cacheable, but varnish doesn't cache POST by default.
    # This section follows the tutorial at: https://docs.varnish-software.com/tutorials/caching-post-requests/ 
    # to cache them
    # Note: it looks like we can change many, if not all, of the cacheable POST requests into GET requests
    # on the PostgREST side, so we may be able to remove this soon.
    unset req.http.X-Body-Len;

    if (std.integer(req.http.content-length, 0) > 500000) {
        return(synth(413, "The request body size exceeds the limit"));
    }

    if (!std.cache_req_body(500KB)){
        return(hash);
    }
    set req.http.X-Body-Len = bodyaccess.len_req_body();
    return(hash);
}

sub vcl_recv {
    if (req.url == "/hafah/") {
        set req.url = "/";
        set req.backend_hint = hafah;
    } elseif (req.url ~ "^/hafah/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafah/(.*)$", "/rpc/\1");
        set req.backend_hint = hafah;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/hafbe_bal/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafbe_bal/(.*)$", "/\1");
        set req.backend_hint = balance_tracker;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/hafah-rest/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafah-rest/(.*)$", "/\1");
        set req.backend_hint = hafah_rest;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/hafbe_rep/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafbe_rep/(.*)$", "/\1");
        set req.backend_hint = reputation_tracker;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/reptracker_app/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/reptracker_app/(.*)$", "/\1");
        set req.backend_hint = hivemind_rtracker;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/hafbe/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafbe/(.*)$", "/\1");
        set req.backend_hint = haf_block_explorer;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url == "/varnishcheck") {
        return(synth(200, "Ok"));
    } else {
        return(synth(404, "Not found"));
    }
}

sub vcl_backend_fetch {
    if (bereq.http.X-Body-Len) {
        set bereq.method = "POST";
    }
}

sub vcl_backend_response {
    if (bereq.backend == hafah || bereq.backend == balance_tracker || bereq.backend == hafah_rest || bereq.backend == reputation_tracker || bereq.backend == haf_block_explorer) {
        # PostgREST generates invalid content-range headers, and varnish will refuse to cache/proxy calls because of it.
        # Until they fix it, just remove the header.  (see https://github.com/PostgREST/postgrest/issues/1089)
        unset beresp.http.Content-Range;
        unset beresp.http.date;
    }
}

sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}

sub vcl_hash {
    # the hashing happens after the vcl_recv function, so it only sees the rewritten form of
    # the req.url.  So by default, it would cache, e.g., requests for /hafah/get_status
    # and return them for /hafbe_bal/get_status.
    # Add the name of the backend to the hash to prevent this
    if (req.backend_hint == hafah) {
        hash_data("hafah");
    } else if (req.backend_hint == hafah_rest) {
        hash_data("hafah-rest");
    } else if (req.backend_hint == balance_tracker) {
        hash_data("hafbe_bal");
    } else if (req.backend_hint == reputation_tracker) {
        hash_data("hafbe_rep");
    } else if (req.backend_hint == hivemind_rtracker) {
        hash_data("reptracker_app");
    } else if (req.backend_hint == haf_block_explorer) {
        hash_data("hafbe");
    }

    # To cache POST and PUT requests
    if (req.http.X-Body-Len) {
        bodyaccess.hash_req_body();
    } else {
        hash_data("");
    }
}
