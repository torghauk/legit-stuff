// ingest.hpp — consumer side of format v1: parse + per-session replay + merge.
//
// Reads every *.jsonl in a run directory, replays input/output context per
// session, and yields resolved records grouped package -> input -> output.
// This is the model layer the viewer builds on.

#pragma once

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace ingest {

struct Frame { std::string desc, file; int line = 0; };

struct Record {                       // a resolved write
    std::string   session;
    std::uint64_t seq = 0;
    std::string   tool, package, input, output, text;
    std::vector<Frame> trace;
    std::int64_t  ts = 0;
};

inline std::vector<Frame> parse_trace(const nlohmann::json& j) {
    std::vector<Frame> t;
    if (j.contains("trace") && j["trace"].is_array())
        for (const auto& f : j["trace"])
            t.push_back({ f.value("desc", std::string{}),
                          f.value("file", std::string{}),
                          f.value("line", 0) });
    return t;
}

// Replay one session file into resolved records.
inline void ingest_file(const std::filesystem::path& p, std::vector<Record>& out) {
    std::ifstream in(p);
    if (!in) return;
    std::string line, sess, tool, pkg, cur_in, cur_out;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto j = nlohmann::json::parse(line, nullptr, /*allow_exceptions=*/false);
        if (j.is_discarded() || !j.contains("event")) continue;   // tolerate partials
        const std::string ev = j.value("event", std::string{});
        if (ev == "meta") {
            sess = j.value("session", std::string{});
            tool = j.value("tool", std::string{});
            pkg  = j.value("package", std::string{});
        } else if (ev == "input")  { cur_in  = j.value("path", std::string{}); }
        else if   (ev == "output") { cur_out = j.value("path", std::string{}); }
        else if   (ev == "write") {
            Record r;
            r.session = j.value("session", sess);
            r.seq     = j.value("seq", 0ull);
            r.ts      = j.value("ts", 0ll);
            r.tool = tool; r.package = pkg; r.input = cur_in; r.output = cur_out;
            r.text  = j.value("text", std::string{});
            r.trace = parse_trace(j);
            out.push_back(std::move(r));
        }
    }
}

inline std::vector<Record> ingest_dir(const std::string& dir) {
    std::vector<Record> out;
    std::error_code ec;
    if (std::filesystem::is_directory(dir, ec)) {
        std::vector<std::filesystem::path> files;
        for (auto& e : std::filesystem::directory_iterator(dir, ec))
            if (e.is_regular_file() && e.path().extension() == ".jsonl") files.push_back(e.path());
        std::sort(files.begin(), files.end());     // stable session order
        for (auto& f : files) ingest_file(f, out);
    } else {
        ingest_file(dir, out);                      // allow a single file too
    }
    return out;
}

// ---- grouping: package -> input -> output -> record indices ----
struct OutputGroup  { std::string output;  std::vector<int> recs; };
struct InputGroup   { std::string input;   std::vector<OutputGroup> outputs; };
struct PackageGroup { std::string package; std::vector<InputGroup> inputs; };

inline std::vector<PackageGroup> build_tree(const std::vector<Record>& recs) {
    std::vector<PackageGroup> tree;
    std::map<std::string, int> pi;
    std::map<std::pair<std::string,std::string>, int> ii;
    std::map<std::tuple<std::string,std::string,std::string>, int> oi;
    for (int i = 0; i < (int)recs.size(); ++i) {
        const auto& r = recs[i];
        int p;
        if (auto it = pi.find(r.package); it != pi.end()) p = it->second;
        else { p = (int)tree.size(); pi[r.package] = p; tree.push_back({r.package, {}}); }
        int in;
        auto ik = std::make_pair(r.package, r.input);
        if (auto it = ii.find(ik); it != ii.end()) in = it->second;
        else { in = (int)tree[p].inputs.size(); ii[ik] = in; tree[p].inputs.push_back({r.input, {}}); }
        int ou;
        auto ok = std::make_tuple(r.package, r.input, r.output);
        if (auto it = oi.find(ok); it != oi.end()) ou = it->second;
        else { ou = (int)tree[p].inputs[in].outputs.size(); oi[ok] = ou;
               tree[p].inputs[in].outputs.push_back({r.output, {}}); }
        tree[p].inputs[in].outputs[ou].recs.push_back(i);
    }
    // order each output's records by (session, seq)
    for (auto& pg : tree) for (auto& ig : pg.inputs) for (auto& og : ig.outputs)
        std::sort(og.recs.begin(), og.recs.end(), [&](int a, int b){
            if (recs[a].session != recs[b].session) return recs[a].session < recs[b].session;
            return recs[a].seq < recs[b].seq;
        });
    return tree;
}

inline std::string reconstruct(const std::vector<Record>& recs, const std::vector<int>& idx) {
    std::string s; for (int i : idx) s += recs[i].text; return s;
}

} // namespace ingest
