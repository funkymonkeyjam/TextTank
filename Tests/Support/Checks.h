// SPDX-License-Identifier: GPL-3.0-or-later
// Shared check harness for the Objective-C++ check executables; the Swift
// counterpart is Checks.swift. A failed check is recorded and the suite carries
// on. Output is uniform: `PASS <label>` or `FAIL <file>:<line> <label>`, and
// the process exits non-zero when anything failed. Include this header last.
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <functional>
#include <string>
#include <vector>

namespace ttchecks {
struct Stop {};
inline int &count() { static int value = 0; return value; }
inline std::vector<std::string> &failures() { static std::vector<std::string> value; return value; }
inline std::string location(const char *file, int line) {
    std::string path(file);
    size_t at = path.rfind("Tests/");
    return (at == std::string::npos ? path : path.substr(at)) + ":" + std::to_string(line);
}
inline void fail(const std::string &label, const char *file, int line) {
    std::string entry = "FAIL " + location(file, line) + " " + label;
    failures().push_back(entry);
    printf("%s\n", entry.c_str()); fflush(stdout);
}
inline bool record(bool condition, const char *label, const char *file, int line) {
    // TEXTTANK_FORCE_FAIL=<label> forces that check to fail, to prove failures are reported.
    const char *forced = getenv("TEXTTANK_FORCE_FAIL");
    if (!condition || (forced && strcmp(forced, label) == 0)) { fail(label, file, line); return false; }
    count() += 1;
    printf("PASS %s\n", label); fflush(stdout);
    return true;
}
/// For a precondition the following code cannot run without; success is not counted.
inline void need(bool condition, const char *label, const char *file, int line) {
    if (!condition) { fail(label, file, line); throw Stop(); }
}
/// Runs one named group of checks. A failed `require`, a C++ exception or an
/// Objective-C exception ends that section only.
inline void section(const char *name, const std::function<void()> &body) {
    std::string prefix = std::string("section '") + name + "' stopped";
    @try {
        try { body(); }
        catch (const Stop &) { fail(prefix + ": a required condition failed", __FILE__, __LINE__); }
        catch (const std::exception &error) { fail(prefix + ": " + error.what(), __FILE__, __LINE__); }
    } @catch (NSException *exception) {
        fail(prefix + ": " + std::string(exception.name.UTF8String ?: "NSException") + ": " + std::string(exception.reason.UTF8String ?: ""), __FILE__, __LINE__);
    }
}
/// Prints the summary or the failures and returns the process exit status.
inline int finish(const char *name, const char *detail) {
    if (failures().empty()) { printf("PASS %s: %d assertions%s%s\n", name, count(), detail[0] ? "; " : "", detail); fflush(stdout); return 0; }
    printf("FAILED %s: %zu failed, %d passed\n", name, failures().size(), count());
    for (const std::string &entry : failures()) printf("  %s\n", entry.c_str());
    fflush(stdout);
    return 1;
}
}
// Variadic so that Objective-C literals containing commas need no extra parentheses.
#define check(...) ttchecks::record(__VA_ARGS__, __FILE__, __LINE__)
#define require(...) ttchecks::need(__VA_ARGS__, __FILE__, __LINE__)
