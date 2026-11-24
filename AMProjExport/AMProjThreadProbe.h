// 猫鹤 AM · Beta 按需主线程采样；仅返回代码位置，不返回栈内数据。
#ifndef AMPROJ_THREAD_PROBE_H
#define AMPROJ_THREAD_PROBE_H
#include <stdbool.h>
#include <stdint.h>

#define AMPROJ_PROBE_FRAMES 20
typedef struct AMProjThreadProbe AMProjThreadProbe;
typedef struct {
    char image[96];
    char uuid[37];
    char symbol[160];
    uint64_t image_offset;
    uint64_t symbol_offset;
    bool resolved;
} AMProjProbeFrame;
typedef struct {
    int status;
    int resume_status;
    int frame_count;
    double pause_ms;
    double elapsed_ms;
    AMProjProbeFrame frames[AMPROJ_PROBE_FRAMES];
} AMProjProbeSample;
typedef struct {
    bool main_valid;
    bool process_valid;
    double main_seconds;
    double process_seconds;
    int main_run_state;
} AMProjProbeStats;

// 仅从主线程创建；持有的 Mach 端口由 Destroy 释放。失败返回 NULL。
AMProjThreadProbe *AMProjThreadProbeCreate(void);
void AMProjThreadProbeDestroy(AMProjThreadProbe *probe);
// 仅在同一个后台串行队列调用。主线程调用失败，不修改线程状态。
void AMProjThreadProbeCapture(AMProjThreadProbe *probe, AMProjProbeSample *sample);
void AMProjThreadProbeStats(AMProjThreadProbe *probe, AMProjProbeStats *stats);
#endif
