"""Speed up the initial native readiness check for an app launch."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_launch_proof(bridge_root: Path, poki_root: Path) -> None:
    app = poki_root / "native/ios-app/Poki"
    header = app / "Native/InProcess.h"
    implementation = app / "Native/InProcess.m"

    replace_once(
        header,
        "- (NSDictionary<NSString *, id> *)prepare;\n",
        """- (NSDictionary<NSString *, id> *)prepare;
/// Open for a launch that will immediately read its destination.
- (NSDictionary<NSString *, id> *)prepareForAppLaunch;
""",
        "PokiCore native app launch readiness entry",
    )
    replace_once(
        implementation,
        "- (NSDictionary<NSString *, id> *)prepare {\n    NSError *error;",
        """- (NSDictionary<NSString *, id> *)prepare {
    return [self prepareWithLaunchProof:NO];
}

- (NSDictionary<NSString *, id> *)prepareForAppLaunch {
    return [self prepareWithLaunchProof:YES];
}

- (NSDictionary<NSString *, id> *)prepareWithLaunchProof:(BOOL)allowSystemProof {
    NSError *error;""",
        "PokiCore native app launch preparation",
    )
    replace_once(
        implementation,
        """    NSString *unreadable = [self unreadableReason:generation warm:&warm];
    if (unreadable) {
        return @{@"ok": @NO, @"code": @"session_unreadable", @"detail": unreadable, @"generation": @(generation),
                 @"seconds": @(seconds), @"warm_seconds": @(warm), @"device": [_sessions rebindDetail] ?: @"first"};
    }
    return @{@"ok": @YES, @"generation": @(generation), @"reused": @(_sessions.enableWasReused), @"seconds": @(seconds), @"warm_seconds": @(warm),
             @"device": [_sessions rebindDetail] ?: @"first"};""",
        """    NSString *readinessCheck = nil;
    NSString *unreadable = [self unreadableReason:generation warm:&warm allowSystemProof:allowSystemProof
                                           mode:&readinessCheck];
    if (unreadable) {
        return @{@"ok": @NO, @"code": @"session_unreadable", @"detail": unreadable, @"generation": @(generation),
                 @"seconds": @(seconds), @"warm_seconds": @(warm), @"readiness_check": readinessCheck ?: @"full",
                 @"device": [_sessions rebindDetail] ?: @"first"};
    }
    return @{@"ok": @YES, @"generation": @(generation), @"reused": @(_sessions.enableWasReused), @"seconds": @(seconds),
             @"warm_seconds": @(warm), @"readiness_check": readinessCheck ?: @"full", @"device": [_sessions rebindDetail] ?: @"first"};""",
        "PokiCore native launch readiness timing",
    )
    replace_once(
        implementation,
        """- (nullable NSString *)unreadableReason:(uint64_t)generation warm:(double *)warm {
    // The check's own lookups come back through -current:outcome: and pass.
    @synchronized (self) { if (_readableGeneration == generation || _provingGeneration == generation) return nil; }""",
        """- (nullable NSString *)unreadableReason:(uint64_t)generation warm:(double *)warm {
    return [self unreadableReason:generation warm:warm allowSystemProof:NO mode:NULL];
}

- (nullable NSString *)unreadableReason:(uint64_t)generation warm:(double *)warm
                      allowSystemProof:(BOOL)allowSystemProof mode:(NSString **)mode {
    // The check's own lookups come back through -current:outcome: and pass.
    @synchronized (self) {
        if (_readableGeneration == generation || _provingGeneration == generation) {
            if (mode) *mode = _readableGeneration == generation ? @"cached" : @"in_progress";
            return nil;
        }
    }""",
        "PokiCore native session proof mode",
    )
    replace_once(
        implementation,
        """            if (_readableGeneration == generation) return nil;
            _provingGeneration = generation;""",
        """            if (_readableGeneration == generation) {
                if (mode) *mode = @"cached";
                return nil;
            }
            _provingGeneration = generation;""",
        "PokiCore native session proof after lock",
    )
    replace_once(
        implementation,
        "        NSString *why = [self proveReadable:generation];",
        """        if (mode) *mode = @"full";
        NSString *why = [self proveReadable:generation allowSystemProof:allowSystemProof mode:mode];""",
        "PokiCore native session proof selection",
    )
    replace_once(
        implementation,
        "- (nullable NSString *)proveReadable:(uint64_t)generation {",
        """- (nullable NSString *)proveReadable:(uint64_t)generation
                    allowSystemProof:(BOOL)allowSystemProof mode:(NSString **)mode {""",
        "PokiCore native readiness proof",
    )
    replace_once(
        implementation,
        """        id root = system ? PKRequestSnapshotWithin(3, ax, system, 1, 1, &code) : nil;
        id client = nil;""",
        """        id root = system ? PKRequestSnapshotWithin(3, ax, system, 1, 1, &code) : nil;
        if (allowSystemProof && loaded && root) {
            if (mode) *mode = @"system";
            return nil;
        }
        id client = nil;""",
        "PokiCore native fast launch proof",
    )

    tests = poki_root / "native/ios-app/PokiTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiLaunchProofTests.swift", tests)
