#pragma once
#include <algorithm>
#include <string>
namespace dnvot {
inline std::string languageCode(std::string s) {
    auto end=s.find_first_of("-_.");if (end!=std::string::npos) s.resize(end);
    if (s.size()<2 || s.size()>3) return "";
    for (char &c:s) { if (c>='A' && c<='Z') c+=32;if (c<'a' || c>'z') return ""; }
    return s=="und" || s=="auto" ? "" : s;
}
enum class AutoAction { wait, start, excluded, unknown };
inline AutoAction autoAction(bool ready, bool known, bool excluded, bool hasExclusions, double age) {
    if (!ready) return AutoAction::wait;
    if (known && excluded) return AutoAction::excluded;
    if (!known && hasExclusions) return age<5 ? AutoAction::wait : AutoAction::unknown;
    return AutoAction::start;
}
inline std::string translatedAudioRoute(const std::string &url,int mode,const std::string &worker) {
    const std::string prefix="https://vtrans.s3-private.mds.yandex.net/tts/prod/";
    if (mode!=2 || worker.empty() || url.compare(0,prefix.size(),prefix)!=0) return url;
    return worker+"/video-translation/audio-proxy/"+url.substr(prefix.size());
}
inline bool sameVideo(const std::string &a,const std::string &b) { return a==b; }
}
