// 猫鹤 AM · Beta 主线程采样，暂停区只使用有界 C 操作和 Mach 系统调用。
#include "AMProjThreadProbe.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#elif defined(__x86_64__)
#include <mach/i386/thread_status.h>
#endif

struct AMProjThreadProbe {
    thread_t main_thread;
    uintptr_t stack_low;
    uintptr_t stack_high;
    double tick_ns;
    kern_return_t (*suspend_thread)(thread_t);
    kern_return_t (*resume_thread)(thread_t);
    kern_return_t (*get_state)(thread_t, thread_state_flavor_t, thread_state_t, mach_msg_type_number_t *);
    kern_return_t (*read_memory)(vm_map_read_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
};

static uintptr_t AMProbeCodePointer(uintptr_t value) {
#if defined(__arm64__)
    // 普通 arm64 slice 也可能读到系统 arm64e 栈。XPACLRI 在不支持 PAC 的硬件上为 HINT。
    register uintptr_t link __asm__("x30") = value;
    __asm__ volatile("hint #7" : "+r"(link));
    return link;
#else
    return value;
#endif
}
AMProjThreadProbe *AMProjThreadProbeCreate(void) {
    if (!pthread_main_np()) return NULL;
    AMProjThreadProbe *probe = calloc(1, sizeof(*probe));
    if (!probe) return NULL;
    probe->main_thread = mach_thread_self();
    probe->stack_high = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t size = pthread_get_stacksize_np(pthread_self());
    probe->stack_low = probe->stack_high >= size ? probe->stack_high - size : 0;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    probe->tick_ns = (double)timebase.numer / timebase.denom;
    // 提前绑定暂停区会用到的入口，避免首次调用的 dyld 绑定等待被暂停线程持有的锁。
    probe->suspend_thread = dlsym(RTLD_DEFAULT, "thread_suspend");
    probe->resume_thread = dlsym(RTLD_DEFAULT, "thread_resume");
    probe->get_state = dlsym(RTLD_DEFAULT, "thread_get_state");
    probe->read_memory = dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite");
    if (!probe->suspend_thread || !probe->resume_thread || !probe->get_state || !probe->read_memory) {
        AMProjThreadProbeDestroy(probe); return NULL;
    }
    return probe;
}
void AMProjThreadProbeDestroy(AMProjThreadProbe *probe) {
    if (!probe) return;
    mach_port_deallocate(mach_task_self(), probe->main_thread);
    free(probe);
}

static bool AMProbeRead(uintptr_t address, void *output, size_t size) {
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)output, &copied) == KERN_SUCCESS && copied == size;
}
static void AMProbeReadString(const char *source, char *output, size_t capacity) {
    if (!source || !capacity) return;
    for (size_t i = 0; i + 1 < capacity;) {
        // 地址来自 dyld，模块也可能并发卸载；不直接解引用这些指针。
        size_t chunk = capacity - 1 - i;
        size_t page = 4096 - (((uintptr_t)source + i) & 4095);
        if (chunk > 64) chunk = 64;
        if (chunk > page) chunk = page;
        if (!AMProbeRead((uintptr_t)source + i, output + i, chunk)) break;
        if (memchr(output + i, 0, chunk)) return;
        i += chunk;
    }
    output[capacity - 1] = 0;
}

#if AMPROJ_PROBE_TESTING
static unsigned AMProbeTestStateCalls;
static kern_return_t AMProbeFailState(thread_t thread, thread_state_flavor_t flavor,
                                     thread_state_t state, mach_msg_type_number_t *count) {
    if (++AMProbeTestStateCalls == 1) return thread_get_state(thread, flavor, state, count);
    return KERN_FAILURE;
}
void AMProjThreadProbeTestFailState(AMProjThreadProbe *probe) {
    AMProbeTestStateCalls = 0; probe->get_state = AMProbeFailState;
}
uintptr_t AMProjThreadProbeTestStripCode(uintptr_t address) { return AMProbeCodePointer(address); }
#endif
static void AMProbeResolve(uintptr_t address, AMProjProbeFrame *frame) {
    Dl_info info;
    // 调用者已经恢复主线程，dyld、字符串和格式化操作不得进入暂停区。
    if (!dladdr((void *)address, &info) || !info.dli_fbase) return;
    char path[1024] = {0};
    AMProbeReadString(info.dli_fname, path, sizeof(path));
    const char *name = strrchr(path, '/');
    snprintf(frame->image, sizeof(frame->image), "%s", name ? name + 1 : "unknown");
    frame->image_offset = address - (uintptr_t)info.dli_fbase;
    if (info.dli_sname && info.dli_saddr && address >= (uintptr_t)info.dli_saddr) {
        AMProbeReadString(info.dli_sname, frame->symbol, sizeof(frame->symbol));
        frame->symbol_offset = address - (uintptr_t)info.dli_saddr;
    }
    struct mach_header_64 header;
    if (!AMProbeRead((uintptr_t)info.dli_fbase, &header, sizeof(header)) ||
        header.magic != MH_MAGIC_64 || header.sizeofcmds > 16 * 1024 * 1024) return;
    uintptr_t cursor = (uintptr_t)info.dli_fbase + sizeof(header);
    uintptr_t end = cursor + header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds && i < 4096 && end - cursor >= sizeof(struct load_command); i++) {
        struct load_command command;
        if (!AMProbeRead(cursor, &command, sizeof(command)) || command.cmdsize < sizeof(command) || command.cmdsize > end - cursor) break;
        if (command.cmd == LC_UUID && command.cmdsize >= sizeof(struct uuid_command)) {
            struct uuid_command uuid;
            if (!AMProbeRead(cursor, &uuid, sizeof(uuid))) break;
            const uint8_t *u = uuid.uuid;
            snprintf(frame->uuid, sizeof(frame->uuid),
                "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]);
            break;
        }
        cursor += command.cmdsize;
    }
    frame->resolved = true;
}

void AMProjThreadProbeCapture(AMProjThreadProbe *probe, AMProjProbeSample *sample) {
    memset(sample, 0, sizeof(*sample));
    sample->status = KERN_INVALID_ARGUMENT;
    if (!probe || pthread_main_np()) return;
    uintptr_t addresses[AMPROJ_PROBE_FRAMES] = {0};
    uintptr_t pc = 0, lr = 0, fp = 0, sp = 0;
    int used = 0;
    uint64_t started = mach_absolute_time();
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
#else
    sample->status = KERN_NOT_SUPPORTED;
    return;
#endif
    // 在实际采样线程预热 MIG 消息、reply-port 和内存读取路径；失败不暂停主线程。
#if defined(__arm64__)
    sample->status = probe->get_state(probe->main_thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    count = ARM_THREAD_STATE64_COUNT;
#elif defined(__x86_64__)
    sample->status = probe->get_state(probe->main_thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    count = x86_THREAD_STATE64_COUNT;
#endif
    if (sample->status != KERN_SUCCESS) return;
    uintptr_t warmSource = 0, warmTarget = 0;
    mach_vm_size_t warmCopied = 0;
    sample->status = probe->read_memory(mach_task_self(), (mach_vm_address_t)&warmSource,
        sizeof(warmSource), (mach_vm_address_t)&warmTarget, &warmCopied);
    if (sample->status != KERN_SUCCESS || warmCopied != sizeof(warmSource)) return;
    if ((mach_absolute_time() - started) * probe->tick_ns > 50000000) {
        sample->status = KERN_ABORTED; return;
    }
    uint64_t pauseStarted = mach_absolute_time();
    sample->status = probe->suspend_thread(probe->main_thread);
    if (sample->status != KERN_SUCCESS) return;
    // 暂停区：无分配、ObjC、日志、dyld、锁或符号解析；所有路径汇合到 resume。
#if defined(__arm64__)
    sample->status = probe->get_state(probe->main_thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (sample->status == KERN_SUCCESS) {
        pc = arm_thread_state64_get_pc(state); lr = arm_thread_state64_get_lr(state);
        fp = arm_thread_state64_get_fp(state); sp = arm_thread_state64_get_sp(state);
    }
#elif defined(__x86_64__)
    sample->status = probe->get_state(probe->main_thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    if (sample->status == KERN_SUCCESS) { pc = state.__rip; fp = state.__rbp; sp = state.__rsp; }
#endif
    if (pc) addresses[used++] = AMProbeCodePointer(pc);
    if (lr && used < AMPROJ_PROBE_FRAMES) addresses[used++] = AMProbeCodePointer(lr);
    while (used < AMPROJ_PROBE_FRAMES && fp >= sp && fp >= probe->stack_low &&
           fp <= probe->stack_high - 2 * sizeof(uintptr_t) && !(fp & (sizeof(uintptr_t) - 1))) {
        if ((mach_absolute_time() - pauseStarted) * probe->tick_ns > 1000000) break;
        uintptr_t record[2];
        mach_vm_size_t copied = 0;
        if (probe->read_memory(mach_task_self(), fp, sizeof(record), (mach_vm_address_t)record, &copied) != KERN_SUCCESS ||
            copied != sizeof(record)) break;
        uintptr_t caller = AMProbeCodePointer(record[1]);
        if (caller && (!used || caller != addresses[used - 1])) addresses[used++] = caller;
        if (record[0] <= fp) break;
        fp = record[0];
    }
    sample->resume_status = probe->resume_thread(probe->main_thread);
    sample->pause_ms = (mach_absolute_time() - pauseStarted) * probe->tick_ns / 1000000;
    if (sample->resume_status != KERN_SUCCESS) {
        sample->elapsed_ms = (mach_absolute_time() - started) * probe->tick_ns / 1000000;
        return;
    }
    // 主线程恢复后才解析代码位置；不保存寄存器和原始栈内容。
    sample->frame_count = used;
    for (int i = 0; i < used; i++) AMProbeResolve(addresses[i], &sample->frames[i]);
    sample->elapsed_ms = (mach_absolute_time() - started) * probe->tick_ns / 1000000;
}

void AMProjThreadProbeStats(AMProjThreadProbe *probe, AMProjProbeStats *stats) {
    memset(stats, 0, sizeof(*stats));
    if (!probe) return;
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(probe->main_thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS) {
        stats->main_valid = true;
        stats->main_seconds = info.user_time.seconds + info.system_time.seconds +
            (info.user_time.microseconds + info.system_time.microseconds) / 1000000.0;
        stats->main_run_state = info.run_state;
    }
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        stats->process_valid = true;
        stats->process_seconds = usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
            (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0;
    }
}
