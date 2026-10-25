#pragma once
#include <cmath>
#include <limits>
#include <string>
namespace dnvot {
// Automatic requests must wait for actual, continuous video playback.
// A nonempty ID and duration can already exist while YouTube is initializing.
struct AutoStartGate {
    std::string video;
    double lastMedia=std::numeric_limits<double>::quiet_NaN();
    double lastProgress=-std::numeric_limits<double>::infinity();
    double movingSince=std::numeric_limits<double>::quiet_NaN();
    unsigned advances=0;
    void reset() { *this=AutoStartGate{}; }
    bool observe(const std::string &id,double media,double now) {
        if (video!=id) { reset();video=id; }
        if (id.empty() || !std::isfinite(media) || !std::isfinite(now)) { lastMedia=media;advances=0;movingSince=NAN;return false; }
        double delta=media-lastMedia;lastMedia=media;
        bool advanced=std::isfinite(delta) && delta>0.002 && delta<1.5;
        if (!advanced) {
            if (delta< -0.05 || delta>=1.5 || now-lastProgress>=0.45) { advances=0;movingSince=NAN; }
            return false;
        }
        if (!std::isfinite(movingSince) || now-lastProgress>=0.45) { movingSince=now;advances=0; }
        lastProgress=now;if (advances<100) advances++;
        return advances>=2 && now-movingSince>=1.0;
    }
};
}
