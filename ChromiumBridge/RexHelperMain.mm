#import <Foundation/Foundation.h>

#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

#include <array>
#include <map>
#include <string>

#include "RexSiteCompatibilityPolicy.h"

#if !defined(ARCH_CPU_ARM64)
#error "Rex Helper supports Apple Silicon only."
#endif

namespace {

struct RexExtensionActionContext {
  int tab_id = 0;
};

std::string RexChromiumVersionString() {
  return std::to_string(CHROME_VERSION_MAJOR) + "." +
      std::to_string(CHROME_VERSION_MINOR) + "." +
      std::to_string(CHROME_VERSION_BUILD) + "." +
      std::to_string(CHROME_VERSION_PATCH);
}

CefRefPtr<CefListValue> RexChromeBrandVersionList(bool full_version) {
  const std::string version = full_version
      ? RexChromiumVersionString()
      : std::to_string(CHROME_VERSION_MAJOR);
  const std::string grease_version = full_version ? "99.0.0.0" : "99";
  struct BrandVersion {
    const char *brand;
    std::string version;
  };
  const std::array<BrandVersion, 3> values = {{
      {"Not=A?Brand", grease_version},
      {"Google Chrome", version},
      {"Chromium", version},
  }};
  CefRefPtr<CefListValue> list = CefListValue::Create();
  list->SetSize(values.size());
  for (size_t index = 0; index < values.size(); ++index) {
    CefRefPtr<CefDictionaryValue> value = CefDictionaryValue::Create();
    value->SetString("brand", values[index].brand);
    value->SetString("version", values[index].version);
    list->SetDictionary(index, value);
  }
  return list;
}

std::string RexChromeCompatibilityUserAgentDataJSON() {
  NSOperatingSystemVersion os_version =
      NSProcessInfo.processInfo.operatingSystemVersion;
  const std::string platform_version =
      std::to_string(os_version.majorVersion) + "." +
      std::to_string(os_version.minorVersion) + "." +
      std::to_string(os_version.patchVersion);

  CefRefPtr<CefDictionaryValue> metadata = CefDictionaryValue::Create();
  metadata->SetList("brands", RexChromeBrandVersionList(false));
  metadata->SetList("fullVersionList", RexChromeBrandVersionList(true));
  metadata->SetString("uaFullVersion", RexChromiumVersionString());
  metadata->SetString("platform", "macOS");
  metadata->SetString("platformVersion", platform_version);
  metadata->SetString("architecture", "arm");
  metadata->SetString("bitness", "64");
  metadata->SetString("model", "");
  metadata->SetBool("mobile", false);
  metadata->SetBool("wow64", false);
  CefRefPtr<CefListValue> form_factors = CefListValue::Create();
  form_factors->SetSize(1);
  form_factors->SetString(0, "Desktop");
  metadata->SetList("formFactors", form_factors);

  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(metadata);
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

void RexInstallChromeCompatibilityUserAgentData(
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefV8Context> context) {
  if (!frame || !context ||
      !rex::site_compatibility::ShouldUseChromeCompatibilityIdentity(
          frame->GetURL().ToString())) {
    return;
  }
  const std::string metadata_json =
      RexChromeCompatibilityUserAgentDataJSON();
  if (metadata_json.empty()) return;

  const std::string script =
      "(() => {"
      "if (navigator.userAgentData) return;"
      "const metadata=" + metadata_json + ";"
      "const freezeList=list=>Object.freeze(list.map(item=>"
      "Object.freeze(Object.assign({},item))));"
      "const brands=freezeList(metadata.brands);"
      "const fullVersionList=freezeList(metadata.fullVersionList);"
      "const formFactors=Object.freeze(metadata.formFactors.slice());"
      "class NavigatorUAData {"
      "constructor(token){if(token!==metadata)throw new TypeError('Illegal constructor');}"
      "get brands(){return brands;}"
      "get mobile(){return metadata.mobile;}"
      "get platform(){return metadata.platform;}"
      "getHighEntropyValues(hints=[]){"
      "const requested=new Set(Array.from(hints));"
      "const values={brands,mobile:metadata.mobile,platform:metadata.platform};"
      "for(const hint of requested){"
      "if(hint==='fullVersionList')values.fullVersionList=fullVersionList;"
      "else if(hint==='formFactors')values.formFactors=formFactors;"
      "else if(Object.prototype.hasOwnProperty.call(metadata,hint))"
      "values[hint]=metadata[hint];"
      "}"
      "return Promise.resolve(values);"
      "}"
      "toJSON(){return {brands,mobile:metadata.mobile,platform:metadata.platform};}"
      "get [Symbol.toStringTag](){return 'NavigatorUAData';}"
      "}"
      "const userAgentData=Object.freeze(new NavigatorUAData(metadata));"
      "try{Object.defineProperty(globalThis,'NavigatorUAData',"
      "{configurable:true,value:NavigatorUAData});}catch{}"
      "try{Object.defineProperty(Navigator.prototype,'userAgentData',"
      "{configurable:true,enumerable:true,get(){return userAgentData;}});return;}"
      "catch{}"
      "try{Object.defineProperty(navigator,'userAgentData',"
      "{configurable:true,enumerable:true,value:userAgentData});}catch{}"
      "})();";
  CefRefPtr<CefV8Value> result;
  CefRefPtr<CefV8Exception> exception;
  context->Eval(script, frame->GetURL(), 0, result, exception);
}

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
    if (!browser || !frame || !context) return;
    RexInstallChromeCompatibilityUserAgentData(frame, context);
    if (!frame->IsMain()) return;
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
