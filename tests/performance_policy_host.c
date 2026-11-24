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
    return 0;
}
