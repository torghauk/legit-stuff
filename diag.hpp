// diag.hpp — emit one JSON record per write {id, input_file, output_file,
// text, trace}, one object per line, for a separate consumer to tail.
//
// Link <stacktrace>:  GCC 14+ -> -lstdc++exp,  GCC 13 -> -lstdc++_libbacktrace.
// nlohmann/json is header-only.

#pragma once

#include <cstdint>
#include <ostream>
#include <stacktrace>
#include <string>
#include <string_view>

#include <nlohmann/json.hpp>

namespace diag {

inline nlohmann::json to_json(const std::stacktrace& st) {
    auto frames = nlohmann::json::array();
    for (const auto& f : st)
        frames.push_back({{"desc", f.description()},
                          {"file", f.source_file()},
                          {"line", f.source_line()}});
    return frames;
}

class Sink {
public:
    explicit Sink(std::ostream& os) : os_(os) {}

    void emit(std::uint64_t id,
              std::string_view input_file,
              std::string_view output_file,
              std::string_view text) {
        nlohmann::json rec;
        rec["id"]          = id;
        rec["input_file"]  = std::string(input_file);
        rec["output_file"] = std::string(output_file);
        rec["text"]        = std::string(text);
        rec["trace"]       = to_json(std::stacktrace::current(1));  // skip emit()
        os_ << rec.dump() << '\n';
        os_.flush();
    }

private:
    std::ostream& os_;
};

} // namespace diag
