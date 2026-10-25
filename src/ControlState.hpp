#pragma once
#include <cmath>
#include <cstdint>
namespace dnvot {
enum class ControlPhase { idle, waiting, active };
struct ControlState { ControlPhase phase; uint64_t elapsed; };
inline ControlState controlState(bool enabled, bool audioReady, double started, double now) {
    if (!enabled) return {ControlPhase::idle,0};
    if (audioReady) return {ControlPhase::active,0};
    double elapsed=now-started;
    return {ControlPhase::waiting, std::isfinite(elapsed) && elapsed>0 ? static_cast<uint64_t>(std::fmin(elapsed,86400.0)) : 0};
}
}
