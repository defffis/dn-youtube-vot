#pragma once
#include <initializer_list>
#include <string_view>

namespace dnvot {
// Feed previews and short-form controllers must not replace the watch player.
inline bool excludedPlaybackClass(std::string_view name) {
    for (auto prefix : {std::string_view("YTInlineMutedPlayback"),
                        std::string_view("YTShorts"), std::string_view("YTReel")}) {
        if (name.substr(0, prefix.size()) == prefix) return true;
    }
    return false;
}

// A hidden optional neighbour is not the visibility of the whole controls row.
struct TopControlsVisibility {
    bool known = false;
    bool shown = false;
    bool overlayShown = true;
    void update(bool visible, bool cancelled) {
        known = true;
        shown = visible && !cancelled;
    }
    void updateOverlay(bool visible) { overlayShown = visible; }
    bool visible(bool fallback) const { return overlayShown && (known ? shown : fallback); }
};
}
