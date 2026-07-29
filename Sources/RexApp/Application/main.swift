import SwiftUI

RexApp.main()

#if REX_CEF
// CEF on macOS must shut down only after NSApplication.run has returned.
RexChromiumRuntime.shared.shutdownAfterApplicationTermination()
#endif
