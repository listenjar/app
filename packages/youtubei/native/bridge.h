// The youtubei native API. FFIgen generates lib/src/bindings.g.dart from this
// header (ffigen.yaml); bridge.c implements it.
#ifndef YOUTUBEI_BRIDGE_H
#define YOUTUBEI_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

// Shared between the owner, which cancels, and the engine, which runs JS.
typedef struct YtInterrupt YtInterrupt;
// One QuickJS runtime and context, confined to the thread that created it.
typedef struct YtEngine YtEngine;

// The synchronous host call: JavaScript's __host(name, json). The callee
// answers with yt_host_return before returning.
typedef void (*YtHost)(YtEngine *engine, const char *name, const char *args, int64_t args_len);

YtInterrupt *yt_interrupt_new(void);
void yt_interrupt_free(YtInterrupt *interrupt);
// Stops any JavaScript running now or later.
void yt_interrupt_close(YtInterrupt *interrupt);
// Stops the JavaScript a call runs, while it is the running call.
void yt_interrupt_cancel(YtInterrupt *interrupt, int64_t call);

YtEngine *yt_new(int64_t memory_limit, int64_t stack_limit, YtInterrupt *interrupt, YtHost host);
void yt_free(YtEngine *engine);
// Attributes the JavaScript about to run to a call, 0 for none.
void yt_set_running(YtEngine *engine, int64_t call);

// Each of these returns NULL, or an error message to free with yt_string_free.

// Evaluates host.js, YouTube.js and bindings.js, embedded at build time.
char *yt_load(YtEngine *engine);
// Evaluates a zero-terminated global script.
char *yt_eval(YtEngine *engine, const char *source, const char *filename);
// Runs every pending promise job.
char *yt_pump(YtEngine *engine);
// Calls globalThis[name](JSON.parse(json), bytes as an ArrayBuffer, or undefined when NULL).
char *yt_deliver(YtEngine *engine, const char *name, const char *json, int64_t json_len, const uint8_t *bytes,
                 int64_t bytes_len);

// kind: 'U' undefined, 'S' string, 'J' JSON, 'B' ArrayBuffer, 'E' throws an Error with this message.
void yt_host_return(YtEngine *engine, int32_t kind, const uint8_t *data, int64_t len);
void yt_string_free(char *text);

#endif
