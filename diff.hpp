// diff.hpp — line diff, trace-aware fragment diff, and trace helpers.
#pragma once
#include <algorithm>
#include <string>
#include <vector>
#include "ingest.hpp"

namespace diffs {

using ingest::Record;

// Frames worth showing: drop the write point and stop after main.
inline std::vector<int> visible_frames(const Record& r) {
    std::vector<int> v;
    for (int i = 0; i < (int)r.trace.size(); ++i) {
        const std::string& d = r.trace[i].desc;
        if (d.find("::w(") != std::string::npos || d.find("write_code") != std::string::npos) continue;
        v.push_back(i);
        if (d == "main") break;
    }
    return v;
}
inline std::string path_sig(const Record& r) {
    std::string s; for (int i : visible_frames(r)) { if(!s.empty()) s+='\n'; s += r.trace[i].desc; } return s;
}

struct DiffLine { char tag; std::string text; };
inline std::vector<DiffLine> line_diff(const std::vector<std::string>& a, const std::vector<std::string>& b) {
    const int n=(int)a.size(), m=(int)b.size();
    std::vector<std::vector<int>> dp(n+1, std::vector<int>(m+1,0));
    for(int i=n-1;i>=0;--i)for(int j=m-1;j>=0;--j)
        dp[i][j]=(a[i]==b[j])?dp[i+1][j+1]+1:std::max(dp[i+1][j],dp[i][j+1]);
    std::vector<DiffLine> o; int i=0,j=0;
    while(i<n&&j<m){ if(a[i]==b[j]){o.push_back({' ',a[i]});++i;++j;}
        else if(dp[i+1][j]>=dp[i][j+1]){o.push_back({'-',a[i]});++i;}
        else{o.push_back({'+',b[j]});++j;} }
    while(i<n)o.push_back({'-',a[i++]}); while(j<m)o.push_back({'+',b[j++]}); return o;
}

struct FragInfo { std::string text; std::string sig; };
struct FragCur  { int rec; std::string text; std::string sig; };
enum FDKind { FDSame, FDText, FDPath, FDChanged, FDAdd, FDDel };
struct FragDiff { FDKind kind; int cur_rec; std::string snap_text; std::string cur_text; };

inline std::vector<FragDiff> frag_diff(const std::vector<FragInfo>& S, const std::vector<FragCur>& C) {
    const int n=(int)S.size(), m=(int)C.size();
    auto eq=[&](int i,int j){ return S[i].text==C[j].text && S[i].sig==C[j].sig; };
    std::vector<std::vector<int>> dp(n+1, std::vector<int>(m+1,0));
    for(int i=n-1;i>=0;--i)for(int j=m-1;j>=0;--j)
        dp[i][j]=eq(i,j)?dp[i+1][j+1]+1:std::max(dp[i+1][j],dp[i][j+1]);
    std::vector<FragDiff> out; std::vector<int> dels, adds;
    auto flush=[&]{
        std::vector<char> du(dels.size(),0), au(adds.size(),0);
        for(size_t a=0;a<adds.size();++a) for(size_t d=0;d<dels.size();++d)
            if(!au[a]&&!du[d]&&S[dels[d]].sig==C[adds[a]].sig){ out.push_back({FDText,C[adds[a]].rec,S[dels[d]].text,C[adds[a]].text}); au[a]=du[d]=1; break; }
        for(size_t a=0;a<adds.size();++a) if(!au[a]) for(size_t d=0;d<dels.size();++d)
            if(!du[d]&&S[dels[d]].text==C[adds[a]].text){ out.push_back({FDPath,C[adds[a]].rec,S[dels[d]].text,C[adds[a]].text}); au[a]=du[d]=1; break; }
        size_t da=0;
        for(size_t a=0;a<adds.size();++a){ if(au[a])continue; while(da<dels.size()&&du[da])++da;
            if(da<dels.size()){ out.push_back({FDChanged,C[adds[a]].rec,S[dels[da]].text,C[adds[a]].text}); au[a]=du[da]=1; } }
        for(size_t d=0;d<dels.size();++d) if(!du[d]) out.push_back({FDDel,-1,S[dels[d]].text,""});
        for(size_t a=0;a<adds.size();++a) if(!au[a]) out.push_back({FDAdd,C[adds[a]].rec,"",C[adds[a]].text});
        dels.clear(); adds.clear();
    };
    int i=0,j=0;
    while(i<n&&j<m){ if(eq(i,j)){ if(!dels.empty()||!adds.empty())flush(); out.push_back({FDSame,C[j].rec,S[i].text,C[j].text}); ++i;++j; }
        else if(dp[i+1][j]>=dp[i][j+1]) dels.push_back(i++); else adds.push_back(j++); }
    while(i<n)dels.push_back(i++); while(j<m)adds.push_back(j++);
    if(!dels.empty()||!adds.empty())flush(); return out;
}

inline std::vector<std::string> split_lines(const std::string& s) {
    std::vector<std::string> o; std::string c;
    for(char ch:s){ if(ch=='\n'){o.push_back(c);c.clear();} else c+=ch; } o.push_back(c); return o;
}

} // namespace diffs
