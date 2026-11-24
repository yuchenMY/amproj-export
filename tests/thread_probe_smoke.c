#include "../AMProjExport/AMProjThreadProbe.h"
#include <assert.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern void AMProjThreadProbeTestFailState(AMProjThreadProbe *probe);
static atomic_bool done = false;
static atomic_uint ticks = 0;

static void *capture(void *context) {
    AMProjThreadProbe *probe = context;
    assert(AMProjThreadProbeCreate() == NULL);
    AMProjProbeStats before, after;
    AMProjThreadProbeStats(probe, &before);
    assert(before.main_valid && before.process_valid);
    usleep(30000);
    for (int i = 0; i < 20; i++) {
        AMProjProbeSample sample;
        AMProjThreadProbeCapture(probe, &sample);
        assert(sample.status == KERN_SUCCESS && sample.resume_status == KERN_SUCCESS);
        assert(sample.frame_count > 0 && sample.frame_count <= AMPROJ_PROBE_FRAMES);
        assert(sample.frames[0].resolved && sample.frames[0].image[0]);
        assert(strlen(sample.frames[0].uuid) == 36);
        assert(sample.pause_ms >= 0 && sample.elapsed_ms >= sample.pause_ms);
        printf("sample %d: frames=%d pause_ms=%.3f total_ms=%.3f\n", i, sample.frame_count, sample.pause_ms, sample.elapsed_ms);
        usleep(1000);
    }
    AMProjThreadProbeStats(probe, &after);
    assert(after.main_seconds > before.main_seconds && after.process_seconds >= before.process_seconds);
    AMProjThreadProbeTestFailState(probe);
    AMProjProbeSample failure;
    AMProjThreadProbeCapture(probe, &failure);
    assert(failure.status == KERN_FAILURE && failure.resume_status == KERN_SUCCESS && failure.frame_count == 0);
    // 失败后主线程仍须运行，验证 suspend/get_state 失败分支确实恢复了线程。
    unsigned previous = atomic_load(&ticks);
    usleep(10000);
    assert(atomic_load(&ticks) != previous);
    atomic_store(&done, true);
    return NULL;
}

int main(void) {
    AMProjThreadProbe *probe = AMProjThreadProbeCreate();
    assert(probe);
    AMProjProbeSample rejected;
    AMProjThreadProbeCapture(probe, &rejected);
    assert(rejected.status == KERN_INVALID_ARGUMENT && rejected.frame_count == 0);
    pthread_t worker;
    assert(pthread_create(&worker, NULL, capture, probe) == 0);
    while (!atomic_load(&done)) atomic_fetch_add(&ticks, 1);
    assert(pthread_join(worker, NULL) == 0);
    AMProjThreadProbeDestroy(probe);
    puts("THREAD_PROBE_SMOKE_PASS");
    return 0;
}
