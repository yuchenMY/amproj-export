// 猫鹤 AM · 可在宿主机验证的诊断边界。
#ifndef AMPROJ_PERFORMANCE_POLICY_H
#define AMPROJ_PERFORMANCE_POLICY_H
#include <stdbool.h>
#include <stdint.h>

#define AMPROJ_PERF_MAX_SECONDS 60.0
#define AMPROJ_PERF_MAX_EVENTS 1024
#define AMPROJ_PERF_MAX_BYTES (512u * 1024u)
#define AMPROJ_PERF_STALL_SECONDS 0.250

static inline bool AMProjPerfExpired(double started, double now) {
    return now >= started && now - started >= AMPROJ_PERF_MAX_SECONDS;
}
static inline bool AMProjPerfIsStall(double requested, double now) {
    return requested > 0 && now >= requested &&
        now - requested >= AMPROJ_PERF_STALL_SECONDS;
}
static inline double AMProjPerfElapsed(double started, double now) {
    if (now < started) return 0;
    double elapsed = now - started;
    return elapsed > AMPROJ_PERF_MAX_SECONDS ? AMPROJ_PERF_MAX_SECONDS : elapsed;
}
#endif
