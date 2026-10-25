#pragma once
#include <cmath>
namespace dnvot {
constexpr double cacheTTL=24*60*60;
inline bool cacheExpired(double now,double created,double modified) {
    double saved=std::isfinite(created) && created>0 ? created : modified;
    if (!std::isfinite(now)) return false;
    if (!std::isfinite(saved) || saved<=0) return true;
    // Do not destroy valid data solely because the wall clock moved backwards.
    return now>=saved && now-saved>=cacheTTL;
}
inline bool cacheMayDelete(double now,double created,double modified,bool active) {
    return !active && cacheExpired(now,created,modified);
}
}
