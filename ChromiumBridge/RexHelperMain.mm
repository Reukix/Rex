#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

#if !defined(ARCH_CPU_ARM64)
#error "Rex Helper supports Apple Silicon only."
#endif

int main(int argc, char *argv[]) {
  CefScopedSandboxContext sandboxContext;
  if (!sandboxContext.Initialize(argc, argv)) return 1;

  CefScopedLibraryLoader libraryLoader;
  if (!libraryLoader.LoadInHelper()) return 2;

  CefMainArgs mainArgs(argc, argv);
  return CefExecuteProcess(mainArgs, nullptr, nullptr);
}
