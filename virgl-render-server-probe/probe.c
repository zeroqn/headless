/* virgl-render-server-probe.c
 *
 * Host-side diagnostic for an L1 machine exposing an AMD GPU in native
 * context.  It answers one question: does the installed virglrenderer support
 * the VENUS renderer in RENDER_SERVER mode -- the path a nested libkrun L2
 * guest would use to run a Vulkan app?
 *
 * Why this matters (from the nested-L2 design):
 *  - Linux GPU native context does not nest, so an L2 guest's virtio-gpu must
 *    be virgl mode.  Guest Vulkan comes from the venus renderer.
 *  - venus is a separate axis from native-context DRM/EGL: it renders via a
 *    host Vulkan device, and it is the only renderer that honors
 *    VIRGL_RENDERER_RENDER_SERVER (bit 9).
 *  - With RENDER_SERVER set and no get_server_fd descriptor (this probe returns
 *    -1, mirroring libkrun/rutabaga which passes render_server_fd=None),
 *    virglrenderer self-spawns virgl_render_server via socketpair/fork/execv.
 *    That split is what a loftd sandbox can trap; on a bare L1 host it is the
 *    normal path.
 *
 * virglrenderer is global state: only one virgl_renderer_init() per process.
 * run-probe.sh loops over the modes, invoking this binary once per mode.
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

#include <virgl/virglrenderer.h>

#define CAPSET_VENUS 4u /* RUTABAGA_CAPSET_VENUS / VIRTGPU_DRM_CAPSET_VENUS */

/* ---- Vulkan device enumeration via the dlopen'd loader (no vulkan headers) ----
 * The venus render server is forked with the same environment, so the devices
 * listed here are exactly the ones venus can reach. */
typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef uint32_t VkFlags;

typedef enum VkResult {
    VK_SUCCESS = 0,
    VK_ERROR_OUT_OF_HOST_MEMORY = -1,
    VK_ERROR_INITIALIZATION_FAILED = -3,
    VK_ERROR_EXTENSION_NOT_PRESENT = -8,
    VK_ERROR_INCOMPATIBLE_DRIVER = -9,
} VkResult;

typedef enum VkStructureType {
    VK_STRUCTURE_TYPE_APPLICATION_INFO = 0,
    VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1,
} VkStructureType;

typedef enum VkPhysicalDeviceType {
    VK_PHYSICAL_DEVICE_TYPE_OTHER = 0,
    VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU = 1,
    VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = 2,
    VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU = 3,
    VK_PHYSICAL_DEVICE_TYPE_CPU = 4,
} VkPhysicalDeviceType;

typedef struct VkApplicationInfo {
    VkStructureType sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} VkApplicationInfo;

typedef struct VkInstanceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

/* Only the leading fields are read; the loader writes the whole struct, so the
 * caller passes a large buffer. */
typedef struct VkPhysicalDeviceProperties {
    uint32_t apiVersion;
    uint32_t driverVersion;
    uint32_t vendorID;
    uint32_t deviceID;
    VkPhysicalDeviceType deviceType;
    char deviceName[256];
    uint8_t pipelineCacheUUID[16];
} VkPhysicalDeviceProperties;

static const char *dev_type_str(VkPhysicalDeviceType t) {
    switch (t) {
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "INTEGRATED_GPU";
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "DISCRETE_GPU";
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return "VIRTUAL_GPU";
    case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "CPU";
    default:                                     return "OTHER";
    }
}

/* List every Vulkan physical device visible to this process and report how many
 * are hardware. Returns the hardware count, 0 if software-only, -1 if the
 * loader is unavailable. */
static int list_vulkan_devices(const char *label) {
    void *loader = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!loader)
        loader = dlopen("libvulkan.so", RTLD_NOW);
    if (!loader) {
        printf("[%s] warning: cannot dlopen libvulkan.so.1 (%s); device list unavailable\n",
               label, dlerror());
        return -1;
    }
    VkResult (*vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
    void (*vkDestroyInstance)(VkInstance, const void *);
    VkResult (*vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
    void (*vkGetPhysicalDeviceProperties)(VkPhysicalDevice, VkPhysicalDeviceProperties *);
    *(void **)&vkCreateInstance = dlsym(loader, "vkCreateInstance");
    *(void **)&vkDestroyInstance = dlsym(loader, "vkDestroyInstance");
    *(void **)&vkEnumeratePhysicalDevices = dlsym(loader, "vkEnumeratePhysicalDevices");
    *(void **)&vkGetPhysicalDeviceProperties = dlsym(loader, "vkGetPhysicalDeviceProperties");
    if (!vkCreateInstance || !vkDestroyInstance || !vkEnumeratePhysicalDevices ||
        !vkGetPhysicalDeviceProperties) {
        printf("[%s] warning: loader missing required vk* entry points\n", label);
        return -1;
    }

    const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "virgl-probe",
        .apiVersion = (1u << 22), /* Vulkan 1.0 */
    };
    const VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    VkInstance instance = NULL;
    VkResult r = vkCreateInstance(&info, NULL, &instance);
    if (r != VK_SUCCESS) {
        printf("[%s] warning: vkCreateInstance => %d; device list unavailable\n", label, (int)r);
        return -1;
    }

    uint32_t count = 0;
    vkEnumeratePhysicalDevices(instance, &count, NULL);
    VkPhysicalDevice *devices = calloc(count ? count : 1, sizeof(*devices));
    r = vkEnumeratePhysicalDevices(instance, &count, devices);
    if (r != VK_SUCCESS) {
        printf("[%s] warning: vkEnumeratePhysicalDevices => %d\n", label, (int)r);
        vkDestroyInstance(instance, NULL);
        return -1;
    }

    printf("[%s] vulkan devices (probe process; the render server forks with the same env):\n", label);
    int hw = 0, sw = 0;
    for (uint32_t i = 0; i < count; i++) {
        union {
            unsigned char bytes[4096];
            uint64_t align;
        } rawbuf;
        VkPhysicalDeviceProperties *p = (VkPhysicalDeviceProperties *)rawbuf.bytes;
        vkGetPhysicalDeviceProperties(devices[i], p);
        int software = p->deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU ||
                       strcasestr(p->deviceName, "llvmpipe") ||
                       strcasestr(p->deviceName, "lavapipe") ||
                       strcasestr(p->deviceName, "softpipe");
        if (software) sw++; else hw++;
        printf("[%s]   [%u] %s  type=%s vendor=0x%04x device=0x%04x  %s\n",
               label, i, p->deviceName, dev_type_str(p->deviceType),
               p->vendorID, p->deviceID, software ? "SOFTWARE" : "HARDWARE");
    }
    printf("[%s] %u device(s): %d hardware, %d software\n", label, count, hw, sw);
    vkDestroyInstance(instance, NULL);
    return hw;
}

/* ---- callbacks: mirrors libkrun/rutabaga's VIRGL_RENDERER_CALLBACKS ---- */

static const char *g_label = "?";

static void log_cb(const char *fmt, va_list ap) {
    fprintf(stderr, "[%s/virgl] ", g_label);
    vfprintf(stderr, fmt, ap);
    fflush(stderr);
}

static void write_fence(void *cookie, uint32_t fence) {
    (void)cookie;
    (void)fence;
}
static void write_context_fence(void *cookie, uint32_t ctx, uint32_t ring, uint64_t id) {
    (void)cookie;
    (void)ctx;
    (void)ring;
    (void)id;
}
/* Return -1 so virglrenderer self-spawns virgl_render_server (standalone path,
 * exactly what libkrun/rutabaga does when render_server_fd is None). */
static int get_server_fd(void *cookie, uint32_t version) {
    (void)cookie;
    (void)version;
    return -1;
}

static struct virgl_renderer_callbacks cb = {
    .version = VIRGL_RENDERER_CALLBACKS_VERSION,
    .write_fence = write_fence,
    .create_gl_context = NULL,
    .destroy_gl_context = NULL,
    .make_current = NULL,
    .get_drm_fd = NULL, /* venus renders via Vulkan, not native-context GL */
    .write_context_fence = write_context_fence,
    .get_server_fd = get_server_fd,
    .get_egl_display = NULL,
};

static int run_mode(int flags, const char *label) {
    g_label = label;
    virgl_set_debug_callback(log_cb);

    int hw_devices = list_vulkan_devices(label);

    printf("[%s] virgl_renderer_init(flags=0x%x)\n", label, (unsigned)flags);
    int ret = virgl_renderer_init(NULL, flags, &cb);
    if (ret != 0) {
        printf("[%s] virgl_renderer_init => %d  (FAIL: flag set rejected)\n", label, ret);
        return 1;
    }
    printf("[%s] virgl_renderer_init => 0  (renderer started)\n", label);

    if (flags & VIRGL_RENDERER_RENDER_SERVER)
        usleep(500 * 1000); /* give a self-spawned render server time to settle */

    uint32_t max_ver = 0, max_size = 0;
    virgl_renderer_get_cap_set(CAPSET_VENUS, &max_ver, &max_size);
    printf("[%s] venus capset(4): max_version=%u max_size=%u bytes\n",
           label, max_ver, max_size);
    /* NOTE: max_size is the fixed size of the venus capset struct, reported by
     * the proxy process -- it does NOT prove a Vulkan device exists. The device
     * list above is the real device signal. */
    int capset_ok = (max_size > 0);
    if (!capset_ok)
        printf("[%s] venus capset absent => no usable host Vulkan device behind venus\n", label);

    const char *name = "probe";
    /* Context id must be nonzero: virglrenderer returns EINVAL for ctx_id 0
     * (virgl_renderer_context_create_with_flags checks it before dispatch). */
    const uint32_t ctx_id = 1;
    int cr = virgl_renderer_context_create_with_flags(
        ctx_id, CAPSET_VENUS, (uint32_t)strlen(name), name);
    printf("[%s] venus context_create_with_flags(%u, capset=4, \"%s\") => %d\n",
           label, ctx_id, name, cr);
    if (cr == 0)
        virgl_renderer_context_destroy(ctx_id);

    virgl_renderer_cleanup(NULL);

    const char *venus_ok = (capset_ok && cr == 0) ? "venus OK" : "venus FAIL";
    if (hw_devices < 0) {
        printf("[%s] RESULT: INCONCLUSIVE - device list unavailable, cannot verify a HARDWARE device [%s]\n",
               label, venus_ok);
        return 1;
    }
    if (hw_devices == 0) {
        printf("[%s] RESULT: FAIL - no HARDWARE Vulkan device (only software, e.g. llvmpipe) [%s]\n",
               label, venus_ok);
        printf("[%s] hint: set VK_DRIVER_FILES (or VK_ICD_FILENAMES) to your hardware ICD\n"
               "       (e.g. radv on the L1 host, or virtio for native-context virtio-gpu)\n"
               "       and rerun\n", label);
        return 1;
    }
    if (capset_ok && cr == 0) {
        printf("[%s] RESULT: PASS (%d hardware device(s) visible)\n", label, hw_devices);
        return 0;
    }
    printf("[%s] RESULT: FAIL [%s]\n", label, venus_ok);
    return 1;
}

static void usage(const char *argv0) {
    printf("usage: %s MODE\n", argv0);
    printf("  venus      VENUS | NO_VIRGL                       (in-process venus)\n");
    printf("  venus-rs   VENUS | NO_VIRGL | RENDER_SERVER       (venus in render-server)\n");
    printf("  loftd      USE_EGL | VENUS | THREAD_SYNC | ASYNC_FENCE_CB  (0x143, current loftd --gpu=virgl)\n");
    printf("  loftd-rs   loftd set + RENDER_SERVER              (0x143|512)\n");
    printf("  --flags=N  exact virglrenderer flag mask\n");
    printf("  Each mode first lists every Vulkan device this process can see;\n");
    printf("  the RESULT requires a HARDWARE device (llvmpipe/lavapipe => FAIL).\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }
    const char *mode = argv[1];

    // Accept both "--flags <N>" and "--flags=<N>".
    long flags = -1;
    if (strcmp(mode, "--flags") == 0 && argc >= 3) {
        flags = strtol(argv[2], NULL, 0);
    } else if (strncmp(mode, "--flags=", 8) == 0) {
        flags = strtol(mode + 8, NULL, 0);
    }
    if (flags >= 0) {
        char label[64];
        snprintf(label, sizeof(label), "flags-0x%lx", flags);
        return run_mode((int)flags, label);
    }
    if (strcmp(mode, "venus") == 0)
        return run_mode(VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL, "venus");
    if (strcmp(mode, "venus-rs") == 0)
        return run_mode(VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL |
                            VIRGL_RENDERER_RENDER_SERVER,
                        "venus-rs");
    if (strcmp(mode, "loftd") == 0)
        return run_mode(VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_VENUS |
                            VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB,
                        "loftd");
    if (strcmp(mode, "loftd-rs") == 0)
        return run_mode(VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_VENUS |
                            VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB |
                            VIRGL_RENDERER_RENDER_SERVER,
                        "loftd-rs");

    usage(argv[0]);
    return 2;
}
