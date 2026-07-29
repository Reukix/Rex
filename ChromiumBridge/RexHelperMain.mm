#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

#include <map>
#include <string>

#if !defined(ARCH_CPU_ARM64)
#error "Rex Helper supports Apple Silicon only."
#endif

namespace {

struct RexExtensionActionContext {
  int tab_id = 0;
};

class RexHelperApp final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnBrowserCreated(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> extra_info) override {
    if (!browser || !extra_info ||
        !extra_info->HasKey("rexExtensionActionTabID")) {
      return;
    }
    RexExtensionActionContext context;
    context.tab_id = extra_info->GetInt("rexExtensionActionTabID");
    if (context.tab_id > 0) {
      extension_action_contexts_[browser->GetIdentifier()] =
          std::move(context);
    }
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    if (browser) {
      extension_action_contexts_.erase(browser->GetIdentifier());
    }
  }

  void OnContextCreated(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefV8Context> context) override {
    if (!browser || !frame || !frame->IsMain() || !context) return;
    const auto entry =
        extension_action_contexts_.find(browser->GetIdentifier());
    if (entry == extension_action_contexts_.end()) return;

    // Only bridge Chromium's numeric tab identity. tabs.get() below supplies
    // the permission-filtered Tab object, so Rex never injects URL or title.
    CefRefPtr<CefDictionaryValue> source = CefDictionaryValue::Create();
    source->SetInt("id", entry->second.tab_id);
    CefRefPtr<CefValue> source_value = CefValue::Create();
    source_value->SetDictionary(source);
    const std::string source_json =
        CefWriteJSON(source_value, JSON_WRITER_DEFAULT).ToString();
    if (source_json.empty()) return;

    const std::string script =
        "(() => {"
        "const marker = Symbol.for('rex.extensionActionContext');"
        "if (globalThis[marker]) return;"
        "const source = Object.freeze(" + source_json + ");"
        "const install = () => {"
        "const namespaces = [globalThis.browser, globalThis.chrome];"
        "let installed = false;"
        "for (const namespace of namespaces) {"
        "const tabs = namespace && namespace.tabs;"
        "if (!tabs || typeof tabs.query !== 'function') continue;"
        "const originalQuery = tabs.query.bind(tabs);"
        "const originalGet = typeof tabs.get === 'function'"
        " ? tabs.get.bind(tabs) : null;"
        "const sourceResult = originalTab => {"
        "const original = Array.isArray(originalTab)"
        " ? originalTab.find(tab => tab && tab.id === source.id)"
        " : originalTab;"
        "if (!original || original.id !== source.id"
        " || !Number.isInteger(original.windowId)) return [];"
        "return [Object.freeze(Object.assign({}, original,"
        " {active: true, highlighted: true}))];"
        "};"
        "const requestSource = callback => {"
        "if (originalGet) return originalGet(source.id, callback);"
        "return originalQuery({}, callback);"
        "};"
        "const requestSourcePromise = () => originalGet"
        " ? originalGet(source.id) : originalQuery({});"
        "const actionQuery = (queryInfo, callback) => {"
        "const useSource = queryInfo && queryInfo.active === true"
        " && (queryInfo.currentWindow === true"
        " || queryInfo.lastFocusedWindow === true);"
        "if (!useSource) return originalQuery(queryInfo, callback);"
        "if (typeof callback === 'function') {"
        "try {"
        "return requestSource(originalTab => {"
        "const result = sourceResult(originalTab);"
        "queueMicrotask(() => callback(result));"
        "});"
        "} catch {"
        "queueMicrotask(() => callback(sourceResult())); return;"
        "}"
        "}"
        "try {"
        "return Promise.resolve(requestSourcePromise())"
        ".then(sourceResult, () => sourceResult());"
        "} catch { return Promise.resolve(sourceResult()); }"
        "};"
        "try {"
        "Object.defineProperty(tabs, 'query', {"
        "configurable: true, value: actionQuery"
        "});"
        "} catch { try { tabs.query = actionQuery; } catch {} }"
        "if (tabs.query !== actionQuery) continue;"
        "installed = true;"
        "if (typeof tabs.getCurrent === 'function') {"
        "const actionGetCurrent = callback => {"
        "if (typeof callback === 'function') {"
        "queueMicrotask(() => callback(undefined)); return;"
        "}"
        "return Promise.resolve(undefined);"
        "};"
        "try {"
        "Object.defineProperty(tabs, 'getCurrent', {"
        "configurable: true, value: actionGetCurrent"
        "});"
        "} catch { try { tabs.getCurrent = actionGetCurrent; } catch {} }"
        "}"
        "}"
        "if (!installed) return false;"
        "globalThis[marker] = source;"
        "return true;"
        "};"
        "if (install()) return;"
        "let attempts = 0;"
        "const retry = () => {"
        "if (install() || ++attempts >= 100) return;"
        "setTimeout(retry, 0);"
        "};"
        "setTimeout(retry, 0);"
        "})();";
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(script, frame->GetURL(), 0, result, exception);
  }

 private:
  std::map<int, RexExtensionActionContext> extension_action_contexts_;
  IMPLEMENT_REFCOUNTING(RexHelperApp);
};

}  // namespace

int main(int argc, char *argv[]) {
  CefScopedSandboxContext sandboxContext;
  if (!sandboxContext.Initialize(argc, argv)) return 1;

  CefScopedLibraryLoader libraryLoader;
  if (!libraryLoader.LoadInHelper()) return 2;

  CefMainArgs mainArgs(argc, argv);
  CefRefPtr<RexHelperApp> app = new RexHelperApp();
  return CefExecuteProcess(mainArgs, app, nullptr);
}
