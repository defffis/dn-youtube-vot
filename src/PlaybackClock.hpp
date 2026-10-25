#pragma once
#include <cmath>
#include <limits>

namespace dnvot {
// Use measured content-clock progress. Private playback-intent flags can be false
// during actual playback and are intentionally not used as a transport veto.
struct PlaybackClock {
    double lastMedia = std::numeric_limits<double>::quiet_NaN();
    double lastAdvance = -std::numeric_limits<double>::infinity();
    double pausedAt = 0;
    unsigned advancingSamples = 0;
    bool paused = false;
    void reset() { *this = PlaybackClock{}; }
    void pause(double now) { paused=true;pausedAt=now;advancingSamples=0;lastAdvance=-std::numeric_limits<double>::infinity(); }
    void resume() { paused=false; }
    bool observe(double media, double now) {
        if (!std::isfinite(media) || !std::isfinite(now)) { advancingSamples=0;lastAdvance=-std::numeric_limits<double>::infinity();lastMedia=media;return false; }
        double delta=media-lastMedia;lastMedia=media;
        bool advanced=std::isfinite(delta) && delta>0.002 && delta<1.5;
        if (advanced) {
            if (advancingSamples<3) ++advancingSamples;
            lastAdvance=now;
        } else if (std::isfinite(delta) && (delta< -0.05 || delta>=1.5)) {
            advancingSamples=0;lastAdvance=-std::numeric_limits<double>::infinity();
        } else if (now-lastAdvance>=0.45) advancingSamples=0;
        // A stale internal pause callback must not hold a visibly advancing video forever.
        if (paused && advanced && advancingSamples>=2 && now-pausedAt>0.6) paused=false;
        return !paused && now>=lastAdvance && now-lastAdvance<0.45;
    }
};
}
