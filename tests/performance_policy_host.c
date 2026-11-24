#include "../AMProjExport/AMProjPerformancePolicy.h"
#include <assert.h>

int main(void) {
    assert(!AMProjPerfExpired(100, 159.999));
    assert(AMProjPerfExpired(100, 160));
    assert(AMProjPerfExpired(100, 10000));
    assert(!AMProjPerfExpired(100, 99));
    assert(!AMProjPerfIsStall(0, 1000));
    assert(!AMProjPerfIsStall(100, 100.249));
    assert(AMProjPerfIsStall(100, 100.25));
    assert(!AMProjPerfIsStall(100, 99));
    assert(AMProjPerfElapsed(100, 99) == 0);
    assert(AMProjPerfElapsed(100, 130) == 30);
    assert(AMProjPerfElapsed(100, 1000) == 60);
    assert(AMProjPerfCPUPercent(1, 1.5, 1) == 50);
    assert(AMProjPerfCPUPercent(1, 3, 1) == 200);
    assert(AMProjPerfCPUPercent(1, 0, 1) == -1);
    assert(AMProjPerfCPUPercent(-1, 0, 1) == -1);
    assert(AMProjPerfCPUPercent(1, 2, 0) == -1);
    assert(!AMProjPerfProbeDue(0, 100, 100.999, true));
    assert(AMProjPerfProbeDue(0, 100, 101, true));
    assert(!AMProjPerfProbeDue(0, 100, 104.999, false));
    assert(AMProjPerfProbeDue(0, 100, 105, false));
    assert(!AMProjPerfProbeDue(32, 100, 200, true));
    assert(!AMProjPerfProbeDue(0, 100, 99, true));
    return 0;
}
