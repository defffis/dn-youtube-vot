#include "../src/VOTWire.hpp"
#include "../src/SyncPolicy.hpp"
#include "../src/ControlState.hpp"
#include "../src/PlaybackClock.hpp"
#include "../src/LocalTransport.hpp"
#include "../src/FeaturePolicy.hpp"
#include "../src/CachePolicy.hpp"
#include "../src/AutoStartGate.hpp"
#include "../src/PlayerPolicy.hpp"
#include <cassert>
#include <iostream>
#include <limits>
#include <iomanip>

static void reject(const dnvot::Bytes &b) {
    bool rejected = false;
    try { dnvot::parse(b.data(), b.size()); } catch (const std::runtime_error &) { rejected = true; }
    assert(rejected);
}
int main(int argc, char **argv) {
    using namespace dnvot;
    assert(excludedPlaybackClass("YTInlineMutedPlaybackWatchViewController"));
    assert(excludedPlaybackClass("YTInlineMutedPlaybackPlayerOverlayViewController"));
    assert(excludedPlaybackClass("YTShortsPlayerViewController"));
    assert(excludedPlaybackClass("YTReelWatchPlaybackOverlayView"));
    assert(!excludedPlaybackClass("YTPlayerViewController"));
    assert(!excludedPlaybackClass("YTMainAppVideoPlayerOverlayViewController"));
    assert(!excludedPlaybackClass("YTWatchMiniBarViewController"));
    assert(!excludedPlaybackClass(""));
    TopControlsVisibility visibility;
    assert(!visibility.visible(false) && visibility.visible(true));
    visibility.update(true,false);
    assert(visibility.visible(false)); // optional overflow is hidden, row is shown
    visibility.update(false,false);
    assert(!visibility.visible(true)); // row hidden while a neighbour is still fading
    visibility.update(true,true);
    assert(!visibility.visible(true)); // autonav cancellation hides controls
    visibility.update(true,false);
    assert(visibility.visible(true));
    visibility.updateOverlay(false);
    assert(!visibility.visible(true)); // hiding the whole overlay always wins
    visibility.updateOverlay(true);
    assert(visibility.visible(false));
    visibility.update(true,true);
    visibility.updateOverlay(true);
    assert(!visibility.visible(true)); // generic show cannot undo cancelled top row
    AutoStartGate gate;
    assert(!gate.observe("A",0,0));
    assert(!gate.observe("A",0.2,0.2));
    assert(!gate.observe("A",0.4,0.4));
    assert(!gate.observe("A",0.47,0.6));
    // Report regression: native video freezes at its first frame, metadata is ready.
    for (int i=4;i<=50;i++) assert(!gate.observe("A",0.47,i*0.2));
    assert(!gate.observe("A",0.67,10.2));
    for (int i=1;i<5;i++) assert(!gate.observe("A",0.67+i*0.2,10.2+i*0.2));
    assert(gate.observe("A",1.87,11.4));
    assert(!gate.observe("B",50,11.6)); // switching / cached translation does not bypass motion
    assert(!gate.observe("B",50,12.8));
    assert(!gate.observe("B",50.2,13));
    for (int i=1;i<6;i++) gate.observe("B",50.2+i*0.2,13+i*0.2);
    assert(gate.observe("B",51.4,14.2));
    assert(!gate.observe("B",100,14.4)); // seek resets continuous motion
    assert(!gate.observe("B",100.2,14.6));
    assert(!gate.observe("B",NAN,15));
    assert(!gate.observe("",0,16));
    const double saved=1700000000;
    assert(!cacheExpired(saved+86399.999,saved,saved));
    assert(cacheExpired(saved+86400,saved,saved));
    assert(cacheExpired(saved+90000,saved,saved+89999)); // a cache hit does not extend TTL
    assert(!cacheExpired(saved+100,saved,saved-90000)); // creation time, not LRU access time
    assert(cacheExpired(saved+90000,NAN,saved)); // old file fallback
    assert(!cacheExpired(saved-100,saved,saved)); // wall clock rollback
    assert(!cacheExpired(NAN,saved,saved));
    assert(cacheExpired(saved,0,0)); // missing timestamps cannot keep a file forever
    assert(!cacheMayDelete(saved+90000,saved,saved,true)); // protect active playback
    assert(cacheMayDelete(saved+90000,saved,saved,false)); // delete once released
    assert(!cacheMayDelete(saved+10,saved,saved,false));
    assert(sameVideo("", "")); // nil/nil must not create a stop every 200 ms
    assert(!sameVideo("", "testVideo01"));
    assert(languageCode("EN-us")=="en" && languageCode("ru.4")=="ru");
    assert(languageCode("pt_BR")=="pt" && languageCode("zh-Hant-TW")=="zh");
    assert(languageCode("und").empty() && languageCode("auto").empty());
    assert(languageCode("a.en").empty() && languageCode("12").empty() && languageCode("").empty());
    assert(autoAction(false,true,false,true,10)==AutoAction::wait);
    assert(autoAction(true,true,true,true,0)==AutoAction::excluded);
    assert(autoAction(true,true,false,true,0)==AutoAction::start);
    assert(autoAction(true,false,false,true,4.99)==AutoAction::wait);
    assert(autoAction(true,false,false,true,5)==AutoAction::unknown);
    assert(autoAction(true,false,false,false,0)==AutoAction::start);
    std::string media="https://vtrans.s3-private.mds.yandex.net/tts/prod/a%2Fb.mp3?sig=XYZ%2B1";
    assert(translatedAudioRoute(media,0,"https://example.com")==media);
    assert(translatedAudioRoute(media,1,"https://example.com")==media);
    assert(translatedAudioRoute(media,2,"")==media);
    assert(translatedAudioRoute(media,2,"https://example.com/base")=="https://example.com/base/video-translation/audio-proxy/a%2Fb.mp3?sig=XYZ%2B1");
    std::string spoof="https://vtrans.s3-private.mds.yandex.net.evil/tts/prod/a";
    assert(translatedAudioRoute(spoof,2,"https://example.com")==spoof);

    if (argc > 2) {
        Bytes b;
        std::string op = argv[1];
        if (op == "session") b = session(argv[2]);
        else if (op == "translation") b = translation(std::string("https://youtu.be/") + argv[2], argc > 3 ? std::stod(argv[3]) : 19, "en", "ru", argc > 4 ? std::string(argv[4]) != "0" : true, false);
        else if (op == "lively") b = translation(std::string("https://youtu.be/") + argv[2],19,"en","ru",true,false,"",true);
        else if (op == "custom") b = translation(argv[2], argc > 3 ? std::stod(argv[3]) : 310, "en", "ru", argc > 5 ? std::string(argv[5]) != "0" : true, false, argc > 4 ? argv[4] : "");
        else return 2;
        for (uint8_t c : b) std::cout << std::hex << std::setw(2) << std::setfill('0') << (int)c;
        std::cout << '\n'; return 0;
    }
    auto b = session("ABC");
    auto f = parse(b.data(), b.size());
    assert(text(f, 1) == "ABC" && text(f, 2) == "video-translation");
    auto t = translation("https://youtu.be/jNQXAC9IVRw", 19, "en", "ru", true, false, "https://example.com/audio");
    f = parse(t.data(), t.size());
    assert(text(f, 3) == "https://youtu.be/jNQXAC9IVRw");
    assert(value(f, 5) == 1 && value(f, 7) == 1 && value(f, 9) == 0 && value(f, 16) == 2);
    assert(text(f, 14) == "ru" && f.at(6).wire == 1);
    auto help = text(f, 11); auto hf = parse(reinterpret_cast<const uint8_t *>(help.data()), help.size());
    assert(text(hf, 1) == "video_file_url" && text(hf, 2) == "https://example.com/audio");
    t = translation("url", 19, "de", "ru", false, true);
    f = parse(t.data(), t.size()); assert(value(f, 5) == 0 && value(f, 9) == 1);
    t = translation("url",19,"en","ru",true,false,"",true);
    f = parse(t.data(),t.size()); assert(value(f,18)==1);
    auto state=controlState(false,false,false,100,105);assert(state.phase==ControlPhase::idle && state.elapsed==0);
    state=controlState(true,false,false,100,165.9);assert(state.phase==ControlPhase::waiting && state.elapsed==65);
    state=controlState(true,true,true,100,200);assert(state.phase==ControlPhase::active);
    state=controlState(false,true,true,100,200);assert(state.phase==ControlPhase::idle); // disable even with a ready item
    state=controlState(true,false,false,100,99);assert(state.elapsed==0); // clock rollback
    state=controlState(true,false,false,NAN,200);assert(state.elapsed==0);
    state=controlState(true,false,false,0,1e100);assert(state.elapsed==86400); // bounded conversion
    state=controlState(true,true,false,100,200);assert(state.phase==ControlPhase::armed); // a ready paused item must not look playing
    PlaybackClock clock;
    assert(!clock.observe(288.8,10));
    assert(clock.observe(289.0,10.2));
    // Regression: actual progress is sufficient even if private attemptingToPlay is false.
    assert(clock.observe(289.191,10.4));
    assert(clock.observe(289.191,10.56)); // matches the reported 0.161s advance age
    assert(!clock.observe(289.191,11.0)); // stalled/paused source stops translation
    clock.pause(11.1);assert(!clock.observe(289.2,11.2));
    assert(!clock.observe(289.3,11.4));
    assert(!clock.observe(289.3,11.75)); // no recovery based only on old advance samples
    assert(clock.observe(289.5,11.9)); // fresh progress recovers a stale internal pause
    clock.pause(12);clock.resume();assert(clock.observe(289.7,12.2));
    assert(!clock.observe(100,12.4)); // backward seek resets motion evidence
    assert(clock.observe(100.2,12.6));
    assert(!clock.observe(500,12.8)); // forward seek is not a playback sample
    assert(clock.observe(500.2,13));
    assert(!clock.observe(NAN,13.2));
    clock.reset();assert(!clock.observe(0,14));assert(clock.observe(0.05,14.2)); // 0.25x
    auto observed=sync(0.05,0.05,0,0.25f,true,false,true,100);assert(observed.audible);
    observed=sync(289.191,289.028,0,1,true,false,true,1441);assert(observed.audible && !observed.seek && observed.rate>0);
    observed=sync(289.191,289.028,0,1,true,true,true,1441);assert(!observed.audible);
    observed=sync(289.191,289.028,0,1,true,false,true,289);assert(!observed.audible); // report coverage separately
    // Local file playback doesn't restart for drift-rate updates. A remote seek
    // completion used to recursively request play/seek while video kept moving.
    double localTime=0,lastAttempt=-INFINITY;float localRate=1;bool playing=false;
    unsigned starts=0,seeks=0;
    for (unsigned i=0;i<400;i++) {
        double now=i*0.2;
        double video=324.657+now+(i>=200 ? 60 : 0);
        auto step=localTransport(video,localTime,0,1,true,false,1441.272,playing,now,lastAttempt);
        assert(step.supported && step.sync.audible);
        if (step.sync.seek) { localTime=step.sync.target;++seeks; }
        localRate=step.sync.rate;
        if (step.play) { playing=true;lastAttempt=now;++starts; }
        localTime+=0.2*localRate;
    }
    assert(starts==1 && seeks==2); // initial alignment and one explicit video seek
    auto local=localTransport(324.657,324.573,0,1,true,false,1441.272,true,10,9);
    assert(!local.play && !local.sync.seek); // user report: don't restart an advancing player
    local=localTransport(10,10,0,1,true,false,100,false,10,9.8);assert(!local.play);
    local=localTransport(10,10,0,1,true,false,100,false,11,9.8);assert(local.play); // failed starts are bounded
    local=localTransport(10,9.8,0,2,true,false,100,true,10,9);assert(local.sync.rate==2);
    local=localTransport(10,10.2,0,0.5f,true,false,100,true,10,9);assert(local.sync.rate==0.5f);
    local=localTransport(10,10,0,3,true,false,100,false,10,9);assert(!local.supported && !local.play && !local.sync.audible);
    local=localTransport(10,10,0,1,false,false,100,true,10,9);assert(!local.sync.audible && !local.play);
    local=localTransport(10,10,0,1,true,true,100,true,10,9);assert(!local.sync.audible && !local.play);
    local=localTransport(110,10,0,1,true,false,100,false,10,9);assert(!local.sync.audible && !local.sync.seek && !local.play);
    Bytes audioBytes = {1, 2, 3, 0, 255};
    auto a = audio("tid", "url", "fid", audioBytes.data(), audioBytes.size());
    f = parse(a.data(), a.size()); assert(f.count(6) == 1 && f.count(4) == 0);
    std::string info = text(f, 6); auto af = parse(reinterpret_cast<const uint8_t *>(info.data()), info.size());
    assert(text(af, 1) == "fid" && text(af, 2).size() == audioBytes.size());
    assert((unsigned char)text(af, 2)[4] == 255);
    for (Bytes invalid : {Bytes{0}, Bytes{0x80}, Bytes{0x0a, 8, 1}, Bytes{0x09, 1, 2}, Bytes{0x0b}, Bytes{0x0d, 1}}) reject(invalid);
    Bytes overflow(11, 0xff); reject(overflow);
    Bytes largest; integer(largest, 10, UINT64_MAX); f = parse(largest.data(), largest.size()); assert(value(f, 10) == UINT64_MAX);
    auto d = sync(10, 10, 0, 1, true, false, true, 100); assert(d.audible && !d.seek && d.rate == 1);
    d = sync(10, 10, 0, 1, false, false, true, 100); assert(!d.audible && !d.seek && d.rate == 0);
    d = sync(50, 10, 0, 2, true, false, true, 100); assert(d.audible && d.seek && d.target == 50);
    d = sync(10, 10, 0, 1, true, true, true, 100); assert(!d.audible && !d.seek);
    d = sync(10, 10, 0, 1, true, false, false, 100); assert(!d.audible);
    d = sync(40, 10, 0, 1, true, false, true, 30); assert(!d.audible && !d.seek);
    d = sync(1, 0, -2, 1, true, false, true, 100); assert(!d.audible);
    d = sync(10, 10, 0.2, 1, true, false, true, 100); assert(d.audible && !d.seek && d.rate > 1 && d.rate <= 1.03);
    d = sync(10, 10.2, 0, 1, true, false, true, 100); assert(d.rate < 1 && d.rate >= 0.97);
    d = sync(NAN, 10, 0, 1, true, false, true, 100); assert(!d.audible);
    d = sync(10, NAN, 0, 1, true, false, true, 100); assert(!d.audible);
    d = sync(10, 10, 0, INFINITY, true, false, true, 100); assert(!d.audible);
    d = sync(10, 10, 0, 0, true, false, true, 100); assert(!d.audible);
    std::cout << "PASS: preview/Shorts scope and top-controls visibility; sustained automatic-start gate / initial stalls / video switching / seeks, absolute cache TTL/boundary/cache hits/active-file protection, language normalization, auto exclusions/unknown timeout, proxy modes/prefix/query preservation, empty ID equality, protobuf bounds, session, translation/help/audio fields, binary payload, lively voice, control idle/wait/armed/playing/disable, measured clock and stale pause recovery, local transport 400-step playback/seek, bounded restart, 0.5x/2x boundaries, pause, seek, rate, ads, buffering, partial coverage, offset, invalid clocks\n";
}
