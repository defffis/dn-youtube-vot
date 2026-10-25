#pragma once
#include <algorithm>
#include <cmath>
namespace dnvot {
struct SyncDecision { bool audible = false; bool seek = false; double target = 0; float rate = 0; };
inline SyncDecision sync(double video, double audio, double offset, float rate,
                         bool moving, bool blocked, bool ready, double duration) {
    SyncDecision d;
    if (!std::isfinite(video) || !std::isfinite(audio) || !std::isfinite(offset) ||
        !std::isfinite(rate) || rate <= 0 || blocked || !ready) return d;
    d.target = std::max(0.0, video + offset);
    if (video + offset < 0 || (std::isfinite(duration) && duration > 0 && d.target >= duration - 0.05)) return d;
    double drift = d.target - audio;
    d.seek = std::fabs(drift) > 0.35;
    d.audible = moving;
    if (moving) {
        double adjustment = std::fabs(drift) > 0.07 ? std::clamp(drift * 0.10, -0.03, 0.03) : 0;
        d.rate = std::clamp(rate * float(1.0 + adjustment), 0.25f, 4.0f);
    }
    return d;
}
}
