// viewer.cpp — Dear ImGui frontend for the compiler's diagnostic stream.
//
//   Toolbar : Reload / Recompile / Run / Snapshot, a "Diff vs" snapshot picker,
//             Watch (auto-reload on file change), and "highlight frame fragments".
//   Tabs    : outer = input file, inner = one of that input's output files.
//   Left    : the output's source (syntax highlighted). Click a fragment to
//             select its record. In diff mode: a line diff, or (Trace-aware) a
//             fragment-level change report distinguishing text vs path changes.
//   Right   : top = the fragment's stacktrace (write_code + sub-main stubs
//             hidden); click a frame to view + open its compiler source line,
//             and to highlight every fragment routed through that function.
//
// CLI: ./viewer [compile.jsonl] [build_cmd] [run_cmd] [nvim_socket]
//   defaults: compile.jsonl, the dummy g++ line, ./dummy_compiler, /tmp/nvim.sock
// Open-in-nvim targets a running `nvim --listen /tmp/nvim.sock`.
// Command running + nvim use popen (POSIX); file watching uses stat(2).

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <sys/wait.h>

#include <nlohmann/json.hpp>

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include <GLFW/glfw3.h>

namespace {

struct Frame { std::string desc; std::string file; int line = 0; };

struct Record {
    std::uint64_t      id = 0;
    std::string        text;
    std::string        input_file;
    std::string        output_file;
    std::vector<Frame> trace;
};

struct OutputGroup { std::string output; std::vector<int> recs; };
struct InputGroup  { std::string input;  std::vector<OutputGroup> outputs; };

std::vector<Record> load_records(const std::string& path) {
    std::vector<Record> recs;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto j = nlohmann::json::parse(line, nullptr, false);
        if (j.is_discarded() || !j.contains("text")) continue;
        Record r;
        r.id          = j.value("id", 0ull);
        r.text        = j.value("text", std::string{});
        r.input_file  = j.value("input_file", std::string{});
        r.output_file = j.value("output_file", std::string{});
        if (j.contains("trace") && j["trace"].is_array())
            for (const auto& f : j["trace"])
                r.trace.push_back({ f.value("desc", std::string{}),
                                    f.value("file", std::string{}),
                                    f.value("line", 0) });
        recs.push_back(std::move(r));
    }
    std::stable_sort(recs.begin(), recs.end(),
                     [](const Record& a, const Record& b) { return a.id < b.id; });
    return recs;
}

std::vector<InputGroup> build_tree(const std::vector<Record>& recs) {
    std::vector<InputGroup> tree;
    std::map<std::string, int> in_idx;
    std::map<std::pair<std::string, std::string>, int> out_idx;
    for (int i = 0; i < static_cast<int>(recs.size()); ++i) {
        const std::string& in = recs[i].input_file;
        const std::string& ou = recs[i].output_file;
        int ii;
        if (auto it = in_idx.find(in); it != in_idx.end()) ii = it->second;
        else { ii = static_cast<int>(tree.size()); in_idx[in] = ii; tree.push_back({in, {}}); }
        int oi;
        auto key = std::make_pair(in, ou);
        if (auto it = out_idx.find(key); it != out_idx.end()) oi = it->second;
        else { oi = static_cast<int>(tree[ii].outputs.size()); out_idx[key] = oi;
               tree[ii].outputs.push_back({ou, {}}); }
        tree[ii].outputs[oi].recs.push_back(i);
    }
    return tree;
}

std::string reconstruct(const std::vector<Record>& recs, const std::vector<int>& idxs) {
    std::string s; for (int i : idxs) s += recs[i].text; return s;
}
std::vector<std::string> split_lines(const std::string& s) {
    std::vector<std::string> out; std::string cur;
    for (char c : s) { if (c == '\n') { out.push_back(cur); cur.clear(); } else cur += c; }
    out.push_back(cur);
    return out;
}

struct Segment { int record = -1; std::string text; };
using Line = std::vector<Segment>;
std::vector<Line> to_lines(const std::vector<Record>& recs, const std::vector<int>& idxs) {
    std::vector<Line> lines(1);
    for (int ri : idxs) {
        std::string cur;
        for (char c : recs[ri].text) {
            if (c == '\n') { if (!cur.empty()) lines.back().push_back({ri, cur});
                             cur.clear(); lines.emplace_back(); }
            else cur += c;
        }
        if (!cur.empty()) lines.back().push_back({ri, cur});
    }
    return lines;
}

struct DiffLine { char tag; std::string text; };
std::vector<DiffLine> diff_lines(const std::vector<std::string>& a,
                                 const std::vector<std::string>& b) {
    const int n = (int)a.size(), m = (int)b.size();
    std::vector<std::vector<int>> dp(n + 1, std::vector<int>(m + 1, 0));
    for (int i = n - 1; i >= 0; --i)
        for (int j = m - 1; j >= 0; --j)
            dp[i][j] = (a[i] == b[j]) ? dp[i + 1][j + 1] + 1
                                      : std::max(dp[i + 1][j], dp[i][j + 1]);
    std::vector<DiffLine> out; int i = 0, j = 0;
    while (i < n && j < m) {
        if (a[i] == b[j])                  { out.push_back({' ', a[i]}); ++i; ++j; }
        else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push_back({'-', a[i]}); ++i; }
        else                               { out.push_back({'+', b[j]}); ++j; }
    }
    while (i < n) out.push_back({'-', a[i++]});
    while (j < m) out.push_back({'+', b[j++]});
    return out;
}

struct FileSrc { bool ok = false; std::vector<std::string> lines; };
const FileSrc& get_file(std::map<std::string, FileSrc>& cache, const std::string& path) {
    if (auto it = cache.find(path); it != cache.end()) return it->second;
    FileSrc fs;
    if (std::ifstream in(path); in) { fs.ok = true; std::string l;
        while (std::getline(in, l)) fs.lines.push_back(l); }
    return cache.emplace(path, std::move(fs)).first->second;
}

struct CmdResult { bool ran = false; int exit = -1; std::string output; };
CmdResult run_cmd(const std::string& cmd) {
    CmdResult r; r.ran = true;
    FILE* p = popen((cmd + " 2>&1").c_str(), "r");
    if (!p) { r.output = "failed to start: " + cmd; return r; }
    char buf[4096]; size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, p)) > 0) r.output.append(buf, n);
    int status = pclose(p);
    r.exit = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return r;
}

std::string key_of(const std::string& in, const std::string& out) { return in + "\x1f" + out; }

// Frames worth showing: drop the write_code write point and stop after main.
std::vector<int> visible_frames(const Record& r) {
    std::vector<int> v;
    for (int i = 0; i < (int)r.trace.size(); ++i) {
        const std::string& d = r.trace[i].desc;
        if (d.find("write_code") != std::string::npos) continue;
        v.push_back(i);
        if (d == "main") break;
    }
    return v;
}
// A signature of a fragment's code path (the visible frame descriptions).
std::string path_sig(const Record& r) {
    std::string s;
    for (int i : visible_frames(r)) { if (!s.empty()) s += '\n'; s += r.trace[i].desc; }
    return s;
}

struct FragInfo { std::string text; std::string sig; };
struct Snapshot { std::string label; std::map<std::string, std::vector<FragInfo>> frags; };

// Fragment-level (trace-aware) diff.
struct FragCur { int rec; std::string text; std::string sig; };
enum FDKind { FDSame, FDText, FDPath, FDChanged, FDAdd, FDDel };
struct FragDiff { FDKind kind; int cur_rec; std::string snap_text; std::string cur_text; };

std::vector<FragDiff> align_frags(const std::vector<FragInfo>& S,
                                  const std::vector<FragCur>& C) {
    const int n = (int)S.size(), m = (int)C.size();
    auto eq = [&](int i, int j) { return S[i].text == C[j].text && S[i].sig == C[j].sig; };
    std::vector<std::vector<int>> dp(n + 1, std::vector<int>(m + 1, 0));
    for (int i = n - 1; i >= 0; --i)
        for (int j = m - 1; j >= 0; --j)
            dp[i][j] = eq(i, j) ? dp[i + 1][j + 1] + 1
                                : std::max(dp[i + 1][j], dp[i][j + 1]);
    std::vector<FragDiff> out;
    std::vector<int> dels, adds;
    auto flush = [&] {
        std::vector<char> du(dels.size(), 0), au(adds.size(), 0);
        for (size_t a = 0; a < adds.size(); ++a)            // same path, diff text
            for (size_t d = 0; d < dels.size(); ++d)
                if (!au[a] && !du[d] && S[dels[d]].sig == C[adds[a]].sig) {
                    out.push_back({FDText, C[adds[a]].rec, S[dels[d]].text, C[adds[a]].text});
                    au[a] = du[d] = 1; break; }
        for (size_t a = 0; a < adds.size(); ++a)            // same text, diff path
            if (!au[a]) for (size_t d = 0; d < dels.size(); ++d)
                if (!du[d] && S[dels[d]].text == C[adds[a]].text) {
                    out.push_back({FDPath, C[adds[a]].rec, S[dels[d]].text, C[adds[a]].text});
                    au[a] = du[d] = 1; break; }
        size_t da = 0;
        for (size_t a = 0; a < adds.size(); ++a) {          // both differ
            if (au[a]) continue;
            while (da < dels.size() && du[da]) ++da;
            if (da < dels.size()) {
                out.push_back({FDChanged, C[adds[a]].rec, S[dels[da]].text, C[adds[a]].text});
                au[a] = du[da] = 1; }
        }
        for (size_t d = 0; d < dels.size(); ++d) if (!du[d]) out.push_back({FDDel, -1, S[dels[d]].text, ""});
        for (size_t a = 0; a < adds.size(); ++a) if (!au[a]) out.push_back({FDAdd, C[adds[a]].rec, "", C[adds[a]].text});
        dels.clear(); adds.clear();
    };
    int i = 0, j = 0;
    while (i < n && j < m) {
        if (eq(i, j)) { if (!dels.empty() || !adds.empty()) flush();
                        out.push_back({FDSame, C[j].rec, S[i].text, C[j].text}); ++i; ++j; }
        else if (dp[i + 1][j] >= dp[i][j + 1]) dels.push_back(i++);
        else                                   adds.push_back(j++);
    }
    while (i < n) dels.push_back(i++);
    while (j < m) adds.push_back(j++);
    if (!dels.empty() || !adds.empty()) flush();
    return out;
}

// ---- minimal C++ line tokenizer for syntax highlighting ----
enum Tk { TkDefault, TkKeyword, TkType, TkString, TkChar, TkNumber, TkComment, TkPreproc, TkPunct };
struct Span { int start; int len; Tk kind; };

ImU32 tk_color(Tk k) {
    switch (k) {
        case TkKeyword: return IM_COL32(197, 134, 192, 255);
        case TkType:    return IM_COL32( 78, 201, 176, 255);
        case TkString:  return IM_COL32(206, 145, 120, 255);
        case TkChar:    return IM_COL32(206, 145, 120, 255);
        case TkNumber:  return IM_COL32(181, 206, 168, 255);
        case TkComment: return IM_COL32(106, 153,  85, 255);
        case TkPreproc: return IM_COL32(155, 155, 255, 255);
        default:        return IM_COL32(212, 212, 212, 255);
    }
}
bool id0(char c) { return std::isalpha((unsigned char)c) || c == '_'; }
bool idc(char c) { return std::isalnum((unsigned char)c) || c == '_'; }
const std::set<std::string> kKeywords = {
    "alignas","alignof","auto","break","case","catch","class","const","constexpr","continue",
    "decltype","default","delete","do","else","enum","explicit","export","extern","false","for",
    "friend","goto","if","inline","mutable","namespace","new","noexcept","nullptr","operator",
    "override","private","protected","public","return","sizeof","static","struct","switch",
    "template","this","throw","true","try","typedef","typename","union","using","virtual",
    "volatile","while" };
const std::set<std::string> kTypes = {
    "bool","char","double","float","int","long","short","signed","unsigned","void","size_t",
    "int8_t","int16_t","int32_t","int64_t","uint8_t","uint16_t","uint32_t","uint64_t",
    "std","string","string_view","vector","int64_t" };

std::vector<Span> tokenize_cpp_line(const std::string& s, bool& in_block) {
    std::vector<Span> out; const int n = (int)s.size(); int i = 0;
    while (i < n) {
        if (in_block) {
            int st = i;
            while (i < n) { if (s[i] == '*' && i + 1 < n && s[i + 1] == '/') { i += 2; in_block = false; break; } ++i; }
            out.push_back({st, i - st, TkComment}); continue;
        }
        char c = s[i];
        if (c == ' ' || c == '\t') { int st = i; while (i < n && (s[i] == ' ' || s[i] == '\t')) ++i; out.push_back({st, i - st, TkDefault}); continue; }
        if (c == '/' && i + 1 < n && s[i + 1] == '/') { out.push_back({i, n - i, TkComment}); i = n; continue; }
        if (c == '/' && i + 1 < n && s[i + 1] == '*') { int st = i; i += 2; in_block = true;
            while (i < n) { if (s[i] == '*' && i + 1 < n && s[i + 1] == '/') { i += 2; in_block = false; break; } ++i; }
            out.push_back({st, i - st, TkComment}); continue; }
        if (c == '"' || c == '\'') { char q = c; int st = i; ++i;
            while (i < n) { if (s[i] == '\\') { i += 2; continue; } if (s[i] == q) { ++i; break; } ++i; }
            out.push_back({st, i - st, q == '"' ? TkString : TkChar}); continue; }
        if (c == '#') { int st = i; ++i; while (i < n && idc(s[i])) ++i; out.push_back({st, i - st, TkPreproc}); continue; }
        if (std::isdigit((unsigned char)c) || (c == '.' && i + 1 < n && std::isdigit((unsigned char)s[i + 1]))) {
            int st = i; while (i < n && (idc(s[i]) || s[i] == '.')) ++i; out.push_back({st, i - st, TkNumber}); continue; }
        if (id0(c)) { int st = i; while (i < n && idc(s[i])) ++i; std::string w = s.substr(st, i - st);
            Tk k = kKeywords.count(w) ? TkKeyword : kTypes.count(w) ? TkType : TkDefault;
            out.push_back({st, i - st, k}); continue; }
        out.push_back({i, 1, TkPunct}); ++i;
    }
    return out;
}

time_t file_mtime(const std::string& p) { struct stat st; return (stat(p.c_str(), &st) == 0) ? st.st_mtime : 0; }
std::string nvim_command(const std::string& sock, const std::string& file, int line) {
    return "nvim --server " + sock + " --remote-send '<C-\\><C-n>:edit +"
         + std::to_string(line) + " " + file + "<CR>'";
}

} // namespace

int main(int argc, char** argv) {
    const std::string path = (argc > 1) ? argv[1] : "compile.jsonl";
    const std::string build_command = (argc > 2) ? argv[2]
        : "g++ -std=c++23 -g -Iinclude dummy_compiler.cpp -o dummy_compiler -lstdc++exp";
    const std::string run_command = (argc > 3) ? argv[3] : "./dummy_compiler";
    const std::string nvim_sock   = (argc > 4) ? argv[4] : "/tmp/nvim.sock";

    if (!glfwInit()) return 1;
    const char* glsl_version = "#version 130";
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
    GLFWwindow* window = glfwCreateWindow(1300, 840, "Generated Output Viewer", nullptr, nullptr);
    if (!window) { glfwTerminate(); return 1; }
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;
    ImGui::StyleColorsDark();
    // For column-aligned source, load a monospace font here, e.g.:
    //   ImGui::GetIO().Fonts->AddFontFromFileTTF("DejaVuSansMono.ttf", 16.0f);
    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init(glsl_version);

    std::vector<Record>     records = load_records(path);
    std::vector<InputGroup> tree    = build_tree(records);
    std::map<std::string, FileSrc> file_cache;
    std::vector<Snapshot>   snapshots;
    int                     snap_counter = 0;

    std::vector<Line> lines;
    int  active_in = -1, active_out = -1;
    int  selected_record = -1, selected_frame = -1;
    bool scroll_to_frame = false;
    int  diff_sel = -1;
    bool trace_aware = false, hide_same = false;
    CmdResult last_cmd;

    bool reverse_enabled = true;
    std::string  reverse_desc;
    std::set<int> reverse_recs;

    bool   watch = false; double last_check = 0; time_t last_mtime = file_mtime(path);

    bool pending_apply = false; std::string pending_input, pending_output;
    std::uint64_t pending_id = UINT64_MAX;

    const int force_input = -1, force_output = -1;   // demo hooks

    const ImU32 sel_bg     = IM_COL32(70, 120, 200, 120);
    const ImU32 hover_bg   = IM_COL32(160, 160, 160, 40);
    const ImU32 line_bg    = IM_COL32(70, 120, 200, 90);
    const ImU32 reverse_bg = IM_COL32(210, 140, 40, 90);
    const ImU32 add_row_bg = IM_COL32(60, 130, 60, 45);
    const ImVec4 col_add(0.55f, 0.95f, 0.55f, 1.0f);
    const ImVec4 col_del(1.00f, 0.50f, 0.50f, 1.0f);
    const ImVec4 col_same(0.60f, 0.60f, 0.60f, 1.0f);
    const ImVec4 col_text(0.92f, 0.82f, 0.30f, 1.0f);
    const ImVec4 col_path(0.95f, 0.50f, 0.95f, 1.0f);

    auto compute_reverse = [&](const std::string& desc) {
        reverse_desc = desc; reverse_recs.clear();
        if (desc.empty()) return;
        for (int gi = 0; gi < (int)records.size(); ++gi)
            for (const auto& fr : records[gi].trace)
                if (fr.desc == desc) { reverse_recs.insert(gi); break; }
    };
    auto pick_frame = [&](int ri) {
        const std::vector<int> vf = visible_frames(records[ri]);
        int sf = vf.empty() ? -1 : vf.front();
        for (int k : vf) if (!records[ri].trace[k].file.empty()) { sf = k; break; }
        return sf;
    };
    auto select_record = [&](int ri) {
        selected_record = ri; selected_frame = pick_frame(ri); scroll_to_frame = true;
    };
    auto select_frame = [&](int ri, int fi) {
        selected_frame = fi; scroll_to_frame = true;
        compute_reverse(records[ri].trace[fi].desc);
    };
    auto snapshot_now = [&] {
        Snapshot s; s.label = "run " + std::to_string(++snap_counter);
        for (const auto& ig : tree)
            for (const auto& og : ig.outputs) {
                auto& v = s.frags[key_of(ig.input, og.output)];
                for (int gi : og.recs) v.push_back({records[gi].text, path_sig(records[gi])});
            }
        snapshots.push_back(std::move(s));
    };
    auto reload = [&](bool preserve) {
        std::string sin, sout; std::uint64_t sid = UINT64_MAX;
        if (preserve && active_in >= 0 && active_out >= 0) {
            sin = tree[active_in].input; sout = tree[active_in].outputs[active_out].output;
            if (selected_record >= 0) sid = records[selected_record].id;
        }
        records = load_records(path); tree = build_tree(records);
        file_cache.clear(); lines.clear();
        active_in = active_out = selected_record = selected_frame = -1;
        reverse_desc.clear(); reverse_recs.clear();
        last_mtime = file_mtime(path);
        pending_apply = preserve; pending_input = sin; pending_output = sout; pending_id = sid;
    };

    while (!glfwWindowShouldClose(window)) {
        if (watch) {
            double t = glfwGetTime();
            if (t - last_check > 0.5) {
                last_check = t;
                time_t mt = file_mtime(path);
                if (mt != 0 && mt != last_mtime) reload(true);
            }
        }

        glfwPollEvents();
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();

        const ImGuiViewport* vp = ImGui::GetMainViewport();
        ImGui::SetNextWindowPos(vp->WorkPos);
        ImGui::SetNextWindowSize(vp->WorkSize);
        ImGui::Begin("root", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse);

        // -------------------- toolbar --------------------
        if (ImGui::Button("Reload"))    reload(false);
        ImGui::SameLine();
        if (ImGui::Button("Recompile")) last_cmd = run_cmd(build_command);
        ImGui::SameLine();
        if (ImGui::Button("Run"))     { last_cmd = run_cmd(run_command); reload(true); }
        ImGui::SameLine();
        if (ImGui::Button("Snapshot")) snapshot_now();
        ImGui::SameLine();
        ImGui::SetNextItemWidth(170);
        const char* dpre = (diff_sel < 0) ? "(none)" : snapshots[diff_sel].label.c_str();
        if (ImGui::BeginCombo("Diff vs", dpre)) {
            if (ImGui::Selectable("(none)", diff_sel < 0)) diff_sel = -1;
            for (int s = 0; s < (int)snapshots.size(); ++s)
                if (ImGui::Selectable(snapshots[s].label.c_str(), diff_sel == s)) diff_sel = s;
            ImGui::EndCombo();
        }
        ImGui::SameLine(); ImGui::Checkbox("Watch", &watch);
        ImGui::SameLine(); ImGui::Checkbox("Highlight frame fragments", &reverse_enabled);

        ImGui::Text("Records: %zu    Inputs: %zu    Snapshots: %zu",
                    records.size(), tree.size(), snapshots.size());
        if (last_cmd.ran) {
            ImGui::SameLine();
            ImGui::TextColored(last_cmd.exit == 0 ? col_add : col_del,
                               "   last command: exit %d", last_cmd.exit);
        }
        if (ImGui::CollapsingHeader("Command output")) {
            ImGui::BeginChild("cmdout", ImVec2(0, 120), true, ImGuiWindowFlags_HorizontalScrollbar);
            if (last_cmd.output.empty()) ImGui::TextDisabled("(no command run yet)");
            else ImGui::TextUnformatted(last_cmd.output.c_str());
            ImGui::EndChild();
        }
        ImGui::Separator();

        if (tree.empty()) {
            ImGui::TextDisabled("No records in %s", path.c_str());
        } else if (ImGui::BeginTabBar("inputs")) {
            for (int ii = 0; ii < (int)tree.size(); ++ii) {
                const bool sel_in = (ii == force_input) ||
                    (pending_apply && tree[ii].input == pending_input);
                if (!ImGui::BeginTabItem(tree[ii].input.c_str(), nullptr,
                                         sel_in ? ImGuiTabItemFlags_SetSelected : 0)) continue;
                ImGui::PushID(ii);

                if (ImGui::BeginTabBar("outputs")) {
                    for (int oi = 0; oi < (int)tree[ii].outputs.size(); ++oi) {
                        const OutputGroup& og = tree[ii].outputs[oi];
                        const bool sel_out = (ii == force_input && oi == force_output) ||
                            (pending_apply && tree[ii].input == pending_input && og.output == pending_output);
                        if (!ImGui::BeginTabItem(og.output.c_str(), nullptr,
                                                 sel_out ? ImGuiTabItemFlags_SetSelected : 0)) continue;

                        if (active_in != ii || active_out != oi) {
                            active_in = ii; active_out = oi; lines = to_lines(records, og.recs);
                        }
                        if (pending_apply && tree[ii].input == pending_input && og.output == pending_output) {
                            if (pending_id != UINT64_MAX)
                                for (int gi : og.recs) if (records[gi].id == pending_id) {
                                    selected_record = gi; selected_frame = pick_frame(gi); break; }
                            pending_apply = false;
                        }

                        const std::string keyc = key_of(tree[ii].input, og.output);
                        const bool diff_active = diff_sel >= 0;
                        const bool sel_in_group =
                            selected_record >= 0 &&
                            records[selected_record].input_file  == tree[ii].input &&
                            records[selected_record].output_file == og.output;

                        if (diff_active) {
                            ImGui::TextDisabled("diff vs %s", snapshots[diff_sel].label.c_str());
                            ImGui::SameLine(); ImGui::Checkbox("Trace-aware", &trace_aware);
                            if (trace_aware) { ImGui::SameLine(); ImGui::Checkbox("Hide unchanged", &hide_same); }
                        }

                        const float full_h = ImGui::GetContentRegionAvail().y;
                        const float left_w = ImGui::GetContentRegionAvail().x * 0.55f;

                        // ============ LEFT pane ============
                        ImGui::BeginChild("left", ImVec2(left_w, full_h), true,
                                          ImGuiWindowFlags_HorizontalScrollbar);
                        {
                            ImDrawList* dl = ImGui::GetWindowDrawList();
                            const float line_h = ImGui::GetTextLineHeight();

                            // Render one reconstructed line: syntax-highlighted, with each
                            // piece resolving to its record (clickable, selectable, reverse-
                            // highlightable). `row_bg` optionally tints the whole row.
                            auto render_line = [&](const Line& ln, bool& in_block, const ImU32* row_bg) {
                                std::string text; std::vector<int> rc;
                                for (const auto& sg : ln) for (char c : sg.text) { text += c; rc.push_back(sg.record); }
                                if (text.empty()) { ImGui::Dummy(ImVec2(0, line_h)); return; }
                                const ImVec2 ls = ImGui::GetCursorScreenPos();
                                if (row_bg) dl->AddRectFilled(ls, ImVec2(ls.x + ImGui::GetContentRegionAvail().x, ls.y + line_h), *row_bg);
                                bool first = true;
                                for (const Span& sp : tokenize_cpp_line(text, in_block)) {
                                    int k = sp.start, e = sp.start + sp.len;
                                    while (k < e) {
                                        int rec = rc[k], j = k; while (j < e && rc[j] == rec) ++j;
                                        std::string piece = text.substr(k, j - k);
                                        if (!first) ImGui::SameLine(0, 0); first = false;
                                        const ImVec2 p = ImGui::GetCursorScreenPos();
                                        const float w = ImGui::CalcTextSize(piece.c_str()).x;
                                        if (reverse_enabled && reverse_recs.count(rec))
                                            dl->AddRectFilled(p, ImVec2(p.x + w, p.y + line_h), reverse_bg);
                                        if (rec == selected_record)
                                            dl->AddRectFilled(p, ImVec2(p.x + w, p.y + line_h), sel_bg);
                                        ImGui::PushStyleColor(ImGuiCol_Text, tk_color(sp.kind));
                                        ImGui::TextUnformatted(piece.c_str());
                                        ImGui::PopStyleColor();
                                        if (ImGui::IsItemHovered()) {
                                            dl->AddRectFilled(p, ImVec2(p.x + w, p.y + line_h), hover_bg);
                                            if (ImGui::IsMouseClicked(ImGuiMouseButton_Left)) select_record(rec);
                                        }
                                        k = j;
                                    }
                                }
                            };

                            if (!diff_active) {                       // ---- plain source ----
                                ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
                                bool in_block = false;
                                for (const Line& ln : lines) render_line(ln, in_block, nullptr);
                                ImGui::PopStyleVar();
                            } else if (trace_aware) {                 // ---- fragment change report ----
                                auto sit = snapshots[diff_sel].frags.find(keyc);
                                if (sit == snapshots[diff_sel].frags.end()) {
                                    ImGui::TextDisabled("'%s' not present in %s", og.output.c_str(),
                                                        snapshots[diff_sel].label.c_str());
                                } else {
                                    std::vector<FragCur> cur;
                                    for (int gi : og.recs) cur.push_back({gi, records[gi].text, path_sig(records[gi])});
                                    auto fds = align_frags(sit->second, cur);
                                    int ct = 0, cp = 0, ca = 0, cd = 0, cc = 0, cs = 0;
                                    for (auto& f : fds) switch (f.kind) {
                                        case FDText: ++ct; break; case FDPath: ++cp; break;
                                        case FDAdd: ++ca; break; case FDDel: ++cd; break;
                                        case FDChanged: ++cc; break; default: ++cs; }
                                    ImGui::Text("%d text, %d PATH, %d added, %d removed, %d changed; %d unchanged",
                                                ct, cp, ca, cd, cc, cs);
                                    ImGui::Separator();
                                    int rowid = 0;
                                    for (const FragDiff& f : fds) {
                                        if (f.kind == FDSame && hide_same) continue;
                                        const char* tag; ImVec4 tc;
                                        switch (f.kind) {
                                            case FDText: tag = "text"; tc = col_text; break;
                                            case FDPath: tag = "PATH"; tc = col_path; break;
                                            case FDChanged: tag = "chg "; tc = ImVec4(0.95f,0.6f,0.3f,1); break;
                                            case FDAdd: tag = "add "; tc = col_add; break;
                                            case FDDel: tag = "del "; tc = col_del; break;
                                            default: tag = "same"; tc = col_same; break;
                                        }
                                        std::string prev = (f.kind == FDDel) ? f.snap_text : f.cur_text;
                                        for (char& c : prev) if (c == '\n') c = ' ';
                                        std::string label = std::string("[") + tag + "] " + prev +
                                                            "##fr" + std::to_string(rowid++);
                                        bool sel = f.cur_rec >= 0 && f.cur_rec == selected_record;
                                        ImGui::PushStyleColor(ImGuiCol_Text, tc);
                                        bool clicked = ImGui::Selectable(label.c_str(), sel);
                                        ImGui::PopStyleColor();
                                        if (clicked && f.cur_rec >= 0) select_record(f.cur_rec);
                                        if ((f.kind == FDText || f.kind == FDPath || f.kind == FDChanged) &&
                                            ImGui::IsItemHovered()) {
                                            ImGui::BeginTooltip();
                                            ImGui::TextDisabled("was:"); ImGui::TextUnformatted(f.snap_text.c_str());
                                            ImGui::TextDisabled("now:"); ImGui::TextUnformatted(f.cur_text.c_str());
                                            if (f.kind == FDPath) ImGui::TextColored(col_path, "(same text, different code path)");
                                            ImGui::EndTooltip();
                                        }
                                    }
                                }
                            } else {                                   // ---- line diff ----
                                auto sit = snapshots[diff_sel].frags.find(keyc);
                                if (sit == snapshots[diff_sel].frags.end()) {
                                    ImGui::TextDisabled("'%s' not present in %s", og.output.c_str(),
                                                        snapshots[diff_sel].label.c_str());
                                } else {
                                    std::string snap; for (auto& fi : sit->second) snap += fi.text;
                                    const std::string cur = reconstruct(records, og.recs);
                                    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
                                    bool in_block = false; int cur_line = 0;
                                    for (const DiffLine& d : diff_lines(split_lines(snap), split_lines(cur))) {
                                        const ImVec4 mc = (d.tag == '+') ? col_add : (d.tag == '-') ? col_del : col_same;
                                        ImGui::TextColored(mc, "%c ", d.tag);
                                        if (d.tag == '-') { ImGui::SameLine(0, 0); ImGui::TextColored(col_del, "%s", d.text.c_str()); }
                                        else if (cur_line < (int)lines.size()) {
                                            const Line& ln = lines[cur_line++];
                                            if (!ln.empty()) { ImGui::SameLine(0, 0); render_line(ln, in_block, d.tag == '+' ? &add_row_bg : nullptr); }
                                        }
                                    }
                                    ImGui::PopStyleVar();
                                }
                            }
                        }
                        ImGui::EndChild();

                        ImGui::SameLine();

                        // ============ RIGHT pane ============
                        ImGui::BeginChild("right", ImVec2(0, full_h), false);
                        {
                            const float trace_h = full_h * 0.42f;

                            ImGui::BeginChild("trace", ImVec2(0, trace_h), true);
                            if (!sel_in_group) {
                                ImGui::TextDisabled("Click a fragment on the left to see its stacktrace.");
                            } else {
                                const Record& r = records[selected_record];
                                ImGui::Text("Stacktrace for fragment id %llu",
                                            (unsigned long long)r.id);
                                if (reverse_enabled && !reverse_recs.empty()) {
                                    int here = 0; for (int gi : og.recs) if (reverse_recs.count(gi)) ++here;
                                    ImGui::TextColored(ImVec4(0.95f,0.7f,0.3f,1),
                                        "selected frame emitted %zu fragments (%d in this file)",
                                        reverse_recs.size(), here);
                                }
                                ImGui::Separator();
                                for (int fi : visible_frames(r)) {
                                    const Frame& f = r.trace[fi];
                                    char label[1024];
                                    if (!f.file.empty())
                                        std::snprintf(label, sizeof label, "%s  (%s:%d)##%d",
                                                      f.desc.c_str(), f.file.c_str(), f.line, fi);
                                    else
                                        std::snprintf(label, sizeof label, "%s##%d",
                                                      f.desc.empty() ? "<unknown>" : f.desc.c_str(), fi);
                                    if (ImGui::Selectable(label, fi == selected_frame))
                                        select_frame(selected_record, fi);
                                }
                            }
                            ImGui::EndChild();

                            ImGui::BeginChild("framesrc", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
                            const bool have_frame = sel_in_group && selected_frame >= 0 &&
                                selected_frame < (int)records[selected_record].trace.size();
                            if (!have_frame) {
                                ImGui::TextDisabled("Select a stack frame above.");
                            } else {
                                const Frame& f = records[selected_record].trace[selected_frame];
                                if (f.file.empty()) {
                                    ImGui::TextDisabled("No source location for this frame.");
                                } else {
                                    if (ImGui::SmallButton("Open in nvim"))
                                        last_cmd = run_cmd(nvim_command(nvim_sock, f.file, f.line));
                                    ImGui::SameLine(); ImGui::TextDisabled("%s:%d  via %s", f.file.c_str(), f.line, nvim_sock.c_str());
                                    ImGui::Separator();
                                    const FileSrc& fs = get_file(file_cache, f.file);
                                    if (!fs.ok) {
                                        ImGui::TextDisabled("Could not open %s", f.file.c_str());
                                    } else {
                                        ImDrawList* dl = ImGui::GetWindowDrawList();
                                        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
                                        const float line_h = ImGui::GetTextLineHeight();
                                        const float gutter_w = ImGui::CalcTextSize("0000  ").x;
                                        bool in_block = false;
                                        for (int li = 0; li < (int)fs.lines.size(); ++li) {
                                            const int lineno = li + 1;
                                            const bool target = (lineno == f.line);
                                            const ImVec2 pos = ImGui::GetCursorScreenPos();
                                            if (target) {
                                                const float tw = gutter_w + ImGui::CalcTextSize(fs.lines[li].c_str()).x;
                                                const float hl = std::max(ImGui::GetContentRegionAvail().x, tw);
                                                dl->AddRectFilled(pos, ImVec2(pos.x + hl, pos.y + line_h), line_bg);
                                            }
                                            ImGui::TextDisabled("%4d  ", lineno);
                                            ImGui::SameLine(0, 0);
                                            // syntax-highlight the compiler source too
                                            const std::string& src = fs.lines[li];
                                            bool firstpiece = true;
                                            int prev_in = in_block;
                                            for (const Span& sp : tokenize_cpp_line(src, in_block)) {
                                                if (!firstpiece) ImGui::SameLine(0, 0); firstpiece = false;
                                                ImGui::PushStyleColor(ImGuiCol_Text, tk_color(sp.kind));
                                                ImGui::TextUnformatted(src.substr(sp.start, sp.len).c_str());
                                                ImGui::PopStyleColor();
                                            }
                                            (void)prev_in;
                                            if (src.empty()) ImGui::NewLine();
                                            if (target && scroll_to_frame) ImGui::SetScrollHereY(0.4f);
                                        }
                                        ImGui::PopStyleVar();
                                        scroll_to_frame = false;
                                    }
                                }
                            }
                            ImGui::EndChild();
                        }
                        ImGui::EndChild();

                        ImGui::EndTabItem();   // output
                    }
                    ImGui::EndTabBar();
                }
                ImGui::PopID();
                ImGui::EndTabItem();   // input
            }
            ImGui::EndTabBar();
        }

        ImGui::End();

        ImGui::Render();
        int w, h; glfwGetFramebufferSize(window, &w, &h);
        glViewport(0, 0, w, h);
        glClearColor(0.10f, 0.10f, 0.12f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        glfwSwapBuffers(window);
    }

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}
