/* Minimal same-process host, based on android-luajit-launcher (MIT).
 * Copyright (c) 2014 Hans-Werner Hilse <software@haveyouseenthiscat.de>
 * Upstream glue and license are retained in glue/. CREngine/LuaJIT are unmodified.
 */
#include <stdlib.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <android/log.h>
#include <android/asset_manager.h>
#include "glue/android_native_app_glue.h"

typedef struct lua_State lua_State;
static void handle_cmd(struct android_app *app, int32_t cmd) { (void)app; (void)cmd; }

static void report(struct android_app *app, const char *message) {
    if (!message) message = "Unknown Lua runtime error";
    __android_log_print(ANDROID_LOG_ERROR, "LegadoKO", "%s", message);
    JNIEnv *env = NULL;
    JavaVM *vm = app->activity->vm;
    int attached = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK;
    if (attached && (*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return;
    jclass cls = (*env)->GetObjectClass(env, app->activity->clazz);
    jmethodID method = (*env)->GetMethodID(env, cls, "onNativeError", "(Ljava/lang/String;)V");
    if (method) {
        jstring text = (*env)->NewStringUTF(env, message);
        (*env)->CallVoidMethod(env, app->activity->clazz, method, text);
        (*env)->DeleteLocalRef(env, text);
    }
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, cls);
    if (attached) (*vm)->DetachCurrentThread(vm);
}

void android_main(struct android_app *app) {
    setenv("IS_ANDROID", "true", 1);
    app->onAppCmd = handle_cmd;
    int events;
    struct android_poll_source *source;
    while (!app->window && !app->destroyRequested) {
        if (ALooper_pollAll(-1, NULL, &events, (void **)&source) >= 0 && source)
            source->process(app, source);
    }
    if (app->destroyRequested) return;

    /* Upstream's virtual-address placement workaround; this commits no physical RAM. */
    const size_t reserve_size = 144U * 1024U * 1024U;
    void *reserve = mmap(NULL, reserve_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    void *library = dlopen("libluajit.so", RTLD_NOW | RTLD_GLOBAL);
    if (reserve != MAP_FAILED) munmap(reserve, reserve_size);
    if (!library) { report(app, dlerror()); goto finish; }

    lua_State *(*newstate)(void) = dlsym(library, "luaL_newstate");
    void (*openlibs)(lua_State *) = dlsym(library, "luaL_openlibs");
    int (*loadbuffer)(lua_State *, const char *, size_t, const char *) = dlsym(library, "luaL_loadbuffer");
    void (*pushuserdata)(lua_State *, void *) = dlsym(library, "lua_pushlightuserdata");
    int (*pcall)(lua_State *, int, int, int) = dlsym(library, "lua_pcall");
    const char *(*tolstring)(lua_State *, int, size_t *) = dlsym(library, "lua_tolstring");
    void (*close)(lua_State *) = dlsym(library, "lua_close");
    if (!newstate || !openlibs || !loadbuffer || !pushuserdata || !pcall || !tolstring || !close) {
        report(app, "LuaJIT entry points missing"); goto finish;
    }
    lua_State *lua = newstate();
    if (!lua) { report(app, "Cannot allocate Lua state"); goto finish; }
    openlibs(lua);
    AAsset *asset = AAssetManager_open(app->activity->assetManager, "android.lua", AASSET_MODE_BUFFER);
    if (!asset) { report(app, "Missing android.lua"); close(lua); goto finish; }
    int status = loadbuffer(lua, AAsset_getBuffer(asset), AAsset_getLength(asset), "android.lua");
    AAsset_close(asset);
    if (!status) { pushuserdata(lua, app); status = pcall(lua, 1, -1, 0); }
    if (status) report(app, tolstring(lua, -1, NULL));
    app->onInputEvent = NULL;
    app->onAppCmd = handle_cmd;
    close(lua);

finish:
    if (library) dlclose(library); /* Java's System.loadLibrary keeps LuaJIT mapped. */
    /* Do not exit(1): Legado's bookshelf lives in this very same process. */
    app->onAppCmd = handle_cmd;
    if (!app->destroyRequested) ANativeActivity_finish(app->activity);
    while (!app->destroyRequested) {
        if (ALooper_pollAll(-1, NULL, &events, (void **)&source) >= 0 && source)
            source->process(app, source);
    }
}
