#include <metal_stdlib>

using namespace metal;

kernel void neantik_metal_smoke(
    device float *values [[buffer(0)]],
    uint index [[thread_position_in_grid]]) {
  values[index] += 1.0;
}
