// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
// Own CLI process only: no session/user registration, installation or font list.
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <cmath>
#include <vector>
#include <chrono>
#include <set>
#include "../../runtime/font-policy-v1/system_font_source.h"

using neantik::fonts::ResolvedOrigin;
using neantik::fonts::OriginLabel;
using neantik::fonts::SystemSourcePolicy;

static bool IsOwnFont(CTFontRef font, CFStringRef expected) {
  if (!font) return false;
  CFStringRef actual = CTFontCopyPostScriptName(font);
  const bool equal = actual && CFEqual(actual, expected);
  if (actual) CFRelease(actual);
  return equal;
}

static bool DrawOwnGlyph(CTFontRef font) {
  UniChar character = 'A'; CGGlyph glyph = 0;
  if (!font || !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) || !glyph) return false;
  std::vector<unsigned char> pixels(64 * 64 * 4, 0);
  CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixels.data(), 64, 64, 8, 64 * 4, color,
      static_cast<unsigned>(kCGImageAlphaPremultipliedLast) | static_cast<unsigned>(kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(color); if (!context) return false;
  CGContextSetRGBFillColor(context, 0, 0, 0, 1);
  CGPoint position = CGPointMake(8, 24);
  CTFontDrawGlyphs(font, &glyph, &position, 1, context);
  CGContextRelease(context);
  size_t opaque = 0;
  for (size_t i = 3; i < pixels.size(); i += 4) opaque += pixels[i] > 0;
  return opaque > 20;
}

static NSDictionary* ShapeSample(NSString* label, NSString* text, CTFontRef base,
                                SystemSourcePolicy& policy) {
  NSDictionary* attributes = @{(__bridge NSString*)kCTFontAttributeName:(__bridge id)base};
  NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:text attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  NSMutableDictionary* origins = [NSMutableDictionary dictionary];
  size_t glyphs = 0, rejected = 0;
  bool missingGlyph=false,lastResort=false;
  std::set<CGGlyph> distinct;
  for (CFIndex i = 0; i < CFArrayGetCount(runs); ++i) {
    CTRunRef run = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, i));
    CFDictionaryRef attrs = CTRunGetAttributes(run);
    CTFontRef font = static_cast<CTFontRef>(CFDictionaryGetValue(attrs, kCTFontAttributeName));
    NSString* origin = [NSString stringWithUTF8String:OriginLabel(ResolvedOrigin(font))];
    origins[origin] = @([origins[origin] unsignedIntegerValue] + 1);
    glyphs += CTRunGetGlyphCount(run); rejected += !policy.AllowsHostFont(font);
    lastResort |= IsOwnFont(font,CFSTR("LastResort")) || IsOwnFont(font,CFSTR(".LastResort"));
    std::vector<CGGlyph> mapped(CTRunGetGlyphCount(run));
    CTRunGetGlyphs(run,CFRangeMake(0,0),mapped.data());
    for (auto glyph:mapped) {missingGlyph|=glyph==0;distinct.insert(glyph);}
  }
  double width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
  std::vector<unsigned char> pixels(256*64*4,0);
  CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
  CGContextRef context=CGBitmapContextCreate(pixels.data(),256,64,8,256*4,space,
      static_cast<unsigned>(kCGImageAlphaPremultipliedLast)|static_cast<unsigned>(kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(space);
  bool drawn=false;
  if (context) {
    CGContextSetRGBFillColor(context,0,0,0,1);CGContextSetTextPosition(context,8,24);CTLineDraw(line,context);CGContextRelease(context);
    for (size_t i=3;i<pixels.size();i+=4)if(pixels[i]){drawn=true;break;}
  }
  CFRelease(line);
  const bool differentiated=![label isEqualToString:@"CJK"] || distinct.size()>1;
  return @{ @"sample":label, @"glyphs":@(glyphs), @"shapingCompleted":@(glyphs > 0 && std::isfinite(width) && width > 0 && !missingGlyph && !lastResort && differentiated && drawn),
            @"actualBitmapDrawn":@(drawn),@"missingGlyph":@(missingGlyph),@"lastResortUsed":@(lastResort),
            @"distinctGlyphCount":@(distinct.size()),@"originClasses":origins, @"strictPolicyRejectedRuns":@(rejected) };
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if (argc != 2) return 64;
    NSString* root = [NSString stringWithUTF8String:argv[1]];
    NSURL* canaryURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"owned-canary.ttf"]];
    NSURL* collisionURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"owned-family-collision.ttf"]];
    SystemSourcePolicy policy;
    CTFontRef initial = CTFontCreateWithName(CFSTR("NeAntikFontPolicyCanary"), 20, nullptr);
    const bool initialAbsent = !IsOwnFont(initial, CFSTR("NeAntikFontPolicyCanary"));
    if (initial) CFRelease(initial);
    if (!initialAbsent) return 65;  // An external fixture must not be overwritten.
    CFErrorRef error = nullptr;
    bool registered = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)canaryURL, kCTFontManagerScopeProcess, &error);
    if (error) { CFRelease(error); error = nullptr; }
    bool collisionRegistered = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)collisionURL, kCTFontManagerScopeProcess, &error);
    if (error) { CFRelease(error); error = nullptr; }
    NSMutableDictionary* output = [@{ @"schemaVersion":@1, @"scope":@"own CoreText process; no browser qualification",
        @"registrationScope":@"process", @"systemFontInstallation":@NO,
        @"canaryAbsentBeforeRegistration":@(initialAbsent), @"canaryRegistered":@(registered),
        @"familyCollisionRegistered":@(collisionRegistered) } mutableCopy];

    CTFontRef canary = CTFontCreateWithName(CFSTR("NeAntikFontPolicyCanary"), 20, nullptr);
    CTFontRef familyLookup = CTFontCreateWithName(CFSTR("Helvetica"), 20, nullptr);
    NSURL* protectedURL = [NSURL fileURLWithPath:@"/System/Library/Fonts/Helvetica.ttc"];
    CFArrayRef protectedFaces = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)protectedURL);
    CTFontRef system = protectedFaces && CFArrayGetCount(protectedFaces) > 0
        ? CTFontCreateWithFontDescriptor(static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(protectedFaces,0)),20,nullptr) : nullptr;
    if (protectedFaces) CFRelease(protectedFaces);
    if (!system) return 67;
    bool canaryResolved = IsOwnFont(canary, CFSTR("NeAntikFontPolicyCanary"));
    output[@"canaryResolvedByNativeLookup"] = @(canaryResolved);
    output[@"canaryDrawn"] = @(DrawOwnGlyph(canary));
    output[@"canaryRejectedByHostPolicy"] = @(!policy.AllowsHostFont(canary));
    output[@"systemFamilyResultAllowed"] = @(policy.AllowsHostFont(system));
    const bool selectedOwnCollision = IsOwnFont(familyLookup, CFSTR("NeAntikFontPolicyFamilyCollision"));
    output[@"nativeFamilyLookupSelectedOwnCollision"] = @(selectedOwnCollision);
    output[@"nativeFamilyLookupAllowedAfterCollision"] = @(policy.AllowsHostFont(familyLookup));
    output[@"actualFamilyCollisionControlRejected"] = @(selectedOwnCollision && DrawOwnGlyph(familyLookup) && !policy.AllowsHostFont(familyLookup));
    output[@"systemFamilyOriginClass"] = [NSString stringWithUTF8String:OriginLabel(ResolvedOrigin(system))];
    CFArrayRef replacements = policy.CopySystemCandidates(CFSTR("Helvetica"));
    bool counterpartFound = false;
    for (CFIndex i=0; i<CFArrayGetCount(replacements); ++i) {
      CTFontRef candidate = CTFontCreateWithFontDescriptor(static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(replacements,i)),20,nullptr);
      counterpartFound |= policy.AllowsHostFont(candidate) && DrawOwnGlyph(candidate);
      if (candidate) CFRelease(candidate);
    }
    CFRelease(replacements);
    output[@"protectedFamilyCounterpartFound"] = @(counterpartFound);
    CTFontRef lastResort=CTFontCreateWithName(CFSTR("LastResort"),20,nullptr);
    bool actualLastResort=IsOwnFont(lastResort,CFSTR("LastResort"));
    CTFontRef realFallback=policy.CopySystemFallbackForText(lastResort,CFSTR("A"),CFSTR("en"));
    bool avoidedLastResort=actualLastResort && realFallback && !IsOwnFont(realFallback,CFSTR("LastResort")) && policy.AllowsHostFont(realFallback) && DrawOwnGlyph(realFallback);
    output[@"actualLastResortControlRejected"] = @(avoidedLastResort);
    if (lastResort)CFRelease(lastResort);if(realFallback)CFRelease(realFallback);

    // Try to spoof origin metadata using real canary glyphs plus a system URL.
    CFTypeRef systemURL = CTFontCopyAttribute(system, kCTFontURLAttribute);
    CGFontRef graphics = CTFontCopyGraphicsFont(canary, nullptr);
    NSDictionary* fakeAttributes = systemURL ? @{(__bridge NSString*)kCTFontURLAttribute:(__bridge id)systemURL} : @{};
    CTFontDescriptorRef fakeDescriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)fakeAttributes);
    CTFontRef spoof = graphics ? CTFontCreateWithGraphicsFont(graphics, 20, nullptr, fakeDescriptor) : nullptr;
    output[@"spoofUsesOwnCanaryGlyphs"] = @(IsOwnFont(spoof, CFSTR("NeAntikFontPolicyCanary")));
    output[@"spoofOriginClass"] = [NSString stringWithUTF8String:OriginLabel(ResolvedOrigin(spoof))];
    output[@"spoofRejected"] = @(!policy.AllowsHostFont(spoof));

    // Explicit resource data is not a host lookup; preserve native drawing.
    NSData* bytes = [NSData dataWithContentsOfURL:canaryURL];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGFontRef downloadedGraphics = CGFontCreateWithDataProvider(provider);
    CTFontRef downloaded = downloadedGraphics ? CTFontCreateWithGraphicsFont(downloadedGraphics, 20, nullptr, nullptr) : nullptr;
    output[@"explicitResourceDataDrawn"] = @(IsOwnFont(downloaded, CFSTR("NeAntikFontPolicyCanary")) && DrawOwnGlyph(downloaded));

    NSMutableArray* samples = [NSMutableArray array];
    NSMutableArray* restricted = [NSMutableArray array];
    bool fallbackReady = true;
    for (NSArray* sample in @[@[@"Latin",@"Hello World",@"en"],@[@"Cyrillic",@"Привет",@"ru"],@[@"CJK",@"中文日本語",@"zh"],
                             @[@"Arabic",@"العربية",@"ar"],@[@"Combining",@"a\u0301",@"en"],@[@"ColourEmoji",@"😀",@"en"],@[@"VariationSelector",@"❤️",@"en"]]) {
      [samples addObject:ShapeSample(sample[0], sample[1], system, policy)];
      CTFontRef fallback=policy.CopySystemFallbackForText(system,(__bridge CFStringRef)sample[1],(__bridge CFStringRef)sample[2]);
      if (fallback) {
        NSDictionary* row=ShapeSample(sample[0],sample[1],fallback,policy);
        fallbackReady &= [row[@"shapingCompleted"] boolValue] && [row[@"strictPolicyRejectedRuns"] unsignedIntegerValue] == 0;
        [restricted addObject:row];CFRelease(fallback);
      } else {
        fallbackReady=false;[restricted addObject:@{@"sample":sample[0],@"fallbackUnavailable":@YES}];
      }
    }
    output[@"samples"] = samples;
    output[@"restrictedSamples"] = restricted;
    output[@"candidateFallbackReady"] = @(fallbackReady && counterpartFound && avoidedLastResort);
    output[@"protectedDescriptorCount"] = @(policy.SystemDescriptorCount());
    const auto start = std::chrono::steady_clock::now();
    size_t cachedAllowed = 0;
    for (size_t i = 0; i < 10000; ++i) cachedAllowed += policy.AllowsHostFont(system);
    output[@"cachedAllowedReads"] = @(cachedAllowed);
    output[@"cachedReadsMicroseconds"] = @(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
    for (int size = 1; size <= 40; ++size) {
      CTFontRef font = CTFontCreateCopyWithAttributes(system, size, nullptr, nullptr);
      policy.AllowsHostFont(font); if (font) CFRelease(font);
    }
    output[@"cacheWithinBound"] = @(policy.CachedCount() <= 32);
    if (systemURL) CFRelease(systemURL);
    if (fakeDescriptor) CFRelease(fakeDescriptor);
    if (graphics) CGFontRelease(graphics);
    if (spoof) CFRelease(spoof);
    if (downloaded) CFRelease(downloaded);
    if (downloadedGraphics) CGFontRelease(downloadedGraphics);
    if (provider) CGDataProviderRelease(provider);
    if (system) CFRelease(system); if (canary) CFRelease(canary); if (familyLookup) CFRelease(familyLookup);
    bool removedCanary = !registered || CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)canaryURL, kCTFontManagerScopeProcess, &error);
    if (error) { CFRelease(error); error = nullptr; }
    bool removedCollision = !collisionRegistered || CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)collisionURL, kCTFontManagerScopeProcess, &error);
    if (error) CFRelease(error);
    output[@"ownRegistrationsRemoved"] = @(removedCanary && removedCollision);
    output[@"primitiveControlsPassed"] = @(registered && collisionRegistered && canaryResolved &&
        [output[@"actualFamilyCollisionControlRejected"] boolValue] &&
        [output[@"canaryDrawn"] boolValue] && [output[@"canaryRejectedByHostPolicy"] boolValue] &&
        [output[@"spoofUsesOwnCanaryGlyphs"] boolValue] && [output[@"spoofRejected"] boolValue] &&
        [output[@"systemFamilyResultAllowed"] boolValue] && [output[@"cachedAllowedReads"] unsignedLongValue] == 10000 &&
        [output[@"explicitResourceDataDrawn"] boolValue] && [output[@"cacheWithinBound"] boolValue] && removedCanary && removedCollision);
    NSData* json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nullptr];
    if (!json) return 66;
    fwrite(json.bytes, 1, json.length, stdout);fputc('\n', stdout);
    return [output[@"primitiveControlsPassed"] boolValue] && [output[@"candidateFallbackReady"] boolValue] ? 0 : 1;
  }
}
