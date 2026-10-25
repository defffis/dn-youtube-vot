#include "../src/VOTWire.hpp"
#include "../src/SyncPolicy.hpp"
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
    if (argc > 2) {
        Bytes b;
        std::string op = argv[1];
        if (op == "session") b = session(argv[2]);
        else if (op == "translation") b = translation(std::string("https://youtu.be/") + argv[2], argc > 3 ? std::stod(argv[3]) : 19, "en", "ru", argc > 4 ? std::string(argv[4]) != "0" : true, false);
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
    std::cout << "PASS: protobuf bounds, session, translation/help/audio fields, binary payload, pause, seek, rate, ads, buffering, partial coverage, offset, invalid clocks\n";
}
