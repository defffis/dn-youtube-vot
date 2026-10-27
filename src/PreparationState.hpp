#pragma once
#include "VOTWire.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace dnvot {
// Optional int32 field 5. Absence, zero and signed negative sentinels are not ETA.
inline double serviceRemainingSeconds(const Fields &fields) {
    auto it=fields.find(5);
    if (it==fields.end() || it->second.wire!=0) return -1;
    uint64_t raw=it->second.integer;
    return raw>0 && raw<=86400 ? static_cast<double>(raw) : -1;
}
enum class PreparationPhase { none, service, download };
struct PreparationState {
    PreparationPhase phase;
    double fraction; // -1 = indeterminate; never infer percent from an ETA
};
inline PreparationState preparationState(bool enabled,bool ready,bool downloading,
                                          int64_t written,int64_t expected) {
    if (!enabled || ready) return {PreparationPhase::none,-1};
    if (!downloading) return {PreparationPhase::service,-1};
    if (written<0 || expected<=0) return {PreparationPhase::download,-1};
    // Reserve completion for successful validation and audio preparation.
    return {PreparationPhase::download,std::clamp(double(written)/double(expected),0.0,0.99)};
}
}
