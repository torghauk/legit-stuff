// dummy_compiler.cpp — drives diag::Sink::emit for several translation units.
// Some inputs produce MORE THAN ONE output (e.g. math.mylang -> math.h +
// math.cpp). Distinct call paths per unit make the captured stacktraces differ.
// The write point only emits; it does NOT write the "real" output.
//
// Each run overwrites compile.jsonl (truncate) so successive runs can be
// snapshotted and diffed in the viewer.
//
// Build (GCC 14+; GCC 13 on Ubuntu 24.04 also works):
//   g++ -std=c++23 -g -I<nlohmann_include> dummy_compiler.cpp -o dummy_compiler
//   -lstdc++exp

#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <string_view>
#include <utility>

#include "diag.hpp"

class Compiler {
public:
  explicit Compiler(diag::Sink &sink) : sink_(sink) {}

  void compile_all() {
    compile_hello();
    compile_math();
    compile_greeter();
  }

private:
  // ---- THE instrumented write point ---------------------------------------
  void write_code(std::string_view text) {
    sink_.emit(next_id_++, input_, output_, text);
  }
  void use(std::string input, std::string output) {
    input_ = std::move(input);
    output_ = std::move(output);
  }

  // ===== unit 1: hello.mylang -> hello.cpp =================================
  void compile_hello() {
    use("hello.mylang", "hello.cpp");
    emit_includes();
    emit_main();
  }
  void emit_includes() {
    write_code("#include <ostream>\n#include <vector>\n");
  }
  void emit_main() {
    emit_signature2("main");
    emit_body();
    emit_close();
  }
  void emit_signature(std::string_view name) {
    write_code("short " + std::string(name) + "() {");
  }
  void emit_signature2(std::string_view name) {
    write_code("int " + std::string(name) + "() {");
  }
  void emit_body() {
    emit_decls();
    emit_loop();
  }
  void emit_decls() {
    write_code("\n    int a = 4;\n    int b = 8;\n    int sum = a + b;\n");
  }
  void emit_loop() {
    emit_loop_header();
    emit_loop_body();
    write_code("    }\n");
  }
  void emit_loop_header() {
    write_code("    for (int i = 0; i < 10; ++i) {\n");
  }
  void emit_loop_body() { write_code("        sum += i;\n"); }
  void emit_close() { write_code("\n    return sum;\n}\n"); }

  // ===== unit 2: math.mylang -> math.h AND math.cpp =======================
  void compile_math() {
    use("math.mylang", "math.h"); // first output of this input
    emit_header();
    output_ = "math.cpp"; // second output, same input
    emit_impl();
  }
  void emit_header() {
    write_code("#pragma once\n#include <cstdint>\n\n");
    emit_decl("add");
    emit_decl("mul");
  }
  void emit_decl(std::string_view name) {
    write_code("std::int64_t " + std::string(name) +
               "(std::int64_t x, std::int64_t y);\n");
  }
  void emit_impl() {
    write_code("#include \"math.h\"\n\n");
    emit_fn("add", "x + y");
    emit_fn("mul", "x * y");
  }
  void emit_fn(std::string_view name, std::string_view expr) {
    emit_fn_open(name);
    emit_return(expr);
    emit_fn_close();
  }
  void emit_fn_open(std::string_view name) {
    write_code("std::int64_t " + std::string(name) +
               "(std::int64_t x, std::int64_t y) {\n");
  }
  void emit_return(std::string_view expr) {
    write_code("    return " + std::string(expr) + ";\n");
  }
  void emit_fn_close() { write_code("}\n\n"); }

  // ===== unit 3: greet.mylang -> greet.cpp ================================
  void compile_greeter() {
    use("greet.mylang", "greet.cpp");
    write_code("#include <iostream>\n#include <string>\n\n");
    emit_greet();
  }
  void emit_greet() {
    emit_greet_sig();
    emit_greet_body();
    write_code("}\n");
  }
  void emit_greet_sig() { write_code("void greet(const std::string& who) {"); }
  void emit_greet_body() {
    write_code("\n    std::cout << \"Hello, \" << who << \"!\\n\";\n");
  }

  diag::Sink &sink_;
  std::string input_;
  std::string output_;
  std::uint64_t next_id_ = 0;
};

int main() {
  std::ofstream out("compile.jsonl"); // truncate: a fresh run each time
  diag::Sink sink(out);

  Compiler cc(sink);
  cc.compile_all();

  std::cerr << "emitted records to compile.jsonl\n";
  return 0;
}
