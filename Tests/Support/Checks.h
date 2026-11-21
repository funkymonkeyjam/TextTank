// SPDX-License-Identifier: GPL-3.0-or-later
// Shared check harness for the Objective-C++ check executables; the Swift
// counterpart is Checks.swift. A failed check is recorded and the suite carries
// on. Output is uniform: `PASS <label>` or `FAIL <file>:<line> <label>`, and
// the process exits non-zero when anything failed. Include this header last.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
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
inline int &knownDefects() { static int value = 0; return value; }
/// An expected failure: `fixed` is what will hold once the audit finding is repaired.
/// While it does not hold this prints `KNOWN-DEFECT <finding> <label>`; once it holds the
/// check fails, so the repairing package has to turn it into an ordinary check.
inline bool known(const char *finding, bool fixed, const char *label, const char *file, int line) {
    if (fixed) { fail(std::string("known defect ") + finding + " no longer reproduces; make this an ordinary check: " + label, file, line); return false; }
    knownDefects() += 1;
    printf("KNOWN-DEFECT %s %s\n", finding, label); fflush(stdout);
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
inline void verifyNativeImages() {
    NSDictionary<NSString *, NSString *> *classes = @{@"TTEditor":@"EditorBridge", @"TTSearchEngine":@"NativeSearch", @"ScintillaView":@"Scintilla"};
    for (NSString *className in classes) {
        Class type=objc_lookUpClass(className.UTF8String);
        if (!type) continue;
        NSString *framework=classes[className];
        const char *manifestPath=getenv("TEXTTANK_ARTIFACT_MANIFEST"), *imageName=class_getImageName(type);
        NSError *error=nil;
        NSData *manifestData=manifestPath ? [NSData dataWithContentsOfFile:@(manifestPath) options:0 error:&error] : nil;
        id manifest=manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error] : nil;
        NSDictionary *images=[manifest isKindOfClass:NSDictionary.class] ? manifest[@"images"] : nil;
        NSDictionary *expected=[images isKindOfClass:NSDictionary.class] ? images[framework] : nil;
        if (![expected isKindOfClass:NSDictionary.class] || !imageName || ![expected[@"embedded"] isKindOfClass:NSString.class] || ![expected[@"embedded_sha256"] isKindOfClass:NSString.class]) {
            fail("native artifact identity: missing actual code-image record", __FILE__, __LINE__); continue;
        }
        NSString *actual=[@(imageName) stringByResolvingSymlinksInPath];
        NSString *wanted=[expected[@"embedded"] stringByResolvingSymlinksInPath];
        NSData *bytes=[NSData dataWithContentsOfFile:actual options:0 error:&error];
        if (!bytes || bytes.length>UINT32_MAX) {
            fail("native artifact identity: code image cannot be read or hashed", __FILE__, __LINE__); continue;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
        NSMutableString *hash=[NSMutableString string];
        for (unsigned char byte: digest) [hash appendFormat:@"%02x",byte];
        if (![actual isEqual:wanted] || ![hash isEqual:expected[@"embedded_sha256"]]) {
            fail("native artifact identity: wrong loaded path or actual signed code hash", __FILE__, __LINE__); continue;
        }
        printf("ARTIFACT_IMAGE %s %s %s\n",framework.UTF8String,hash.UTF8String,actual.UTF8String);
    }
}
inline int finish(const char *name, const char *detail) {
    verifyNativeImages();
    if (failures().empty() && knownDefects() > 0) printf("KNOWN-DEFECTS %s: %d expected failures, not counted below\n", name, knownDefects());
    if (failures().empty()) { printf("PASS %s: %d assertions%s%s\n", name, count(), detail[0] ? "; " : "", detail); fflush(stdout); return 0; }
    printf("FAILED %s: %zu failed, %d passed\n", name, failures().size(), count());
    for (const std::string &entry : failures()) printf("  %s\n", entry.c_str());
    fflush(stdout);
    return 1;
}
}
// Variadic so that Objective-C literals containing commas need no extra parentheses.
#define check(...) ttchecks::record(__VA_ARGS__, __FILE__, __LINE__)
#define knownDefect(finding, fixed, label) ttchecks::known(finding, fixed, label, __FILE__, __LINE__)
#define require(...) ttchecks::need(__VA_ARGS__, __FILE__, __LINE__)
