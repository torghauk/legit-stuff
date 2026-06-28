// syntax.hpp — minimal C++ line tokenizer for highlighting.
#pragma once
#include <cctype>
#include <set>
#include <string>
#include <vector>
#include "imgui.h"

namespace syntax {

enum Tk { Default, Keyword, Type, String, Char, Number, Comment, Preproc, Punct };
struct Span { int start; int len; Tk kind; };

inline ImU32 color(Tk k) {
    switch (k) {
        case Keyword: return IM_COL32(197, 134, 192, 255);
        case Type:    return IM_COL32( 78, 201, 176, 255);
        case String:  return IM_COL32(206, 145, 120, 255);
        case Char:    return IM_COL32(206, 145, 120, 255);
        case Number:  return IM_COL32(181, 206, 168, 255);
        case Comment: return IM_COL32(106, 153,  85, 255);
        case Preproc: return IM_COL32(155, 155, 255, 255);
        default:      return IM_COL32(212, 212, 212, 255);
    }
}
inline bool id0(char c) { return std::isalpha((unsigned char)c) || c == '_'; }
inline bool idc(char c) { return std::isalnum((unsigned char)c) || c == '_'; }

inline const std::set<std::string>& keywords() {
    static const std::set<std::string> k = {
        "alignas","alignof","auto","break","case","catch","class","const","constexpr","continue",
        "decltype","default","delete","do","else","enum","explicit","export","extern","false","for",
        "friend","goto","if","inline","mutable","namespace","new","noexcept","nullptr","operator",
        "override","private","protected","public","return","sizeof","static","struct","switch",
        "template","this","throw","true","try","typedef","typename","union","using","virtual","volatile","while" };
    return k;
}
inline const std::set<std::string>& types() {
    static const std::set<std::string> t = {
        "bool","char","double","float","int","long","short","signed","unsigned","void","size_t",
        "int8_t","int16_t","int32_t","int64_t","uint8_t","uint16_t","uint32_t","uint64_t",
        "std","string","string_view","vector" };
    return t;
}

// Tokenize one line; `in_block` carries /* */ state across lines.
inline std::vector<Span> tokenize(const std::string& s, bool& in_block) {
    std::vector<Span> out; const int n = (int)s.size(); int i = 0;
    while (i < n) {
        if (in_block) { int st = i;
            while (i < n) { if (s[i]=='*'&&i+1<n&&s[i+1]=='/'){i+=2;in_block=false;break;} ++i; }
            out.push_back({st, i-st, Comment}); continue; }
        char c = s[i];
        if (c==' '||c=='\t') { int st=i; while(i<n&&(s[i]==' '||s[i]=='\t'))++i; out.push_back({st,i-st,Default}); continue; }
        if (c=='/'&&i+1<n&&s[i+1]=='/') { out.push_back({i,n-i,Comment}); i=n; continue; }
        if (c=='/'&&i+1<n&&s[i+1]=='*') { int st=i; i+=2; in_block=true;
            while(i<n){ if(s[i]=='*'&&i+1<n&&s[i+1]=='/'){i+=2;in_block=false;break;} ++i; }
            out.push_back({st,i-st,Comment}); continue; }
        if (c=='"'||c=='\'') { char q=c; int st=i; ++i;
            while(i<n){ if(s[i]=='\\'){i+=2;continue;} if(s[i]==q){++i;break;} ++i; }
            out.push_back({st,i-st, q=='"'?String:Char}); continue; }
        if (c=='#') { int st=i; ++i; while(i<n&&idc(s[i]))++i; out.push_back({st,i-st,Preproc}); continue; }
        if (std::isdigit((unsigned char)c)||(c=='.'&&i+1<n&&std::isdigit((unsigned char)s[i+1]))) {
            int st=i; while(i<n&&(idc(s[i])||s[i]=='.'))++i; out.push_back({st,i-st,Number}); continue; }
        if (id0(c)) { int st=i; while(i<n&&idc(s[i]))++i; std::string w=s.substr(st,i-st);
            Tk k = keywords().count(w)?Keyword: types().count(w)?Type:Default; out.push_back({st,i-st,k}); continue; }
        out.push_back({i,1,Punct}); ++i;
    }
    return out;
}

} // namespace syntax
