/*
 * AMMeowLoader is the project's own, deliberately narrow plugin loader.
 * It has no relationship to any external loader: no entry table, plugin
 * discovery, bundle allow-list, or configuration is reused.
 */

#include <dlfcn.h>
#include <os/log.h>

static void *g_cloud_handle;
static int g_attempted;

__attribute__((constructor(101)))
static void AMMeowLoaderInit(void) {
    if (g_attempted) {
        return;
    }
    g_attempted = 1;

    const char *path =
        "@executable_path/Frameworks/AMProjExportCloud.dylib";
    g_cloud_handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (g_cloud_handle != NULL) {
        os_log_info(
            OS_LOG_DEFAULT,
            "AMMeowLoader loaded AMProjExportCloud.dylib"
        );
        return;
    }

    const char *error = dlerror();
    os_log_error(
        OS_LOG_DEFAULT,
        "AMMeowLoader failed to load AMProjExportCloud.dylib: %{public}s",
        error != NULL ? error : "unknown dlopen error"
    );
}
