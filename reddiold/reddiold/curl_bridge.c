#include "curl_bridge.h"
#include <curl/curl.h>
#include <stdlib.h>

// Wraps the CURL easy handle together with an optional Range/etc. header list —
// CurlHandle (opaque void*) now points at one of these instead of a bare CURL*.
// Needed to support curl_bridge_add_header (Range: bytes=X-Y for video/audio segment
// fetches) since curl_slist_free_all must be called on cleanup to avoid leaking it.
typedef struct {
    CURL *easy;
    struct curl_slist *headers;
} CurlBridgeCtx;

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
}

CurlHandle curl_bridge_init(void) {
    CurlBridgeCtx *ctx = (CurlBridgeCtx *)malloc(sizeof(CurlBridgeCtx));
    ctx->easy = curl_easy_init();
    ctx->headers = NULL;
    return ctx;
}

void curl_bridge_cleanup(CurlHandle h) {
    CurlBridgeCtx *ctx = (CurlBridgeCtx *)h;
    if (!ctx) return;
    if (ctx->headers) curl_slist_free_all(ctx->headers);
    curl_easy_cleanup(ctx->easy);
    free(ctx);
}

void curl_bridge_set_url(CurlHandle h, const char *url) {
    curl_easy_setopt(((CurlBridgeCtx *)h)->easy, CURLOPT_URL, url);
}

void curl_bridge_set_user_agent(CurlHandle h, const char *ua) {
    curl_easy_setopt(((CurlBridgeCtx *)h)->easy, CURLOPT_USERAGENT, ua);
}

void curl_bridge_set_ssl_noverify(CurlHandle h) {
    CURL *easy = ((CurlBridgeCtx *)h)->easy;
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 0L);
}

void curl_bridge_set_follow_redirects(CurlHandle h) {
    CURL *easy = ((CurlBridgeCtx *)h)->easy;
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 10L);
}

void curl_bridge_set_timeout(CurlHandle h, long secs) {
    curl_easy_setopt(((CurlBridgeCtx *)h)->easy, CURLOPT_TIMEOUT, secs);
}

void curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata) {
    CURL *easy = ((CurlBridgeCtx *)h)->easy;
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, fn);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, userdata);
}

void curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp) {
    CURL *easy = ((CurlBridgeCtx *)h)->easy;
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, fn);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, clientp);
}

void curl_bridge_add_header(CurlHandle h, const char *header) {
    CurlBridgeCtx *ctx = (CurlBridgeCtx *)h;
    ctx->headers = curl_slist_append(ctx->headers, header);
    curl_easy_setopt(ctx->easy, CURLOPT_HTTPHEADER, ctx->headers);
}

int curl_bridge_perform(CurlHandle h) {
    return (int)curl_easy_perform(((CurlBridgeCtx *)h)->easy);
}

long curl_bridge_response_code(CurlHandle h) {
    long code = 0;
    curl_easy_getinfo(((CurlBridgeCtx *)h)->easy, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *curl_bridge_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}
