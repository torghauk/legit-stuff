// proc.hpp — async command runner (streaming output) + editor template + mtime.
#pragma once
#include <atomic>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <sys/stat.h>
#include <sys/wait.h>

namespace proc {

inline std::string expand(std::string tmpl, const std::string& file, int line) {
    auto rep = [&](const std::string& k, const std::string& v) {
        for (size_t p; (p = tmpl.find(k)) != std::string::npos; ) tmpl.replace(p, k.size(), v);
    };
    rep("{file}", file); rep("{line}", std::to_string(line));
    return tmpl;
}
inline time_t mtime(const std::string& p) { struct stat st; return stat(p.c_str(), &st) == 0 ? st.st_mtime : 0; }

// Runs a command on a worker thread; UI polls running/done and reads `output`.
class Runner {
public:
    ~Runner() { if (th_.joinable()) th_.join(); }
    bool running() const { return running_.load(); }
    bool take_done() { return done_.exchange(false); }     // true once per completion
    int  exit_code() const { return exit_.load(); }
    bool reload_after() const { return reload_after_; }
    std::string label() { std::scoped_lock lk(mtx_); return label_; }
    std::string output() { std::scoped_lock lk(mtx_); return output_; }

    void start(std::string label, std::string cmd, bool reload_after) {
        if (running_) return;
        if (th_.joinable()) th_.join();
        { std::scoped_lock lk(mtx_); label_ = std::move(label); output_.clear(); }
        reload_after_ = reload_after; exit_ = -1; running_ = true; done_ = false;
        th_ = std::thread([this, cmd] {
            FILE* p = popen((cmd + " 2>&1").c_str(), "r");
            if (p) { char buf[4096]; size_t n;
                while ((n = std::fread(buf, 1, sizeof buf, p)) > 0) { std::scoped_lock lk(mtx_); output_.append(buf, n); }
                int st = pclose(p); exit_ = WIFEXITED(st) ? WEXITSTATUS(st) : -1; }
            else { std::scoped_lock lk(mtx_); output_ = "failed to start command"; exit_ = -1; }
            running_ = false; done_ = true;
        });
    }
private:
    std::thread th_; std::mutex mtx_;
    std::atomic<bool> running_{false}, done_{false}; std::atomic<int> exit_{-1};
    bool reload_after_ = false; std::string label_, output_;
};

} // namespace proc
