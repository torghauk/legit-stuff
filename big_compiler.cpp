#include "diag.hpp"
#include <string>
static diag::Sink* g;
static void emit_line(const std::string& s) { g->write(s); }      // top visible frame
static void emit_fn(int i) {
    emit_line("int fn_" + std::to_string(i) + "(int x) {\n");
    emit_line("    // function number " + std::to_string(i) + "\n");
    for (int k = 0; k < 8; ++k)
        emit_line("    x += " + std::to_string(k) + " * " + std::to_string(i) + ";\n");
    emit_line("    return x;\n");
    emit_line("}\n\n");
}
int main() {
    diag::Sink sink("bigc"); g = &sink;
    sink.set_input("big.mylang");
    sink.set_output("big.cpp");
    sink.write("#include <cstdint>\n");
    sink.write("/* generated file\n   spanning several\n   comment lines */\n");
    for (int i = 0; i < 300; ++i) emit_fn(i);
}
