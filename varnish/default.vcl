# specify the VCL syntax version to use
vcl 4.1;

import std;
import bodyaccess;

backend hafah {
    .host = "haproxy";
    .port = "7003";
}

backend balance_tracker {
    .host = "haproxy";
    .port = "7004";
}

backend haf_block_explorer {
    .host = "haproxy";
    .port = "7005";
}

backend default {
    .host = "haproxy";
    .port = "7001";
}

sub recv_cachable_post {
    # many of the POST requests to PostgREST are cacheable, but varnish doesn't cache POST by default.
    # This section follows the tutorial at: https://docs.varnish-software.com/tutorials/caching-post-requests/ 
    # to cache them
    # Note: it looks like we can change many, if not all, of the cacheable POST requests into GET requests
    # on the PostgREST side, so we may be able to remove this soon.
    unset req.http.X-Body-Len;

    std.log("Will cache POST for: " + req.http.host + req.url);
    if (std.integer(req.http.content-length, 0) > 500000) {
        return(synth(413, "The request body size exceeds the limit"));
    }

    if (!std.cache_req_body(500KB)){
        return(hash);
    }
    set req.http.X-Body-Len = bodyaccess.len_req_body();
    std.log("req_body is " + req.http.X-Body-Len);
    return(hash);
}

sub vcl_recv {
    if (req.url ~ "^/hafah/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafah/(.*)$", "/rpc/\1");
        set req.backend_hint = hafah;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/btracker/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/btracker/(.*)$", "/rpc/\1");
        set req.backend_hint = balance_tracker;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    } elseif (req.url ~ "^/hafbe/") {
        # rewrite the URL to where PostgREST expects it, and route the call to the hafah backend
        set req.url = regsub(req.url, "^/hafbe/(.*)$", "/rpc/\1");
        set req.backend_hint = haf_block_explorer;

        if (req.method == "POST") {
            call recv_cachable_post;
        }
    }
}

sub vcl_backend_fetch {
    if (bereq.http.X-Body-Len) {
        set bereq.method = "POST";
    }
}

sub vcl_backend_response {
    if (bereq.backend == hafah || bereq.backend == balance_tracker) {
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
    # To cache POST and PUT requests
    if (req.http.X-Body-Len) {
        bodyaccess.hash_req_body();
    } else {
        hash_data("");
    }
}
