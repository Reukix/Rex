#pragma once

#include "include/cef_command_line.h"

// Thorium-inspired performance and runtime flags applied on top of the
// official CEF binary. These switches are the portable subset that does not
// require rebuilding Chromium from source.
namespace rex::thorium {

// Apply process-wide flags during CefApp::OnBeforeCommandLineProcessing.
void ApplyBrowserProcessFlags(CefRefPtr<CefCommandLine> command_line);

// Apply child-process flags during CefBrowserProcessHandler::OnBeforeChildProcessLaunch.
void ApplyChildProcessFlags(CefRefPtr<CefCommandLine> command_line);

// Human-readable profile name used by package metadata.
inline const char *ProfileName() { return "rex-thorium-hybrid-v1.3"; }

}  // namespace rex::thorium
