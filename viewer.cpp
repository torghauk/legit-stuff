// viewer.cpp — Dear ImGui frontend (format v1), built on the ingest model.
//
// Performance model: everything derived (reconstructed text, per-line block-
// comment state, the diff, the changed-file set) is cached and recomputed only
// when its inputs change (active file / snapshot / reloaded data). All long
// panes (generated source, diff, input, frame source, navigator) are rendered
// through ImGuiListClipper so cost scales with what's on screen, not file size.
//
// Layout:  [ navigator | document (Generated | Input) | stacktrace + frame ]
// CLI: ./viewer [run_dir] [run_cmd] [build_cmd] [editor_tmpl] [remap_from=to]

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include <GLFW/glfw3.h>

#include "ingest.hpp"
#include "syntax.hpp"
#include "diff.hpp"
#include "sources.hpp"
#include "proc.hpp"

using ingest::Record;

namespace {

struct Segment { int record; std::string text; };
using Line = std::vector<Segment>;

std::vector<Line> to_lines(const std::vector<Record>& recs, const std::vector<int>& idxs) {
    std::vector<Line> lines(1);
    for (int ri : idxs) {
        std::string cur;
        for (char c : recs[ri].text) {
            if (c == '\n') { if (!cur.empty()) lines.back().push_back({ri, cur}); cur.clear(); lines.emplace_back(); }
            else cur += c;
        }
        if (!cur.empty()) lines.back().push_back({ri, cur});
    }
    return lines;
}
std::string line_text(const Line& ln) { std::string t; for (auto& s : ln) t += s.text; return t; }
std::string lower(std::string s) { for (char& c : s) c = (char)std::tolower((unsigned char)c); return s; }
std::string snap_key(const std::string& p, const std::string& i, const std::string& o) { return p + "\x1f" + i + "\x1f" + o; }

// block-comment entry state for each line (so a clipped view can start any line correctly)
std::vector<char> block_states(const std::vector<std::string>& lines) {
    std::vector<char> v(lines.size()); bool ib = false;
    for (size_t i = 0; i < lines.size(); ++i) { v[i] = ib ? 1 : 0; std::string l = lines[i]; syntax::tokenize(l, ib); }
    return v;
}

} // namespace

int main(int argc, char** argv) {
    std::string dir = (argc > 1) ? argv[1] : (std::getenv("DIAG_DIR") ? std::getenv("DIAG_DIR") : ".diag");
    std::string run_cmd   = (argc > 2) ? argv[2] : "DIAG_DIR=" + dir + " DIAG_PACKAGE=core ./dummy_compiler hello.mylang math.mylang greet.mylang";
    std::string build_cmd = (argc > 3) ? argv[3] : "g++ -std=c++23 -g dummy_compiler.cpp -o dummy_compiler -lstdc++exp";
    std::string editor_tmpl = (argc > 4) ? argv[4] : "nvim --server /tmp/nvim.sock --remote-send '<C-\\><C-n>:edit +{line} {file}<CR>'";
    std::string remap_from, remap_to;
    if (argc > 5) { std::string r = argv[5]; auto eq = r.find('='); if (eq != std::string::npos) { remap_from = r.substr(0, eq); remap_to = r.substr(eq + 1); } }

    if (!glfwInit()) return 1;
    const char* glsl = "#version 130";
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3); glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
    GLFWwindow* window = glfwCreateWindow(1400, 860, "Diagnostics Viewer", nullptr, nullptr);
    if (!window) { glfwTerminate(); return 1; }
    glfwMakeContextCurrent(window); glfwSwapInterval(1);
    IMGUI_CHECKVERSION(); ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr; ImGui::StyleColorsDark();
    ImGui_ImplGlfw_InitForOpenGL(window, true); ImGui_ImplOpenGL3_Init(glsl);

    std::vector<Record> records = ingest::ingest_dir(dir);
    std::vector<ingest::PackageGroup> tree = ingest::build_tree(records);
    int data_gen = 0;

    sources::Cache srccache; srccache.set_remap(remap_from, remap_to);
    std::map<std::string, std::vector<char>> file_ib;     // block-state cache for on-disk files
    proc::Runner runner;

    // active document + its cached derivations
    std::vector<Line> lines; std::vector<char> doc_ib; std::string doc_text;
    int active_p = -1, active_i = -1, active_o = -1;
    int selected_record = -1, selected_frame = -1; bool scroll_to_frame = false;

    std::set<std::string> collapsed; char nav_filter[256] = {0}; bool changed_only = false;

    struct Snapshot { std::string label; std::map<std::string, std::vector<diffs::FragInfo>> frags; };
    std::vector<Snapshot> snapshots; int snap_counter = 0; int diff_sel = -1;
    bool trace_aware = false, hide_same = false;

    // diff cache (recomputed only when the signature below changes)
    int d_p=-2,d_i=-2,d_o=-2,d_diff=-2,d_gen=-2; bool d_ta=false,d_hs=false;
    bool d_present=false;
    std::vector<diffs::DiffLine> dc_lines; std::vector<int> dc_cur;     // line diff + map to `lines`
    std::vector<diffs::FragDiff> dc_frags; std::vector<int> dc_vis;     // frag diff + visible indices
    int dc_ct=0,dc_cp=0,dc_ca=0,dc_cd=0,dc_cc=0,dc_cs=0;

    // changed-file set cache (for "changed only" + the * markers)
    std::set<std::string> changed_set; int cs_diff=-2, cs_gen=-2;

    bool reverse_enabled = true; std::string reverse_desc; std::set<int> reverse_recs;
    bool watch = false; double last_check = 0; time_t dir_mtime = proc::mtime(dir);

    const ImU32 sel_bg=IM_COL32(70,120,200,120), hover_bg=IM_COL32(160,160,160,40);
    const ImU32 line_bg=IM_COL32(70,120,200,90), reverse_bg=IM_COL32(210,140,40,90), add_row=IM_COL32(60,130,60,45);
    const ImVec4 c_add(0.55f,0.95f,0.55f,1), c_del(1,0.5f,0.5f,1), c_same(0.6f,0.6f,0.6f,1);
    const ImVec4 c_text(0.92f,0.82f,0.3f,1), c_path(0.95f,0.5f,0.95f,1);

    auto cur_recs = [&]() -> const std::vector<int>& { static std::vector<int> e; return active_p<0?e:tree[active_p].inputs[active_i].outputs[active_o].recs; };
    auto active_pkg = [&]{ return active_p<0?std::string():tree[active_p].package; };
    auto active_in  = [&]{ return active_p<0?std::string():tree[active_p].inputs[active_i].input; };
    auto active_out = [&]{ return active_p<0?std::string():tree[active_p].inputs[active_i].outputs[active_o].output; };

    auto open_output = [&](int p, int i, int o) {
        active_p=p; active_i=i; active_o=o;
        lines = to_lines(records, tree[p].inputs[i].outputs[o].recs);
        std::vector<std::string> lt(lines.size()); for (size_t k=0;k<lines.size();++k) lt[k]=line_text(lines[k]);
        doc_ib = block_states(lt);
        doc_text = ingest::reconstruct(records, tree[p].inputs[i].outputs[o].recs);
        selected_record=selected_frame=-1; reverse_desc.clear(); reverse_recs.clear();
    };
    auto open_first = [&]{ if (!tree.empty() && !tree[0].inputs.empty() && !tree[0].inputs[0].outputs.empty()) open_output(0,0,0); };
    auto open_by_names = [&](const std::string& p,const std::string& i,const std::string& o){
        for (int a=0;a<(int)tree.size();++a) if(tree[a].package==p)
            for (int b=0;b<(int)tree[a].inputs.size();++b) if(tree[a].inputs[b].input==i)
                for (int c=0;c<(int)tree[a].inputs[b].outputs.size();++c) if(tree[a].inputs[b].outputs[c].output==o){ open_output(a,b,c); return; } };
    auto reload = [&]{
        std::string ap=active_pkg(), ai=active_in(), ao=active_out();
        records = ingest::ingest_dir(dir); tree = ingest::build_tree(records); ++data_gen;
        srccache.clear(); file_ib.clear();
        active_p=active_i=active_o=-1; lines.clear(); doc_ib.clear(); doc_text.clear();
        selected_record=selected_frame=-1; reverse_desc.clear(); reverse_recs.clear();
        dir_mtime = proc::mtime(dir);
        if (!ao.empty()) open_by_names(ap,ai,ao);
        if (active_p<0) open_first();
    };
    auto compute_reverse = [&](const std::string& desc){ reverse_desc=desc; reverse_recs.clear();
        for (int gi=0;gi<(int)records.size();++gi) for (auto& fr:records[gi].trace) if (fr.desc==desc){ reverse_recs.insert(gi); break; } };
    auto pick_frame = [&](int ri){ auto vf=diffs::visible_frames(records[ri]); int sf=vf.empty()?-1:vf.front();
        for (int k:vf) if(!records[ri].trace[k].file.empty()){ sf=k; break; } return sf; };
    auto select_record = [&](int ri){ selected_record=ri; selected_frame=pick_frame(ri); scroll_to_frame=true; };
    auto snapshot_now = [&]{ Snapshot s; s.label="run "+std::to_string(++snap_counter);
        for (auto& pg:tree) for (auto& ig:pg.inputs) for (auto& og:ig.outputs){ auto& v=s.frags[snap_key(pg.package,ig.input,og.output)];
            for (int gi:og.recs) v.push_back({records[gi].text, diffs::path_sig(records[gi])}); }
        snapshots.push_back(std::move(s)); };
    auto snap_text = [&](int snap,const std::string& key,bool& found)->std::string{ auto it=snapshots[snap].frags.find(key); found=it!=snapshots[snap].frags.end();
        std::string s; if(found) for(auto& f:it->second) s+=f.text; return s; };
    auto get_file_ib = [&](const std::string& path, const sources::File& f)->const std::vector<char>&{
        auto it=file_ib.find(path); if(it!=file_ib.end()) return it->second;
        return file_ib.emplace(path, block_states(f.lines)).first->second; };

    if (active_p<0) open_first();

    auto render_frag_line = [&](ImDrawList* dl, float lh, const Line& ln, bool ib, const ImU32* row_bg){
        std::string text; std::vector<int> rc; for (auto& sg:ln) for(char c:sg.text){ text+=c; rc.push_back(sg.record); }
        if (text.empty()) { ImGui::Dummy(ImVec2(0,lh)); return; }
        ImVec2 ls=ImGui::GetCursorScreenPos();
        if (row_bg) dl->AddRectFilled(ls, ImVec2(ls.x+ImGui::GetContentRegionAvail().x, ls.y+lh), *row_bg);
        bool first=true;
        for (auto& sp:syntax::tokenize(text, ib)) { int k=sp.start,e=sp.start+sp.len;
            while(k<e){ int rec=rc[k],j=k; while(j<e&&rc[j]==rec)++j; std::string pc=text.substr(k,j-k);
                if(!first) ImGui::SameLine(0,0); first=false;
                ImVec2 p=ImGui::GetCursorScreenPos(); float w=ImGui::CalcTextSize(pc.c_str()).x;
                if(reverse_enabled&&reverse_recs.count(rec)) dl->AddRectFilled(p,ImVec2(p.x+w,p.y+lh),reverse_bg);
                if(rec==selected_record) dl->AddRectFilled(p,ImVec2(p.x+w,p.y+lh),sel_bg);
                ImGui::PushStyleColor(ImGuiCol_Text, syntax::color(sp.kind)); ImGui::TextUnformatted(pc.c_str()); ImGui::PopStyleColor();
                if(ImGui::IsItemHovered()){ dl->AddRectFilled(p,ImVec2(p.x+w,p.y+lh),hover_bg); if(ImGui::IsMouseClicked(ImGuiMouseButton_Left)) select_record(rec); }
                k=j; } }
    };
    auto render_syntax_line = [&](const std::string& s, bool ib){ if(s.empty()){ImGui::NewLine();return;} bool first=true;
        for (auto& sp:syntax::tokenize(s, ib)){ if(!first)ImGui::SameLine(0,0); first=false;
            ImGui::PushStyleColor(ImGuiCol_Text, syntax::color(sp.kind)); ImGui::TextUnformatted(s.substr(sp.start,sp.len).c_str()); ImGui::PopStyleColor(); } };

    while (!glfwWindowShouldClose(window)) {
        if (runner.take_done() && runner.reload_after()) reload();
        if (watch) { double t=glfwGetTime(); if(t-last_check>0.5){ last_check=t; time_t m=proc::mtime(dir); if(m&&m!=dir_mtime) reload(); } }

        glfwPollEvents(); ImGui_ImplOpenGL3_NewFrame(); ImGui_ImplGlfw_NewFrame(); ImGui::NewFrame();
        const ImGuiViewport* vp=ImGui::GetMainViewport(); ImGui::SetNextWindowPos(vp->WorkPos); ImGui::SetNextWindowSize(vp->WorkSize);
        ImGui::Begin("root", nullptr, ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoResize|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoCollapse);

        // -------- toolbar --------
        const bool busy=runner.running();
        if (ImGui::Button("Reload")) reload();
        ImGui::SameLine(); ImGui::BeginDisabled(busy);
        if (ImGui::Button("Recompile")) runner.start("recompile", build_cmd, false);
        ImGui::SameLine();
        if (ImGui::Button("Run")) { std::error_code ec; for (auto& e:std::filesystem::directory_iterator(dir,ec)) if(e.path().extension()==".jsonl") std::filesystem::remove(e.path(),ec); runner.start("run", run_cmd, true); }
        ImGui::EndDisabled();
        ImGui::SameLine(); if (ImGui::Button("Snapshot")) snapshot_now();
        ImGui::SameLine(); ImGui::SetNextItemWidth(150);
        const char* dpre=diff_sel<0?"(none)":snapshots[diff_sel].label.c_str();
        if (ImGui::BeginCombo("Diff vs", dpre)) { if(ImGui::Selectable("(none)",diff_sel<0))diff_sel=-1;
            for(int s=0;s<(int)snapshots.size();++s) if(ImGui::Selectable(snapshots[s].label.c_str(),diff_sel==s))diff_sel=s; ImGui::EndCombo(); }
        ImGui::SameLine(); ImGui::Checkbox("Watch",&watch);
        ImGui::SameLine(); ImGui::Checkbox("Highlight frame fragments",&reverse_enabled);
        ImGui::Text("dir: %s    records: %zu    packages: %zu", dir.c_str(), records.size(), tree.size());
        if (busy){ ImGui::SameLine(); ImGui::TextColored(ImVec4(0.9f,0.8f,0.3f,1),"   %s running...", runner.label().c_str()); }
        else { int ec=runner.exit_code(); if(ec>=0){ ImGui::SameLine(); ImGui::TextColored(ec==0?c_add:c_del,"   last: exit %d", ec); } }
        if (ImGui::CollapsingHeader("Command output")) { ImGui::BeginChild("cmdout",ImVec2(0,110),true,ImGuiWindowFlags_HorizontalScrollbar);
            std::string o=runner.output(); if(o.empty())ImGui::TextDisabled("(no command run yet)"); else ImGui::TextUnformatted(o.c_str()); ImGui::EndChild(); }
        ImGui::Separator();

        const bool diff_active = diff_sel>=0;

        // ---- recompute changed-file set only when the snapshot or data changes ----
        if (diff_sel!=cs_diff || data_gen!=cs_gen) {
            cs_diff=diff_sel; cs_gen=data_gen; changed_set.clear();
            if (diff_active) for (auto& pg:tree) for (auto& ig:pg.inputs) for (auto& og:ig.outputs) {
                std::string key=snap_key(pg.package,ig.input,og.output); bool found; std::string st=snap_text(diff_sel,key,found);
                std::string cur=ingest::reconstruct(records,og.recs); if(!found||st!=cur) changed_set.insert(key); }
        }

        const float full_h=ImGui::GetContentRegionAvail().y;
        const float nav_w=280, right_w=(ImGui::GetContentRegionAvail().x-nav_w)*0.32f;

        // ================= NAVIGATOR =================
        ImGui::BeginChild("nav", ImVec2(nav_w, full_h), true);
        {
            ImGui::SetNextItemWidth(-1); ImGui::InputTextWithHint("##filter","filter files...",nav_filter,sizeof nav_filter);
            if (diff_active) ImGui::Checkbox("changed only",&changed_only);
            ImGui::Separator();
            std::string fl=lower(nav_filter);
            auto match=[&](const std::string& s){ return fl.empty()||lower(s).find(fl)!=std::string::npos; };
            struct Row { int kind,p,i,o; std::string label; bool chg; };
            std::vector<Row> rows;
            for (int p=0;p<(int)tree.size();++p) {
                bool pcol=collapsed.count("p"+std::to_string(p))&&fl.empty()&&!changed_only;
                std::vector<Row> kids; bool pkg_any=false;
                for (int i=0;i<(int)tree[p].inputs.size();++i){ bool icol=collapsed.count("p"+std::to_string(p)+"i"+std::to_string(i))&&fl.empty()&&!changed_only;
                    std::vector<Row> outs; bool in_any=false;
                    for (int o=0;o<(int)tree[p].inputs[i].outputs.size();++o){ const auto& og=tree[p].inputs[i].outputs[o];
                        bool ch=diff_active&&changed_set.count(snap_key(tree[p].package,tree[p].inputs[i].input,og.output));
                        if(!(match(og.output)||match(tree[p].inputs[i].input)||match(tree[p].package))) continue;
                        if(changed_only&&diff_active&&!ch) continue; in_any=true; outs.push_back({2,p,i,o,og.output,ch}); }
                    if(!in_any) continue; pkg_any=true; kids.push_back({1,p,i,-1,tree[p].inputs[i].input,false});
                    if(!icol) for(auto& r:outs) kids.push_back(r); }
                if(!pkg_any) continue; rows.push_back({0,p,-1,-1,tree[p].package.empty()?"(no package)":tree[p].package,false});
                if(!pcol) for(auto& r:kids) rows.push_back(r);
            }
            ImGuiListClipper clip; clip.Begin((int)rows.size());
            while (clip.Step()) for (int n=clip.DisplayStart;n<clip.DisplayEnd;++n) { const Row& r=rows[n]; ImGui::PushID(n);
                if (r.kind==0){ bool col=collapsed.count("p"+std::to_string(r.p)); std::string l=std::string(col?"[+] ":"[-] ")+r.label;
                    if(ImGui::Selectable(l.c_str(),false)){ std::string k="p"+std::to_string(r.p); if(col)collapsed.erase(k);else collapsed.insert(k); } }
                else if (r.kind==1){ ImGui::Indent(12); bool col=collapsed.count("p"+std::to_string(r.p)+"i"+std::to_string(r.i)); std::string l=std::string(col?"[+] ":"[-] ")+r.label;
                    if(ImGui::Selectable(l.c_str(),false)){ std::string k="p"+std::to_string(r.p)+"i"+std::to_string(r.i); if(col)collapsed.erase(k);else collapsed.insert(k); } ImGui::Unindent(12); }
                else { ImGui::Indent(28); bool sel=(r.p==active_p&&r.i==active_i&&r.o==active_o); std::string l=r.label+(r.chg?"  *":"");
                    if(r.chg)ImGui::PushStyleColor(ImGuiCol_Text,c_text); if(ImGui::Selectable(l.c_str(),sel)) open_output(r.p,r.i,r.o); if(r.chg)ImGui::PopStyleColor(); ImGui::Unindent(28); }
                ImGui::PopID(); }
        }
        ImGui::EndChild(); ImGui::SameLine();

        // ================= DOCUMENT =================
        ImGui::BeginChild("doc", ImVec2(ImGui::GetContentRegionAvail().x-right_w, full_h), false);
        if (active_p<0) ImGui::TextDisabled("Select an output file in the navigator.");
        else if (ImGui::BeginTabBar("doctabs")) {
            const std::string keyc=snap_key(active_pkg(),active_in(),active_out());

            // ---- recompute the diff cache only when its inputs change ----
            if (active_p!=d_p||active_i!=d_i||active_o!=d_o||diff_sel!=d_diff||data_gen!=d_gen||trace_aware!=d_ta||hide_same!=d_hs) {
                d_p=active_p;d_i=active_i;d_o=active_o;d_diff=diff_sel;d_gen=data_gen;d_ta=trace_aware;d_hs=hide_same;
                dc_lines.clear(); dc_cur.clear(); dc_frags.clear(); dc_vis.clear(); d_present=false;
                if (diff_active) { bool found; std::string snap=snap_text(diff_sel,keyc,found); d_present=found;
                    if (found) {
                        if (trace_aware) { std::vector<diffs::FragCur> cur; for(int gi:cur_recs()) cur.push_back({gi,records[gi].text,diffs::path_sig(records[gi])});
                            dc_frags=diffs::frag_diff(snapshots[diff_sel].frags[keyc],cur);
                            dc_ct=dc_cp=dc_ca=dc_cd=dc_cc=dc_cs=0;
                            for (int k=0;k<(int)dc_frags.size();++k){ auto kd=dc_frags[k].kind;
                                switch(kd){case diffs::FDText:++dc_ct;break;case diffs::FDPath:++dc_cp;break;case diffs::FDAdd:++dc_ca;break;case diffs::FDDel:++dc_cd;break;case diffs::FDChanged:++dc_cc;break;default:++dc_cs;}
                                if(!(kd==diffs::FDSame&&hide_same)) dc_vis.push_back(k); }
                        } else { dc_lines=diffs::line_diff(diffs::split_lines(snap),diffs::split_lines(doc_text));
                            dc_cur.resize(dc_lines.size()); int cl=0;
                            for (int k=0;k<(int)dc_lines.size();++k){ if(dc_lines[k].tag=='-') dc_cur[k]=-1; else { dc_cur[k]=(cl<(int)lines.size())?cl:-1; ++cl; } } }
                    }
                }
            }

            if (ImGui::BeginTabItem("Generated")) {
                if (diff_active){ ImGui::TextDisabled("%s -> %s   diff vs %s",active_in().c_str(),active_out().c_str(),snapshots[diff_sel].label.c_str());
                    ImGui::SameLine(); ImGui::Checkbox("Trace-aware",&trace_aware); if(trace_aware){ImGui::SameLine();ImGui::Checkbox("Hide unchanged",&hide_same);} }
                else ImGui::TextDisabled("%s -> %s",active_in().c_str(),active_out().c_str());
                ImGui::BeginChild("gen",ImVec2(0,0),true,ImGuiWindowFlags_HorizontalScrollbar);
                ImDrawList* dl=ImGui::GetWindowDrawList(); float lh=ImGui::GetTextLineHeight();
                ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing,ImVec2(0,0));
                if (!diff_active) {
                    ImGuiListClipper clip; clip.Begin((int)lines.size(), lh);
                    while(clip.Step()) for(int i=clip.DisplayStart;i<clip.DisplayEnd;++i) render_frag_line(dl,lh,lines[i],doc_ib[i]!=0,nullptr);
                } else if (!d_present) { ImGui::TextDisabled("not present in %s",snapshots[diff_sel].label.c_str()); }
                else if (trace_aware) {
                    ImGui::PopStyleVar();
                    ImGui::Text("%d text, %d PATH, %d added, %d removed, %d changed; %d unchanged",dc_ct,dc_cp,dc_ca,dc_cd,dc_cc,dc_cs); ImGui::Separator();
                    ImGuiListClipper clip; clip.Begin((int)dc_vis.size());
                    while(clip.Step()) for(int n=clip.DisplayStart;n<clip.DisplayEnd;++n){ const auto& f=dc_frags[dc_vis[n]];
                        const char* tg; ImVec4 tc; switch(f.kind){case diffs::FDText:tg="text";tc=c_text;break;case diffs::FDPath:tg="PATH";tc=c_path;break;
                            case diffs::FDChanged:tg="chg ";tc=ImVec4(0.95f,0.6f,0.3f,1);break;case diffs::FDAdd:tg="add ";tc=c_add;break;case diffs::FDDel:tg="del ";tc=c_del;break;default:tg="same";tc=c_same;break;}
                        std::string pv=(f.kind==diffs::FDDel)?f.snap_text:f.cur_text; for(char&c:pv) if(c=='\n')c=' ';
                        ImGui::PushStyleColor(ImGuiCol_Text,tc); bool cl=ImGui::Selectable((std::string("[")+tg+"] "+pv+"##r"+std::to_string(dc_vis[n])).c_str(), f.cur_rec>=0&&f.cur_rec==selected_record); ImGui::PopStyleColor();
                        if(cl&&f.cur_rec>=0) select_record(f.cur_rec);
                        if((f.kind==diffs::FDText||f.kind==diffs::FDPath||f.kind==diffs::FDChanged)&&ImGui::IsItemHovered()){ ImGui::BeginTooltip();
                            ImGui::TextDisabled("was:");ImGui::TextUnformatted(f.snap_text.c_str());ImGui::TextDisabled("now:");ImGui::TextUnformatted(f.cur_text.c_str());
                            if(f.kind==diffs::FDPath)ImGui::TextColored(c_path,"(same text, different code path)"); ImGui::EndTooltip(); } }
                    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing,ImVec2(0,0)); // balance pop below
                } else {
                    ImGuiListClipper clip; clip.Begin((int)dc_lines.size(), lh);
                    while(clip.Step()) for(int i=clip.DisplayStart;i<clip.DisplayEnd;++i){ const auto& d=dc_lines[i];
                        ImVec4 mc=d.tag=='+'?c_add:d.tag=='-'?c_del:c_same; ImGui::TextColored(mc,"%c ",d.tag);
                        if(d.tag=='-'){ ImGui::SameLine(0,0); ImGui::TextColored(c_del,"%s",d.text.c_str()); }
                        else { int ci=dc_cur[i]; if(ci>=0&&!lines[ci].empty()){ ImGui::SameLine(0,0); render_frag_line(dl,lh,lines[ci],doc_ib[ci]!=0,d.tag=='+'?&add_row:nullptr); } } }
                }
                ImGui::PopStyleVar();
                ImGui::EndChild(); ImGui::EndTabItem();
            }
            if (ImGui::BeginTabItem("Input")) {
                ImGui::TextDisabled("%s",active_in().c_str());
                ImGui::BeginChild("inp",ImVec2(0,0),true,ImGuiWindowFlags_HorizontalScrollbar);
                const sources::File& f=srccache.get(active_in());
                if(!f.ok) ImGui::TextDisabled("Could not open input file '%s'",active_in().c_str());
                else { const auto& ibv=get_file_ib(active_in(),f); ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing,ImVec2(0,0));
                    ImGuiListClipper clip; clip.Begin((int)f.lines.size(), ImGui::GetTextLineHeight());
                    while(clip.Step()) for(int i=clip.DisplayStart;i<clip.DisplayEnd;++i) render_syntax_line(f.lines[i], ibv[i]!=0);
                    ImGui::PopStyleVar(); }
                ImGui::EndChild(); ImGui::EndTabItem();
            }
            ImGui::EndTabBar();
        }
        ImGui::EndChild(); ImGui::SameLine();

        // ================= STACKTRACE + FRAME =================
        ImGui::BeginChild("right", ImVec2(0,full_h), false);
        {
            const bool sel_ok=selected_record>=0;
            ImGui::BeginChild("trace",ImVec2(0,full_h*0.42f),true);
            if(!sel_ok) ImGui::TextDisabled("Click a fragment to see its stacktrace.");
            else { const Record& r=records[selected_record]; ImGui::Text("Stacktrace for write seq %llu",(unsigned long long)r.seq);
                if(reverse_enabled&&!reverse_recs.empty()){ int here=0; for(int gi:cur_recs()) if(reverse_recs.count(gi))++here;
                    ImGui::TextColored(ImVec4(0.95f,0.7f,0.3f,1),"frame emitted %zu fragments (%d here)",reverse_recs.size(),here); }
                ImGui::Separator();
                for(int fi:diffs::visible_frames(r)){ const ingest::Frame& f=r.trace[fi]; char lbl[1024];
                    if(!f.file.empty()) std::snprintf(lbl,sizeof lbl,"%s  (%s:%d)##%d",f.desc.c_str(),f.file.c_str(),f.line,fi);
                    else std::snprintf(lbl,sizeof lbl,"%s##%d",f.desc.empty()?"<unknown>":f.desc.c_str(),fi);
                    if(ImGui::Selectable(lbl,fi==selected_frame)){ selected_frame=fi; scroll_to_frame=true; compute_reverse(f.desc); } } }
            ImGui::EndChild();

            ImGui::BeginChild("framesrc",ImVec2(0,0),true,ImGuiWindowFlags_HorizontalScrollbar);
            bool have=sel_ok&&selected_frame>=0&&selected_frame<(int)records[selected_record].trace.size();
            if(!have) ImGui::TextDisabled("Select a stack frame above.");
            else { const ingest::Frame& f=records[selected_record].trace[selected_frame];
                if(f.file.empty()) ImGui::TextDisabled("No source location for this frame.");
                else { if(ImGui::SmallButton("Open in editor")) runner.start("editor", proc::expand(editor_tmpl,f.file,f.line), false);
                    ImGui::SameLine(); ImGui::TextDisabled("%s:%d",f.file.c_str(),f.line); ImGui::Separator();
                    const sources::File& fs=srccache.get(f.file);
                    if(!fs.ok) ImGui::TextDisabled("Could not open %s (try a remap_from=to arg)",f.file.c_str());
                    else { ImDrawList* dl=ImGui::GetWindowDrawList(); float lh=ImGui::GetTextLineHeight(); float vh=ImGui::GetContentRegionAvail().y;
                        const auto& ibv=get_file_ib(f.file,fs);
                        if(scroll_to_frame) ImGui::SetScrollY(std::max(0.0f,(f.line-1)*lh - vh*0.4f));
                        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing,ImVec2(0,0));
                        ImGuiListClipper clip; clip.Begin((int)fs.lines.size(), lh);
                        while(clip.Step()) for(int i=clip.DisplayStart;i<clip.DisplayEnd;++i){ bool target=(i+1==f.line); ImVec2 pos=ImGui::GetCursorScreenPos();
                            if(target){ float w=ImGui::CalcTextSize("0000  ").x+ImGui::CalcTextSize(fs.lines[i].c_str()).x;
                                dl->AddRectFilled(pos,ImVec2(pos.x+std::max(ImGui::GetContentRegionAvail().x,w),pos.y+lh),line_bg); scroll_to_frame=false; }
                            ImGui::TextDisabled("%4d  ",i+1); ImGui::SameLine(0,0); render_syntax_line(fs.lines[i], ibv[i]!=0); }
                        ImGui::PopStyleVar(); } } }
            ImGui::EndChild();
        }
        ImGui::EndChild();

        ImGui::End(); ImGui::Render();
        int w,h; glfwGetFramebufferSize(window,&w,&h); glViewport(0,0,w,h); glClearColor(0.1f,0.1f,0.12f,1); glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData()); glfwSwapBuffers(window);
    }
    ImGui_ImplOpenGL3_Shutdown(); ImGui_ImplGlfw_Shutdown(); ImGui::DestroyContext(); glfwDestroyWindow(window); glfwTerminate(); return 0;
}
