// diag.hpp — diagnostic event emit library (format v1).
//
// Dependency-free (no JSON library) so it embeds cleanly in any compiler.
// One Sink per process writes $DIAG_DIR/<session>.jsonl as NDJSON events.
//
// Usage (works for a compiler that knows files only at a convenient point,
// e.g. the loop over inputs and just before each output is generated):
//
//   diag::Sink diag("frontend");          // tool name; reads $DIAG_DIR,$DIAG_PACKAGE
//   for (auto& in : inputs) {
//       diag.set_input(in.path);
//       ...
//       diag.set_output(out.path);        // before generating that output
//       diag.write(chunk);                // at each write point (captures stacktrace)
//   }
//
// Link <stacktrace>:  GCC 14+ -> -lstdc++exp ; GCC 13 (Ubuntu 24.04) -> -lstdc++exp.

#pragma once

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <stacktrace>
#include <string>
#include <string_view>
#include <unistd.h>   // getpid, gethostname

namespace diag {

// Minimal JSON string escaping.
inline void json_escape(std::string& out, std::string_view s) {
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8]; std::snprintf(buf, sizeof buf, "\\u%04x", c & 0xff);
                    out += buf;
                } else out += c;
        }
    }
}

class Sink {
public:
    explicit Sink(std::string tool = "") : tool_(std::move(tool)) {
        if (const char* p = std::getenv("DIAG_PACKAGE")) package_ = p;

        char host[256] = {0};
        if (::gethostname(host, sizeof host - 1) != 0) std::snprintf(host, sizeof host, "host");
        const long pid = ::getpid();
        session_ = std::string(host) + "-" + std::to_string(pid) + "-" + std::to_string(now_us());
        for (char& c : session_)
            if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_' || c == '.'))
                c = '_';

        const char* dir = std::getenv("DIAG_DIR");
        std::filesystem::path d = (dir && *dir) ? std::filesystem::path(dir)
                                                : std::filesystem::path(".diag");
        std::error_code ec; std::filesystem::create_directories(d, ec);
        os_.open(d / (session_ + ".jsonl"), std::ios::out | std::ios::trunc);

        emit_meta();
    }

    const std::string& session() const { return session_; }

    void set_input(std::string_view path)  { emit_ctx("input",  path); }
    void set_output(std::string_view path) { emit_ctx("output", path); }

    void write(std::string_view text, bool with_trace = true) {
        std::string line; line.reserve(text.size() + 256);
        line += '{'; common(line, "write");
        line += ",\"text\":\""; json_escape(line, text); line += '"';
        if (with_trace) { line += ",\"trace\":"; append_trace(line, std::stacktrace::current(1)); }
        line += "}\n";
        write_line(line);
    }

private:
    static std::int64_t now_us() {
        return std::chrono::duration_cast<std::chrono::microseconds>(
                   std::chrono::system_clock::now().time_since_epoch()).count();
    }
    void common(std::string& line, std::string_view ev) {
        line += "\"session\":\""; json_escape(line, session_); line += '"';
        line += ",\"seq\":" + std::to_string(seq_.fetch_add(1, std::memory_order_relaxed));
        line += ",\"event\":\""; line += ev; line += '"';
        line += ",\"ts\":" + std::to_string(now_us());
    }
    void emit_meta() {
        std::string line = "{"; common(line, "meta");
        line += ",\"tool\":\"";    json_escape(line, tool_);    line += '"';
        line += ",\"package\":\""; json_escape(line, package_); line += '"';
        line += ",\"pid\":" + std::to_string(static_cast<long>(::getpid()));
        line += "}\n";
        write_line(line);
    }
    void emit_ctx(std::string_view ev, std::string_view path) {
        std::string line = "{"; common(line, ev);
        line += ",\"path\":\""; json_escape(line, path); line += '"';
        line += "}\n";
        write_line(line);
    }
    static void append_trace(std::string& out, const std::stacktrace& st) {
        out += '['; bool first = true;
        for (const auto& f : st) {
            if (!first) out += ','; first = false;
            out += "{\"desc\":\"";  json_escape(out, f.description());  out += '"';
            out += ",\"file\":\"";  json_escape(out, f.source_file());  out += '"';
            out += ",\"line\":" + std::to_string(static_cast<long>(f.source_line()));
            out += '}';
        }
        out += ']';
    }
    void write_line(const std::string& l) {
        std::scoped_lock lk(mtx_);
        os_.write(l.data(), static_cast<std::streamsize>(l.size()));
        os_.flush();   // crash-safe: a killed compiler leaves only complete lines
    }

    std::ofstream              os_;
    std::mutex                 mtx_;
    std::atomic<std::uint64_t> seq_{0};
    std::string                session_, tool_, package_;
};

} // namespace diag
