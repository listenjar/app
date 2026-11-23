// The scripts yt_load evaluates, compiled into the library (C23 #embed:
// clang 19+ or GCC 15+), each zero-terminated as JS_Eval requires.
// youtubejs.js is the bundle `moon run desktop:bundle` builds.
#include <stddef.h>

const unsigned char yt_host_js[] = {
#embed "host.js"
  , 0};
const size_t yt_host_js_len = sizeof(yt_host_js) - 1;

const unsigned char yt_youtubejs_js[] = {
#embed "youtubejs.js"
  , 0};
const size_t yt_youtubejs_js_len = sizeof(yt_youtubejs_js) - 1;

const unsigned char yt_bindings_js[] = {
#embed "bindings.js"
  , 0};
const size_t yt_bindings_js_len = sizeof(yt_bindings_js) - 1;
