#pragma once
#include <algorithm>
#include <cmath>
namespace dnvot {
struct ControlSize { double width,height; };
inline ControlSize nativeControlSize(double width,double height) {
    if (!std::isfinite(width) || !std::isfinite(height) || width<20 || width>64 || height<20 || height>64)
        return {32,32};
    return {width,height};
}
inline double glyphOffset(double referenceCenter,double ownCenter) {
    if (!std::isfinite(referenceCenter) || !std::isfinite(ownCenter)) return 0;
    double offset=referenceCenter-ownCenter;
    return std::fabs(offset)<=8.0 ? offset : 0; // ignore geometry from an unfinished native layout
}
}
