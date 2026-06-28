// dummy_compiler.cpp — reference producer for format v1.
//
// Models a compiler whose write points do NOT know the file: input is announced
// in the loop over inputs, output is announced before each output is generated,
// and writes carry only text + stacktrace. The same diag::Sink API also serves
// a compiler that does know the files (it just calls set_input/set_output
// inline).
//
// Build: g++ -std=c++23 -g dummy_compiler.cpp -o dummy_compiler -lstdc++exp
// Run (the build system sets these per package/run):
//   DIAG_DIR=run1 DIAG_PACKAGE=core ./dummy_compiler hello.mylang math.mylang

#include <string>
#include <string_view>
#include <vector>

#include "diag.hpp"

class Compiler {
public:
  explicit Compiler(diag::Sink &sink) : sink_(sink) {}

  // The "convenient point that loops over input files".
  void compile(const std::string &input) {
    sink_.set_input(input);
    const std::string b = base(input);
    if (input.find("math") != std::string::npos)
      gen_math(b);
    else if (input.find("greet") != std::string::npos)
      gen_greet(b);
    else
      gen_hello(b);
  }

private:
  void w(std::string_view t) { sink_.write(t); }
  static std::string base(const std::string &f) {
    auto p = f.rfind('.');
    return p == std::string::npos ? f : f.substr(0, p);
  }

  // one input -> one output
  void gen_hello(const std::string &b) {
    sink_.set_output(b + ".cpp"); // announced before generation begins
    w("#include <iostream>\n#include <vector>\n");
    emit_main();
  }
  void emit_main() {
    emit_sig("main");
    emit_body();
    emit_close();
  }
  void emit_sig(std::string_view n) { w("int " + std::string(n) + "() {"); }
  void emit_body() {
    emit_decls();
    emit_loop();
  }
  void emit_decls() {
    w("\n    int a = 1;\n    int b = 2;\n    int sum = a + b;\n");
  }
  void emit_loop() {
    w("    for (int i = 0; i < 10; ++i) {\n");
    w("        sum += i;\n");
    w("    }\n");
  }
  void emit_close() { w("\n    return sum;\n}\n"); }

  // one input -> TWO outputs (header + impl)
  void gen_math(const std::string &b) {
    sink_.set_output(b + ".h");
    w("#pragma once\n#include <cstdint>\n\n");
    emit_decl("add");
    emit_decl("mul");
    sink_.set_output(b + ".cpp");
    w("#include \"" + b + ".h\"\n\n");
    emit_fn("add", "x + y");
    emit_fn("mul", "x * y");
  }
  void emit_decl(std::string_view n) {
    w("std::int64_t " + std::string(n) + "(std::int64_t x, std::int64_t y);\n");
  }
  void emit_fn(std::string_view n, std::string_view e) {
    w("std::int64_t " + std::string(n) +
      "(std::int64_t x, std::int64_t y) {\n");
    w("    return " + std::string(e) + ";\n");
    w("}\n\n");
  }

  void gen_greet(const std::string &b) {
    sink_.set_output(b + ".cpp");
    w("#include <iostream>\n#include <string>\n\n");
    w("void greet(const std::string& who) {");
    w("\n    std::cout << \"Hello, \" << who << \"!\\n\";\n");
    w("}\n");
  }

  diag::Sink &sink_;
};

int main(int argc, char **argv) {
  diag::Sink sink(
      "dummyc"); // tool name; $DIAG_DIR / $DIAG_PACKAGE come from env
  Compiler cc(sink);

  std::vector<std::string> inputs;
  for (int i = 1; i < argc; ++i)
    inputs.emplace_back(argv[i]);
  if (inputs.empty())
    inputs = {"hello.mylang", "math.mylang", "greet.mylang"};

  for (const auto &in : inputs)
    cc.compile(in);
  return 0;
}
