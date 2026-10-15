// Copyright 2026 NeAntik Authors. SPDX-License-Identifier: MPL-2.0
#include "components/ungoogled/font_qa_witness_mac.h"

#include <CoreText/CoreText.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <memory>
#include <string>

#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/no_destructor.h"
#include "base/posix/eintr_wrapper.h"
#include "base/strings/string_number_conversions.h"
#include "base/time/time.h"
#include "base/threading/platform_thread.h"
#include "crypto/hash.h"

namespace ungoogled::nevision {
namespace {
using base::apple::ScopedCFTypeRef;
constexpr char kRequest[] = "NEANTIK_FONT_QA";
constexpr char kRoot[] = "NEANTIK_FONT_QA_ROOT";
constexpr char kNonce[] = "NEANTIK_FONT_QA_NONCE";
constexpr char kApproved[] = "NEANTIK_FONT_QA_APPROVED";
constexpr char kPrefix[] = "/private/tmp/neantik-font-policy-qa.";

bool IsNonce(const std::string& value) {
  return value.size() == 32 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool RequestValues(std::string* root, std::string* nonce) {
  auto env = base::Environment::Create();
  *root = env->GetVar(kRoot).value_or("");
  *nonce = env->GetVar(kNonce).value_or("");
  return env->GetVar(kRequest) == "owned-v1" && IsNonce(*nonce) &&
         *root == std::string(kPrefix) + *nonce;
}
bool Browser() {
  return !base::CommandLine::ForCurrentProcess()->HasSwitch("type");
}
bool PrivateFD(int fd, bool directory) {
  struct stat value;
  if (fd < 0 || fstat(fd, &value) || value.st_uid != geteuid() || value.st_flags ||
      (value.st_mode & 07777) != (directory ? 0700 : 0600) ||
      (directory ? !S_ISDIR(value.st_mode) : (!S_ISREG(value.st_mode) || value.st_nlink != 1)))
    return false;
  errno = 0;
  acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
  if (!acl)
    return errno == ENOENT;
  acl_entry_t entry = nullptr;
  errno = 0;
  const int result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
  const int error = errno;
  acl_free(acl);
  return result == -1 && error == EINVAL && !entry;
}
bool SameEntry(int parent, const char* name, int fd) {
  struct stat retained, named;
  return fstat(fd, &retained) == 0 &&
         fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
         retained.st_dev == named.st_dev && retained.st_ino == named.st_ino;
}
struct Custody {
  base::ScopedFD parent, root, profile, crashes, marker, log;
  std::string name;
  bool Validate() const {
    return PrivateFD(root.get(), true) && PrivateFD(profile.get(), true) &&
           PrivateFD(crashes.get(), true) && PrivateFD(marker.get(), false) &&
           PrivateFD(log.get(), false) && SameEntry(parent.get(), name.c_str(), root.get()) &&
           SameEntry(root.get(), "profile", profile.get()) &&
           SameEntry(root.get(), "crashes", crashes.get()) &&
           SameEntry(root.get(), "marker", marker.get()) &&
           SameEntry(root.get(), "witness.log", log.get());
  }
};
Custody& Owned() {
  static base::NoDestructor<Custody> value;
  return *value;
}
bool FixedArguments(const std::string& root) {
  const auto& cmd = *base::CommandLine::ForCurrentProcess();
  return cmd.GetSwitchValuePath("user-data-dir").value() == root + "/profile" &&
         cmd.GetSwitchValuePath("log-file").value() == root + "/witness.log" &&
         cmd.GetSwitchValueASCII("enable-logging") == "stderr" &&
         !cmd.HasSwitch("no-sandbox") && !cmd.HasSwitch("disable-web-security");
}
// Use the existing inherited stderr transport. No sandbox exception, tmp write,
// personal font inventory or arbitrary path is exposed by the renderer.
bool Ack(const std::string& nonce) {
  const std::string line = "NEANTIK_FONT_QA_V1 nonce=" + nonce +
      " pid=" + base::NumberToString(getpid()) +
      " role=" + (Browser() ? "browser" : "renderer") +
      " complete=1 unique=1 family=1\n";
  return HANDLE_EINTR(write(STDERR_FILENO, line.data(), line.size())) ==
         static_cast<ssize_t>(line.size());
}
struct Registration {
  std::atomic<bool> done{false};
  std::atomic<bool> error{false};
};
bool SelectedFrom(CFStringRef name, CFURLRef source, CFStringRef postscript) {
  ScopedCFTypeRef<CTFontRef> font(CTFontCreateWithName(name, 18, nullptr));
  if (!font)
    return false;
  ScopedCFTypeRef<CFStringRef> actual(CTFontCopyPostScriptName(font.get()));
  ScopedCFTypeRef<CFTypeRef> url(CTFontCopyAttribute(font.get(), kCTFontURLAttribute));
  return actual && url && CFGetTypeID(url.get()) == CFURLGetTypeID() &&
         CFEqual(actual.get(), postscript) && CFEqual(url.get(), source);
}
}  // namespace

bool FontQARequested() {
  auto env = base::Environment::Create();
  return env->HasVar(kRequest) || env->HasVar(kRoot) || env->HasVar(kNonce) ||
         env->HasVar(kApproved);
}
bool PrepareFontQAProcess() {
  if (!FontQARequested())
    return true;
  auto env = base::Environment::Create();
  if (!Browser())
    return ValidateFontQAProcess();
  // Never trust an approval supplied by the caller of the browser process.
  env->UnSetVar(kApproved);
  std::string root, nonce;
  if (!RequestValues(&root, &nonce) || !FixedArguments(root))
    return false;
  Custody& state = Owned();
  state.name = base::FilePath(root).BaseName().value();
  state.parent.reset(HANDLE_EINTR(open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)));
  if (!state.parent.is_valid())
    return false;
  state.root.reset(HANDLE_EINTR(openat(state.parent.get(), state.name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)));
  if (!state.root.is_valid())
    return false;
  auto child = [&state](const char* name, bool directory) {
    return HANDLE_EINTR(openat(state.root.get(), name,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : O_NONBLOCK)));
  };
  state.profile.reset(child("profile", true));
  state.crashes.reset(child("crashes", true));
  state.marker.reset(child("marker", false));
  state.log.reset(child("witness.log", false));
  if (!state.Validate())
    return false;
  const std::string expected = "NeAntikFontPolicyQA-v1\n" + nonce + "\n";
  char bytes[128];
  const ssize_t count = HANDLE_EINTR(pread(state.marker.get(), bytes, sizeof(bytes), 0));
  if (count != static_cast<ssize_t>(expected.size()) || std::string(bytes, count) != expected)
    return false;
  // Crashpad otherwise derives a default path independently of user-data-dir.
  return env->SetVar("BREAKPAD_DUMP_LOCATION", root + "/crashes");
}
bool ValidateFontQAProcess() {
  if (!FontQARequested())
    return true;
  std::string root, nonce;
  if (!RequestValues(&root, &nonce))
    return false;
  auto env = base::Environment::Create();
  if (env->GetVar("BREAKPAD_DUMP_LOCATION") != root + "/crashes")
    return false;
  if (Browser())
    return FixedArguments(root) && Owned().Validate();
  // Child processes are already sandboxed: no attempt to reopen the marker.
  // The browser verified custody; kernel PID/generation is checked by harness.
  return env->GetVar(kApproved) == nonce &&
         base::CommandLine::ForCurrentProcess()->GetSwitchValuePath("user-data-dir").value() == root + "/profile";
}
bool ValidateFontQAProfile(const base::FilePath& effective, bool approve) {
  if (!FontQARequested())
    return true;
  std::string root, nonce;
  if (!RequestValues(&root, &nonce) || effective.value() != root + "/profile" ||
      !ValidateFontQAProcess())
    return false;
  return !approve || !Browser() || base::Environment::Create()->SetVar(kApproved, nonce);
}
bool RegisterFontQAWitness() {
  if (!FontQARequested())
    return true;
  if (!ValidateFontQAProcess())
    return false;
  std::string root, nonce;
  if (!RequestValues(&root, &nonce) || base::Environment::Create()->GetVar(kApproved) != nonce)
    return false;
  // Exactly these two original QA resources; never a caller-supplied font.
  constexpr const char* names[] = {"owned-canary.ttf", "owned-family-collision.ttf"};
  constexpr const char* hashes[] = {"f442b055b908db3c277bb603d0ad188c385e2050312b0ee6a6ae6512c3b266de", "9932ad8299abfa1ab4fb565fd0bf3a211c2818678ff30cb8ac3355602ae27c56"};
  ScopedCFTypeRef<CFMutableArrayRef> urls(CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
  for (size_t i = 0; i < 2; ++i) {
    const auto path = base::apple::PathForFrameworkBundleResource(names[i]);
    std::string bytes;
    if (path.empty() || !base::ReadFileToStringWithMaxSize(path, &bytes, 4096) ||
        base::HexEncodeLower(crypto::hash::Sha256(bytes)) != hashes[i])
      return false;
    ScopedCFTypeRef<CFURLRef> url(CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(path.value().data()), path.value().size(), false));
    if (!url)
      return false;
    CFArrayAppendValue(urls.get(), url.get());
  }
  auto completion = std::make_shared<Registration>();
  CTFontManagerRegisterFontURLs(urls.get(), kCTFontManagerScopeProcess, true,
      ^bool(CFArrayRef errors, bool done) {
        if (CFArrayGetCount(errors))
          completion->error.store(true);
        if (done)
          completion->done.store(true);
        return true;
      });
  const auto deadline = base::TimeTicks::Now() + base::Seconds(10);
  while (!completion->done.load() && base::TimeTicks::Now() < deadline) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    base::PlatformThread::Sleep(base::Milliseconds(5));
  }
  if (!completion->done.load() || completion->error.load() ||
      !SelectedFrom(CFSTR("NeAntikFontPolicyCanary"),
          static_cast<CFURLRef>(CFArrayGetValueAtIndex(urls.get(), 0)), CFSTR("NeAntikFontPolicyCanary")) ||
      !SelectedFrom(CFSTR("Helvetica"),
          static_cast<CFURLRef>(CFArrayGetValueAtIndex(urls.get(), 1)), CFSTR("NeAntikFontPolicyFamilyCollision")))
    return false;
  return Ack(nonce);
}
}  // namespace ungoogled::nevision
