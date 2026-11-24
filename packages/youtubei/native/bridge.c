// The native half of youtubei: one QuickJS runtime and context, and the host
// primitives YouTube.js needs synchronously or faster than JavaScript does
// them (UTF-8, the system's random bytes). JavaScript never calls Dart: the
// owning isolate calls in, then takes the outbox (host.js). Everything here
// runs on that isolate's thread, except the interrupt, which other threads
// signal.
#ifdef _WIN32
#define _CRT_RAND_S // rand_s
#endif
#include "bridge.h"
#include "quickjs.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if defined(__linux__) && !defined(__ANDROID__)
#include <sys/random.h>
#endif

// The scripts embedded by hook/build.dart: host.js, the YouTube.js bundle and
// bindings.js, each zero-terminated as JS_Eval requires.
extern const unsigned char yt_host_js[];
extern const size_t yt_host_js_len;
extern const unsigned char yt_youtubejs_js[];
extern const size_t yt_youtubejs_js_len;
extern const unsigned char yt_bindings_js[];
extern const size_t yt_bindings_js_len;

#define CANCELLED_SLOTS 16

struct YtInterrupt {
  _Atomic int32_t closed;
  _Atomic int64_t cancelled[CANCELLED_SLOTS];
  _Atomic uint32_t next_slot;
};

struct YtEngine {
  JSRuntime *runtime;
  JSContext *context;
  YtInterrupt *interrupt;
  // The call whose JavaScript is running now, 0 when unknown.
  int64_t running;
};

YtInterrupt *yt_interrupt_new(void) { return calloc(1, sizeof(YtInterrupt)); }

void yt_interrupt_free(YtInterrupt *interrupt) { free(interrupt); }

void yt_interrupt_close(YtInterrupt *interrupt) { atomic_store(&interrupt->closed, 1); }

void yt_interrupt_cancel(YtInterrupt *interrupt, int64_t call) {
  uint32_t slot = atomic_fetch_add(&interrupt->next_slot, 1) % CANCELLED_SLOTS;
  atomic_store(&interrupt->cancelled[slot], call);
}

static int interrupted(JSRuntime *runtime, void *opaque) {
  (void)runtime;
  YtEngine *engine = opaque;
  if (atomic_load_explicit(&engine->interrupt->closed, memory_order_relaxed)) return 1;
  if (!engine->running) return 0;
  for (int i = 0; i < CANCELLED_SLOTS; i++) {
    if (atomic_load_explicit(&engine->interrupt->cancelled[i], memory_order_relaxed) == engine->running) return 1;
  }
  return 0;
}

static char *copy_string(const char *value) {
  if (!value) value = "QuickJS allocation failed";
  size_t size = strlen(value) + 1;
  char *result = malloc(size);
  if (result) memcpy(result, value, size);
  return result;
}

// Takes the pending exception and returns its message and stack.
static char *take_exception(YtEngine *engine) {
  JSContext *ctx = engine->context;
  JSValue error = JS_GetException(ctx);
  JSValue stack = JS_IsObject(error) ? JS_GetPropertyStr(ctx, error, "stack") : JS_UNDEFINED;
  const char *message = JS_ToCString(ctx, error);
  const char *trace = JS_IsUndefined(stack) ? NULL : JS_ToCString(ctx, stack);
  char *result;
  if (message && trace && *trace) {
    size_t size = strlen(message) + strlen(trace) + 2;
    result = malloc(size);
    if (result) {
      strcpy(result, message);
      strcat(result, "\n");
      strcat(result, trace);
    }
  } else {
    result = copy_string(message);
  }
  if (message) JS_FreeCString(ctx, message);
  if (trace) JS_FreeCString(ctx, trace);
  JS_FreeValue(ctx, stack);
  JS_FreeValue(ctx, error);
  return result;
}

// Fills [out] from the system's cryptographic random source.
static int fill_random(uint8_t *out, size_t len) {
#if defined(_WIN32)
  while (len) {
    unsigned int value;
    if (rand_s(&value)) return -1;
    size_t n = len < sizeof value ? len : sizeof value;
    memcpy(out, &value, n);
    out += n;
    len -= n;
  }
#elif defined(__linux__) && !defined(__ANDROID__)
  while (len) {
    ssize_t n = getrandom(out, len, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    out += n;
    len -= (size_t)n;
  }
#else
  arc4random_buf(out, len);
#endif
  return 0;
}

// __randomBytes(length): ArrayBuffer of random bytes, at most 64 KiB.
static JSValue js_random_bytes(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void)this_val;
  int64_t len;
  if (JS_ToInt64(ctx, &len, argc > 0 ? argv[0] : JS_UNDEFINED)) return JS_EXCEPTION;
  if (len < 0 || len > 65536) return JS_ThrowRangeError(ctx, "__randomBytes length out of range");
  uint8_t *bytes = malloc(len ? (size_t)len : 1);
  if (!bytes) return JS_ThrowOutOfMemory(ctx);
  JSValue buffer = fill_random(bytes, (size_t)len) ? JS_ThrowInternalError(ctx, "no system random source")
                                                    : JS_NewArrayBufferCopy(ctx, bytes, (size_t)len);
  free(bytes);
  return buffer;
}

// __utf8Encode(string): ArrayBuffer.
static JSValue js_utf8_encode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void)this_val;
  size_t len;
  const char *text = JS_ToCStringLen(ctx, &len, argc > 0 ? argv[0] : JS_UNDEFINED);
  if (!text) return JS_EXCEPTION;
  JSValue buffer = JS_NewArrayBufferCopy(ctx, (const uint8_t *)text, len);
  JS_FreeCString(ctx, text);
  return buffer;
}

// __utf8Decode(arrayBuffer, offset, length): string, invalid sequences as U+FFFD.
static JSValue js_utf8_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void)this_val;
  if (argc < 3) return JS_ThrowTypeError(ctx, "__utf8Decode(buffer, offset, length)");
  size_t size;
  uint8_t *bytes = JS_GetArrayBuffer(ctx, &size, argv[0]);
  if (!bytes) return JS_EXCEPTION;
  int64_t offset, length;
  if (JS_ToInt64(ctx, &offset, argv[1]) || JS_ToInt64(ctx, &length, argv[2])) return JS_EXCEPTION;
  if (offset < 0 || length < 0 || (uint64_t)offset + (uint64_t)length > size) {
    return JS_ThrowRangeError(ctx, "__utf8Decode out of bounds");
  }
  return JS_NewStringLen(ctx, (const char *)bytes + offset, (size_t)length);
}

YtEngine *yt_new(int64_t memory_limit, int64_t stack_limit, YtInterrupt *interrupt) {
  YtEngine *engine = calloc(1, sizeof(YtEngine));
  if (!engine) return NULL;
  engine->interrupt = interrupt;
  engine->runtime = JS_NewRuntime();
  if (!engine->runtime) {
    free(engine);
    return NULL;
  }
  JS_SetMemoryLimit(engine->runtime, (size_t)memory_limit);
  JS_SetMaxStackSize(engine->runtime, (size_t)stack_limit);
  JS_SetInterruptHandler(engine->runtime, interrupted, engine);
  engine->context = JS_NewContext(engine->runtime);
  if (!engine->context) {
    JS_FreeRuntime(engine->runtime);
    free(engine);
    return NULL;
  }
  JS_SetContextOpaque(engine->context, engine);
  JSValue global = JS_GetGlobalObject(engine->context);
  JS_SetPropertyStr(engine->context, global, "__randomBytes",
                    JS_NewCFunction(engine->context, js_random_bytes, "__randomBytes", 1));
  JS_SetPropertyStr(engine->context, global, "__utf8Encode",
                    JS_NewCFunction(engine->context, js_utf8_encode, "__utf8Encode", 1));
  JS_SetPropertyStr(engine->context, global, "__utf8Decode",
                    JS_NewCFunction(engine->context, js_utf8_decode, "__utf8Decode", 3));
  JS_FreeValue(engine->context, global);
  return engine;
}

void yt_free(YtEngine *engine) {
  if (!engine) return;
  JS_UpdateStackTop(engine->runtime);
  JS_FreeContext(engine->context);
  JS_FreeRuntime(engine->runtime);
  free(engine);
}

void yt_string_free(char *text) { free(text); }

void yt_set_running(YtEngine *engine, int64_t call) { engine->running = call; }

static char *eval(YtEngine *engine, const char *source, size_t len, const char *filename) {
  JS_UpdateStackTop(engine->runtime);
  JSValue value = JS_Eval(engine->context, source, len, filename, JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) return take_exception(engine);
  JS_FreeValue(engine->context, value);
  return NULL;
}

// Evaluates a zero-terminated script; returns NULL or the error to free.
char *yt_eval(YtEngine *engine, const char *source, const char *filename) {
  return eval(engine, source, strlen(source), filename);
}

// Evaluates host.js, YouTube.js and bindings.js.
char *yt_load(YtEngine *engine) {
  char *error = eval(engine, (const char *)yt_host_js, yt_host_js_len, "host.js");
  if (!error) error = eval(engine, (const char *)yt_youtubejs_js, yt_youtubejs_js_len, "youtubejs.js");
  if (!error) error = eval(engine, (const char *)yt_bindings_js, yt_bindings_js_len, "bindings.js");
  return error;
}

// Runs every pending promise job; returns NULL or the error to free.
char *yt_pump(YtEngine *engine) {
  JS_UpdateStackTop(engine->runtime);
  while (JS_IsJobPending(engine->runtime)) {
    JSContext *context = NULL;
    if (JS_ExecutePendingJob(engine->runtime, &context) < 0) return take_exception(engine);
  }
  return NULL;
}

// Calls globalThis[name](JSON.parse(json), bytes) where bytes is an
// ArrayBuffer, or undefined when NULL. Returns NULL or the error to free.
char *yt_deliver(YtEngine *engine, const char *name, const char *json, int64_t json_len, const uint8_t *bytes,
                 int64_t bytes_len) {
  JSContext *ctx = engine->context;
  JS_UpdateStackTop(engine->runtime);
  JSValue global = JS_GetGlobalObject(ctx);
  JSValue fn = JS_GetPropertyStr(ctx, global, name);
  JSValue args[2] = {JS_ParseJSON(ctx, json, (size_t)json_len, "<deliver>"),
                     bytes ? JS_NewArrayBufferCopy(ctx, bytes, (size_t)bytes_len) : JS_UNDEFINED};
  char *error = NULL;
  if (JS_IsException(args[0]) || JS_IsException(args[1])) {
    error = take_exception(engine);
  } else {
    JSValue result = JS_Call(ctx, fn, global, 2, args);
    if (JS_IsException(result)) error = take_exception(engine);
    JS_FreeValue(ctx, result);
  }
  JS_FreeValue(ctx, args[0]);
  JS_FreeValue(ctx, args[1]);
  JS_FreeValue(ctx, fn);
  JS_FreeValue(ctx, global);
  return error;
}

// Sets *outbox to what JavaScript queued since the last take, as a JSON
// array to free with yt_string_free, or NULL when it queued nothing. Returns
// NULL or the error to free.
char *yt_take_outbox(YtEngine *engine, char **outbox) {
  JSContext *ctx = engine->context;
  *outbox = NULL;
  JS_UpdateStackTop(engine->runtime);
  JSValue global = JS_GetGlobalObject(ctx);
  JSValue fn = JS_GetPropertyStr(ctx, global, "__takeOutbox");
  JSValue result = JS_Call(ctx, fn, global, 0, NULL);
  char *error = NULL;
  if (JS_IsException(result)) {
    error = take_exception(engine);
  } else {
    size_t len;
    const char *text = JS_ToCStringLen(ctx, &len, result);
    if (!text) {
      error = take_exception(engine);
    } else {
      if (len) {
        *outbox = malloc(len + 1);
        if (*outbox) memcpy(*outbox, text, len + 1);
        else error = copy_string(NULL);
      }
      JS_FreeCString(ctx, text);
    }
  }
  JS_FreeValue(ctx, result);
  JS_FreeValue(ctx, fn);
  JS_FreeValue(ctx, global);
  return error;
}
