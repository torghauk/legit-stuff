// sources.hpp — on-disk source cache (compiler files AND input files) + remap.
#pragma once
#include <fstream>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace sources {

struct File { bool ok = false; std::vector<std::string> lines; };

class Cache {
public:
    // remap: rewrite a leading `from` prefix to `to` so traces captured on a
    // build machine resolve locally. One pair is enough for most setups.
    void set_remap(std::string from, std::string to) { from_ = std::move(from); to_ = std::move(to); }

    const File& get(const std::string& path) {
        auto it = cache_.find(path);
        if (it != cache_.end()) return it->second;
        File f; std::string real = remap(path);
        if (std::ifstream in(real); in) { f.ok = true; std::string l;
            while (std::getline(in, l)) f.lines.push_back(l); }
        return cache_.emplace(path, std::move(f)).first->second;
    }
    void clear() { cache_.clear(); }
private:
    std::string remap(const std::string& p) const {
        if (!from_.empty() && p.rfind(from_, 0) == 0) return to_ + p.substr(from_.size());
        return p;
    }
    std::map<std::string, File> cache_;
    std::string from_, to_;
};

} // namespace sources
