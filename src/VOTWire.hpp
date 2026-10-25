#pragma once
#include <cstdint>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace dnvot {
using Bytes = std::vector<uint8_t>;
inline void varint(Bytes &b, uint64_t n) {
    while (n > 127) { b.push_back(uint8_t(n) | 128); n >>= 7; }
    b.push_back(uint8_t(n));
}
inline void integer(Bytes &b, unsigned f, uint64_t n) { varint(b, uint64_t(f) << 3); varint(b, n); }
inline void blob(Bytes &b, unsigned f, const uint8_t *p, size_t n) {
    varint(b, (uint64_t(f) << 3) | 2); varint(b, n);
    if (n) b.insert(b.end(), p, p + n);
}
inline void string(Bytes &b, unsigned f, const std::string &s) {
    blob(b, f, reinterpret_cast<const uint8_t *>(s.data()), s.size());
}
inline void number(Bytes &b, unsigned f, double d) {
    varint(b, (uint64_t(f) << 3) | 1);
    uint64_t bits; std::memcpy(&bits, &d, 8);
    for (unsigned i = 0; i < 8; ++i) b.push_back(uint8_t(bits >> (8 * i)));
}
struct Field { unsigned wire = 0; uint64_t integer = 0; std::string text; };
using Fields = std::map<unsigned, Field>;
inline Fields parse(const uint8_t *p, size_t size) {
    if (size > 2 * 1024 * 1024) throw std::runtime_error("Protobuf response too large");
    size_t pos = 0;
    auto read = [&]() {
        uint64_t value = 0;
        for (unsigned i = 0; i < 10; ++i) {
            if (pos >= size) throw std::runtime_error("Truncated varint");
            uint8_t c = p[pos++];
            if (i == 9 && c > 1) throw std::runtime_error("Varint overflow");
            value |= uint64_t(c & 127) << (7 * i);
            if (!(c & 128)) return value;
        }
        throw std::runtime_error("Invalid varint");
    };
    Fields out;
    while (pos < size) {
        uint64_t tag = read();
        unsigned field = unsigned(tag >> 3), wire = unsigned(tag & 7);
        if (!field || tag >> 3 > 0x1fffffff) throw std::runtime_error("Invalid protobuf tag");
        Field value; value.wire = wire;
        if (wire == 0) value.integer = read();
        else if (wire == 1 || wire == 5) {
            size_t n = wire == 1 ? 8 : 4;
            if (n > size - pos) throw std::runtime_error("Truncated fixed field");
            pos += n;
        } else if (wire == 2) {
            uint64_t n = read();
            if (n > size - pos) throw std::runtime_error("Truncated string field");
            value.text.assign(reinterpret_cast<const char *>(p + pos), size_t(n)); pos += size_t(n);
        } else throw std::runtime_error("Unsupported protobuf wire type");
        out[field] = std::move(value);
    }
    return out;
}
inline std::string text(const Fields &f, unsigned n) {
    auto it = f.find(n); return it != f.end() && it->second.wire == 2 ? it->second.text : "";
}
inline uint64_t value(const Fields &f, unsigned n, uint64_t fallback = 0) {
    auto it = f.find(n); return it != f.end() && it->second.wire == 0 ? it->second.integer : fallback;
}
inline Bytes session(const std::string &uuid) {
    Bytes b; string(b, 1, uuid); string(b, 2, "video-translation"); return b;
}
inline Bytes translation(const std::string &url, double duration, const std::string &from,
                         const std::string &to, bool first, bool forceLanguage,
                         const std::string &audioURL = "", bool lively = false) {
    Bytes b; string(b, 3, url); if (first) integer(b, 5, 1); number(b, 6, duration);
    integer(b, 7, 1); string(b, 8, from); if (forceLanguage) integer(b, 9, 1);
    if (!audioURL.empty()) {
        Bytes help; string(help, 1, "video_file_url"); string(help, 2, audioURL);
        blob(b, 11, help.data(), help.size());
    }
    string(b, 14, to); integer(b, 15, 1); integer(b, 16, 2);
    if (lively) integer(b, 18, 1);
    return b;
}
inline Bytes audio(const std::string &translationID, const std::string &url,
                   const std::string &fileID, const uint8_t *p, size_t n) {
    Bytes info; string(info, 1, fileID); blob(info, 2, p, n);
    Bytes b; string(b, 1, translationID); string(b, 2, url);
    blob(b, 6, info.data(), info.size()); return b;
}
}
