// ingest_main.cpp — CLI to ingest a run directory and print resolved provenance.
// Doubles as the headless test/verification harness for the format.
//   ./ingest_main [run_dir]   (defaults to $DIAG_DIR or ./.diag)
#include <cstdlib>
#include <cstdio>
#include <set>
#include "ingest.hpp"

int main(int argc, char** argv) {
    std::string dir = (argc > 1) ? argv[1]
                    : (std::getenv("DIAG_DIR") ? std::getenv("DIAG_DIR") : ".diag");
    auto recs = ingest::ingest_dir(dir);
    auto tree = ingest::build_tree(recs);

    std::set<std::string> sessions, tools;
    for (auto& r : recs) { sessions.insert(r.session); tools.insert(r.tool); }

    std::printf("dir: %s\n", dir.c_str());
    std::printf("records: %zu   sessions: %zu   packages: %zu   tools: %zu\n",
                recs.size(), sessions.size(), tree.size(), tools.size());

    for (auto& pg : tree) {
        std::printf("package '%s'\n", pg.package.c_str());
        for (auto& ig : pg.inputs) {
            std::printf("  input %s\n", ig.input.c_str());
            for (auto& og : ig.outputs) {
                std::string src = ingest::reconstruct(recs, og.recs);
                // count sessions contributing to this output (parallel-safety check)
                std::set<std::string> os;
                for (int i : og.recs) os.insert(recs[i].session);
                std::printf("    -> %-12s  %2zu writes, %3zu bytes, %zu session(s)\n",
                            og.output.c_str(), og.recs.size(), src.size(), os.size());
            }
        }
    }
    return 0;
}
