#pragma once
#include "SyncPolicy.hpp"
namespace dnvot {
struct LocalDecision { SyncDecision sync; bool supported=false; bool play=false; };
inline LocalDecision localTransport(double video, double audio, double offset, float rate,
                                    bool moving, bool blocked, double duration, bool playing,
                                    double now, double lastAttempt) {
    LocalDecision d;
    d.supported=std::isfinite(rate) && rate>=0.5f && rate<=2.0f;
    d.sync=sync(video,audio,offset,rate,moving,blocked || !d.supported,true,duration);
    // Fine drift correction stays within the decoder's supported speed range,
    // including at the boundary video rates 0.5x and 2x.
    if (d.sync.audible) d.sync.rate=std::clamp(d.sync.rate,0.5f,2.0f);
    d.play=d.sync.audible && !playing && std::isfinite(now) && now-lastAttempt>=1.0;
    return d;
}
}
