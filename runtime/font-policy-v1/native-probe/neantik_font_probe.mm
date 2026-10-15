// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
// Same real patched Skia/policy archives; own process font registration only.
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <limits.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include "components/ungoogled/system_font_policy_mac.h"
#include "components/ungoogled/system_font_source.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkCanvas.h"
#include "third_party/skia/include/core/SkFont.h"
#include "third_party/skia/include/core/SkFontArguments.h"
#include "third_party/skia/include/core/SkFontMgr.h"
#include "third_party/skia/include/core/SkFontParameters.h"
#include "third_party/skia/include/core/SkPaint.h"
#include "third_party/skia/include/core/SkSpan.h"
#include "third_party/skia/include/ports/SkFontMgr_mac_ct.h"
#include "third_party/skia/include/ports/SkTypeface_mac.h"
#include <type_traits>

using ungoogled::nevision::IsAllowedSystemHostFont;
using ungoogled::nevision::SystemFontPolicyV1Enabled;
struct OwnCFRelease {void operator()(CFTypeRef value)const{if(value)CFRelease(value);}};
template<typename T>using OwnCF=std::unique_ptr<std::remove_pointer_t<T>,OwnCFRelease>;
using CFList=OwnCF<CFArrayRef>;
static bool NameIs(CTFontRef font,CFStringRef expected){
  OwnCF<CFStringRef> name(font?CTFontCopyPostScriptName(font):nullptr);
  return name&&CFEqual(name.get(),expected);
}
static bool SameFontFile(CFTypeRef left,CFTypeRef right){
  if(!left||!right||CFGetTypeID(left)!=CFURLGetTypeID()||CFGetTypeID(right)!=CFURLGetTypeID())return false;
  auto identify=[](CFURLRef url,struct stat& value){
    OwnCF<CFStringRef> scheme(CFURLCopyScheme(url));UInt8 path[PATH_MAX];char resolved[PATH_MAX];
    if(!scheme||!CFEqual(scheme.get(),CFSTR("file"))||!CFURLGetFileSystemRepresentation(url,true,path,sizeof(path))||!realpath(reinterpret_cast<const char*>(path),resolved))return false;
    const int fd=open(resolved,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);if(fd<0)return false;
    const bool valid=fstat(fd,&value)==0&&S_ISREG(value.st_mode);close(fd);return valid;
  };
  struct stat a{},b{};return identify(static_cast<CFURLRef>(left),a)&&identify(static_cast<CFURLRef>(right),b)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
}
static bool SameSource(CTFontRef font,CTFontDescriptorRef descriptor){
  if(!font||!descriptor)return false;
  OwnCF<CFStringRef> name(CTFontCopyPostScriptName(font));
  OwnCF<CFTypeRef> url(CTFontCopyAttribute(font,kCTFontURLAttribute));
  OwnCF<CFTypeRef> otherName(CTFontDescriptorCopyAttribute(descriptor,kCTFontNameAttribute));
  OwnCF<CFTypeRef> otherURL(CTFontDescriptorCopyAttribute(descriptor,kCTFontURLAttribute));
  // CoreText can return a file-reference URL for a registered fixture, whereas
  // its input descriptor has a path URL. Compare the actual file plus face.
  return name&&url&&otherName&&otherURL&&CFEqual(name.get(),otherName.get())&&SameFontFile(url.get(),otherURL.get());
}
static bool InList(const SkTypeface* face,CFArrayRef list){
  CTFontRef font=face?SkTypeface_GetCTFontRef(face):nullptr;if(!font)return false;
  for(CFIndex i=0;i<CFArrayGetCount(list);i++)if(SameSource(font,static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(list,i))))return true;
  return false;
}
static CFList List(std::initializer_list<CTFontDescriptorRef> descriptors){
  std::vector<const void*> values;for(auto d:descriptors)values.push_back(d);
  return CFList(CFArrayCreate(nullptr,values.data(),values.size(),&kCFTypeArrayCallBacks));
}
static CTFontDescriptorRef Find(CFArrayRef list,CFStringRef name){
  for(CFIndex i=0;list&&i<CFArrayGetCount(list);i++){
    auto d=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(list,i));
    OwnCF<CFTypeRef> value(CTFontDescriptorCopyAttribute(d,kCTFontNameAttribute));
    if(value&&CFEqual(value.get(),name))return d;
  }return nullptr;
}
static OwnCF<CTFontCollectionRef> MakeFontCollection(CFArrayRef descriptors){
  const void* key=kCTFontCollectionDisallowAutoActivationOption;const void* value=kCFBooleanTrue;
  OwnCF<CFDictionaryRef> options(CFDictionaryCreate(nullptr,&key,&value,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));
  return OwnCF<CTFontCollectionRef>(CTFontCollectionCreateWithFontDescriptors(descriptors,options.get()));
}
static bool ExactCollection(CTFontCollectionRef collection,CFArrayRef expected){
  CFList actual(collection?CTFontCollectionCreateMatchingFontDescriptors(collection):nullptr);
  if(!actual||CFArrayGetCount(actual.get())!=CFArrayGetCount(expected))return false;
  std::vector<bool> used(CFArrayGetCount(expected),false);
  for(CFIndex i=0;i<CFArrayGetCount(actual.get());i++){
    auto d=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(actual.get(),i));
    OwnCF<CTFontRef> font(CTFontCreateWithFontDescriptor(d,24,nullptr));bool found=false;
    for(CFIndex j=0;j<CFArrayGetCount(expected);j++)if(!used[j]&&SameSource(font.get(),static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(expected,j)))){used[j]=true;found=true;break;}
    if(!found)return false;
  }return true;
}
// Failed setup diagnostics contain only counts and comparisons of the finite
// requested fixtures. Never export descriptors, URLs or a system inventory.
static NSDictionary* CollectionSetup(CTFontCollectionRef collection,CFArrayRef expected){
  CFList actual(collection?CTFontCollectionCreateMatchingFontDescriptors(collection):nullptr);
  int missingExpectedName=0,missingExpectedURL=0,matchedDescriptors=0,matchedInstances=0,namesMatched=0,filesMatched=0;
  for(CFIndex j=0;j<CFArrayGetCount(expected);j++){
    auto d=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(expected,j));
    OwnCF<CFTypeRef> name(CTFontDescriptorCopyAttribute(d,kCTFontNameAttribute));
    OwnCF<CFTypeRef> url(CTFontDescriptorCopyAttribute(d,kCTFontURLAttribute));
    missingExpectedName+=!name;missingExpectedURL+=!url;
    if(!actual||CFArrayGetCount(actual.get())>64)continue;
    bool direct=false,instance=false,nameMatched=false,fileMatched=false;
    for(CFIndex i=0;i<CFArrayGetCount(actual.get());i++){
      auto a=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(actual.get(),i));
      OwnCF<CFTypeRef> an(CTFontDescriptorCopyAttribute(a,kCTFontNameAttribute));
      OwnCF<CFTypeRef> au(CTFontDescriptorCopyAttribute(a,kCTFontURLAttribute));
      nameMatched|=name&&an&&CFEqual(name.get(),an.get());fileMatched|=SameFontFile(url.get(),au.get());
      direct|=name&&url&&an&&au&&CFEqual(name.get(),an.get())&&SameFontFile(url.get(),au.get());
      OwnCF<CTFontRef> font(CTFontCreateWithFontDescriptor(a,24,nullptr));instance|=SameSource(font.get(),d);
    }
    matchedDescriptors+=direct;matchedInstances+=instance;namesMatched+=nameMatched;filesMatched+=fileMatched;
  }
  return @{@"expectedCount":@(CFArrayGetCount(expected)),@"resolvedCount":@(actual?CFArrayGetCount(actual.get()):-1),@"expectedMissingName":@(missingExpectedName),@"expectedMissingURL":@(missingExpectedURL),@"descriptorMatches":@(matchedDescriptors),@"instantiatedMatches":@(matchedInstances),@"namesMatched":@(namesMatched),@"filesMatched":@(filesMatched)};
}
static bool Draw(sk_sp<SkTypeface> face,std::vector<uint8_t>* raster=nullptr){
  if(!face||!face->unicharToGlyph('A'))return false;
  SkBitmap bitmap;if(!bitmap.tryAllocN32Pixels(192,64))return false;bitmap.eraseColor(SK_ColorTRANSPARENT);
  SkCanvas canvas(bitmap);SkPaint paint;paint.setColor(SK_ColorBLACK);SkFont font(face,24);
  canvas.drawSimpleText("ABABA",5,SkTextEncoding::kUTF8,8,40,font,paint);
  bool ink=false;if(raster)raster->clear();
  for(int y=0;y<bitmap.height();y++)for(int x=0;x<bitmap.width();x++){auto alpha=SkColorGetA(bitmap.getColor(x,y));ink|=alpha>128;if(raster)raster->push_back(alpha);}
  return ink;
}
static bool Allowed(const SkTypeface* face){return face&&IsAllowedSystemHostFont(SkTypeface_GetCTFontRef(face));}
static bool Strict(const SkTypeface* face,neantik::fonts::SystemSourcePolicy& policy){return face&&policy.AllowsHostFont(SkTypeface_GetCTFontRef(face));}
static NSDictionary* Case(NSString* name,NSDictionary* fields){NSMutableDictionary* result=[fields mutableCopy];result[@"case"]=name;return result;}
static bool AllTrue(NSDictionary* value){for(NSString* key in value)if(![key isEqualToString:@"case"]&&![value[key] boolValue])return false;return true;}
static NSDictionary* VariableCase(NSString* caseName,sk_sp<SkTypeface> base,neantik::fonts::SystemSourcePolicy& strict){
  const int n=base?base->getVariationDesignParameters({}):-1;
  bool axes=n>0&&n<=64;std::vector<SkFontParameters::Variation::Axis> parameters(axes?n:0);
  axes=axes&&base->getVariationDesignParameters(parameters)==n;
  auto found=std::find_if(parameters.begin(),parameters.end(),[](const auto& axis){return axis.tag==SkSetFourByteTag('w','g','h','t')&&std::isfinite(axis.min)&&std::isfinite(axis.max)&&axis.min<axis.max;});
  axes=axes&&found!=parameters.end();const bool baseSource=Strict(base.get(),strict);bool applied=axes,source=baseSource,clonesAllowed=true,drawn=Draw(base),stable=true;float readback[2]={0,0};std::vector<uint8_t> rasters[2];
  if(axes)for(int i=0;i<2;i++){
    const float value=found->min+(found->max-found->min)*(i?0.75f:0.25f);
    SkFontArguments::VariationPosition::Coordinate coordinate{found->tag,value};SkFontArguments args;args.setVariationDesignPosition({&coordinate,1});auto clone=base->makeClone(args);
    const int count=clone?clone->getVariationDesignPosition({}):-1;bool valid=count>0&&count<=64;std::vector<SkFontArguments::VariationPosition::Coordinate> actual(valid?count:0);
    valid=valid&&clone->getVariationDesignPosition(actual)==count;
    auto weight=std::find_if(actual.begin(),actual.end(),[&](const auto& c){return c.axis==found->tag;});
    valid=valid&&weight!=actual.end()&&std::isfinite(weight->value)&&std::abs(weight->value-value)<=std::max(0.001f,(found->max-found->min)*0.0001f);
    if(valid)readback[i]=weight->value;applied&=valid;const bool cloneAllowed=Strict(clone.get(),strict);source&=cloneAllowed;clonesAllowed&=cloneAllowed;drawn&=Draw(clone,&rasters[i]);std::vector<uint8_t> repeated;stable&=Draw(clone,&repeated)&&repeated==rasters[i];
  }
  return Case(caseName,@{@"supportedAxisPresent":@(axes),@"distinctCoordinatesApplied":@(applied&&readback[0]!=readback[1]),@"baseSourceAllowed":@(baseSource),@"baseProtectedOrigin":@(base&&neantik::fonts::ResolvedOrigin(SkTypeface_GetCTFontRef(base.get()))==neantik::fonts::Origin::kProtectedSystemFile),@"clonedSourcesAllowed":@(axes&&clonesAllowed),@"postCloneSourceAllowed":@(source),@"actualDrawing":@(drawn),@"repeatedRastersStable":@(stable),@"distinctRastersDrawn":@(!rasters[0].empty()&&!rasters[1].empty()&&rasters[0]!=rasters[1])});
}
static NSDictionary* Run(CTFontDescriptorRef canary,CTFontDescriptorRef light,CFArrayRef helvetica,bool policy){
  neantik::fonts::SystemSourcePolicy strict;NSMutableArray* cases=[NSMutableArray array];
  auto own=List({canary}),single=List({light}),mixed=List({canary,light});
  auto ownCollection=MakeFontCollection(own.get()),singleCollection=MakeFontCollection(single.get()),mixedCollection=MakeFontCollection(mixed.get()),familyCollection=MakeFontCollection(helvetica);
  bool resolved=ExactCollection(ownCollection.get(),own.get())&&ExactCollection(singleCollection.get(),single.get())&&ExactCollection(mixedCollection.get(),mixed.get())&&ExactCollection(familyCollection.get(),helvetica);
  [cases addObject:Case(@"collection-query-preflight",@{@"collectionResolvedExactly":@(resolved)})];
  if(!resolved)return @{@"cases":cases,@"complete":@NO,@"failedSetupCounts":@[CollectionSetup(ownCollection.get(),own.get()),CollectionSetup(singleCollection.get(),single.get()),CollectionSetup(mixedCollection.get(),mixed.get()),CollectionSetup(familyCollection.get(),helvetica)]};
  auto ownMgr=SkFontMgr_New_CoreText(ownCollection.get()),singleMgr=SkFontMgr_New_CoreText(singleCollection.get()),mixedMgr=SkFontMgr_New_CoreText(mixedCollection.get()),familyMgr=SkFontMgr_New_CoreText(familyCollection.get());
  auto nativeOwn=mixedMgr->matchFamilyStyle("NeAntik Font Policy Canary",SkFontStyle::Normal());
  bool ownBehavior=policy?!nativeOwn:(nativeOwn&&NameIs(SkTypeface_GetCTFontRef(nativeOwn.get()),CFSTR("NeAntikFontPolicyCanary"))&&Draw(nativeOwn));
  bool enumerated=true,protectedSeen=false,canarySeen=false,membershipEscape=false;
  for(int i=0;i<mixedMgr->countFamilies();i++){
    auto set=mixedMgr->createStyleSet(i);
    for(int j=0;j<set->count();j++){
      auto face=set->createTypeface(j);enumerated&=face&&Allowed(face.get())&&Draw(face);
      membershipEscape|=face&&!InList(face.get(),mixed.get());
      if(policy)enumerated&=InList(face.get(),mixed.get())&&Strict(face.get(),strict);
      protectedSeen|=face&&NameIs(SkTypeface_GetCTFontRef(face.get()),CFSTR("Helvetica-Light"));
      canarySeen|=face&&NameIs(SkTypeface_GetCTFontRef(face.get()),CFSTR("NeAntikFontPolicyCanary"));
    }
  }
  [cases addObject:Case(@"mixed-restricted-collection",@{@"ownLookupBehavior":@(ownBehavior),@"enumerationDrawing":@(enumerated),@"membershipBoundaryBehavior":@(membershipEscape==!policy),@"protectedMemberSeen":@(protectedSeen),@"canaryEnumerationBehavior":@(canarySeen==!policy),@"familyCountBehavior":@(mixedMgr->countFamilies()==(policy?1:2))})];
  const char* zh[]={"zh"};
  bool ownEmpty=ownMgr->countFamilies()==0&&ownMgr->matchFamily("NeAntik Font Policy Canary")->count()==0&&!ownMgr->matchFamilyStyle(nullptr,SkFontStyle::Normal())&&!ownMgr->matchFamilyStyleCharacter(nullptr,SkFontStyle::Normal(),zh,1,0x4E2D)&&!ownMgr->legacyMakeTypeface(nullptr,SkFontStyle::Normal());
  auto ownPositive=ownMgr->matchFamilyStyle("NeAntik Font Policy Canary",SkFontStyle::Normal());
  [cases addObject:Case(@"own-only-no-global-fallback",@{@"behavior":@(policy?ownEmpty:(ownMgr->countFamilies()==1&&ownPositive&&Draw(ownPositive)))})];
  OwnCF<CTFontRef> lightFont(CTFontCreateWithFontDescriptor(light,24,nullptr));
  auto lightFace=lightFont?SkMakeTypefaceFromCTFont(lightFont.get()):nullptr;
  bool missing=lightFace&&!lightFace->unicharToGlyph(0x4E2D);
  auto escaped=singleMgr->matchFamilyStyleCharacter("Helvetica",SkFontStyle::Normal(),zh,1,0x4E2D);
  bool traitMembership=true,nativeTraitEscape=false;
  for(const auto& style:{SkFontStyle::Normal(),SkFontStyle::Bold(),SkFontStyle::Italic()}){
    auto a=singleMgr->matchFamilyStyle("Helvetica",style),b=singleMgr->matchFamily("Helvetica")->matchStyle(style);
    // Native upstream may widen this query. Its result is recorded separately.
    if(policy)traitMembership&=a&&b&&InList(a.get(),single.get())&&InList(b.get(),single.get())&&Strict(a.get(),strict)&&Strict(b.get(),strict)&&Draw(a)&&Draw(b);
    else nativeTraitEscape|=a&&b&&(!InList(a.get(),single.get())||!InList(b.get(),single.get()));
  }
  [cases addObject:Case(@"single-member-traits-and-character",@{@"missingCharacterPrecondition":@(missing),@"traitsBoundaryBehavior":@(policy?traitMembership:nativeTraitEscape),@"fallbackBoundaryBehavior":@(policy?!escaped:bool(escaped&&escaped->unicharToGlyph(0x4E2D)&&!InList(escaped.get(),single.get())))})];
  bool styles=true;
  for(const auto& style:{SkFontStyle::Normal(),SkFontStyle::Bold(),SkFontStyle::Italic()}){
    auto face=familyMgr->matchFamilyStyle("Helvetica",style);CTFontRef font=face?SkTypeface_GetCTFontRef(face.get()):nullptr;
    const auto traits=font?CTFontGetSymbolicTraits(font):0;
    styles&=face&&InList(face.get(),helvetica)&&Strict(face.get(),strict)&&Draw(face);
    styles&=bool(traits&kCTFontTraitBold)==(style.weight()>=SkFontStyle::kBold_Weight);
    styles&=bool(traits&kCTFontTraitItalic)==(style.slant()==SkFontStyle::kItalic_Slant);
  }
  [cases addObject:Case(@"full-protected-family-styles",@{@"actualStylesSourceAndDrawing":@(styles)})];
  OwnCF<CTFontRef> ui(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,24,nullptr));
  auto alias=ui?SkMakeTypefaceFromCTFont(ui.get()):nullptr;
  [cases addObject:VariableCase(@"ui-variable-weight-clones",alias,strict)];
  bool passed=true;for(NSDictionary* value in cases)passed&=AllTrue(value);
  return @{@"cases":cases,@"complete":@(passed)};
}
int main(int argc,const char* argv[]){@autoreleasepool{
  if(argc!=3||(!strcmp(argv[1],"native")?SystemFontPolicyV1Enabled():!strcmp(argv[1],"policy")?!SystemFontPolicyV1Enabled():strcmp(argv[1],"observe")!=0))return 64;
  OwnCF<CTFontRef> initial(CTFontCreateWithName(CFSTR("NeAntikFontPolicyCanary"),24,nullptr));bool absent=!NameIs(initial.get(),CFSTR("NeAntikFontPolicyCanary"));
  if(!absent)return 65;
  if(!strcmp(argv[1],"observe")){puts("{\"schemaVersion\":1,\"observer\":true,\"ownCanaryAbsent\":true}");return 0;}
  NSURL* url=[NSURL fileURLWithPath:[[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"owned-canary.ttf"]];CFErrorRef error=nullptr;
  bool registered=CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,kCTFontManagerScopeProcess,&error);if(error){CFRelease(error);error=nullptr;}if(!registered)return 66;
  CFList own(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));NSURL* system=[NSURL fileURLWithPath:@"/System/Library/Fonts/Helvetica.ttc"];
  CFList systemFaces(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)system));CTFontDescriptorRef canary=Find(own.get(),CFSTR("NeAntikFontPolicyCanary")),light=Find(systemFaces.get(),CFSTR("Helvetica-Light"));
  OwnCF<CFMutableArrayRef> family(CFArrayCreateMutable(nullptr,0,&kCFTypeArrayCallBacks));
  for(CFIndex i=0;systemFaces&&i<CFArrayGetCount(systemFaces.get());i++){
    auto d=static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(systemFaces.get(),i));OwnCF<CFTypeRef> name(CTFontDescriptorCopyAttribute(d,kCTFontFamilyNameAttribute));
    if(name&&CFEqual(name.get(),CFSTR("Helvetica")))CFArrayAppendValue(family.get(),d);
  }
  NSDictionary* result=canary&&light&&CFArrayGetCount(family.get())>0?Run(canary,light,family.get(),SystemFontPolicyV1Enabled()):@{@"cases":@[],@"complete":@NO};
  bool removed=CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url,kCTFontManagerScopeProcess,&error);if(error)CFRelease(error);
  NSMutableDictionary* output=[result mutableCopy];output[@"schemaVersion"]=@1;output[@"policy"]=@(SystemFontPolicyV1Enabled());output[@"registrationScope"]=@"process";output[@"ownCanaryAbsentBefore"]=@(absent);output[@"ownRegistrationRemoved"]=@(removed);output[@"actualSkia"]=@YES;output[@"browserQualified"]=@NO;
  NSData* data=[NSJSONSerialization dataWithJSONObject:output options:0 error:nil];if(!data)return 67;fwrite(data.bytes,1,data.length,stdout);putchar('\n');return [result[@"complete"] boolValue]&&removed?0:1;
}}
