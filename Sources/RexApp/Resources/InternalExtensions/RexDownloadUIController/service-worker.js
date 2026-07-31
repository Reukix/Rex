async function disableChromiumDownloadUi(trigger) {
  try {
    await chrome.downloads.setUiOptions({ enabled: false });
    console.info(`[Rex] Chromium download UI disabled (${trigger})`);
  } catch (error) {
    console.error(`[Rex] Unable to disable Chromium download UI (${trigger})`, error);
  }
}

void disableChromiumDownloadUi("service-worker-start");

chrome.runtime.onInstalled.addListener(() => {
  void disableChromiumDownloadUi("extension-installed");
});

chrome.runtime.onStartup.addListener(() => {
  void disableChromiumDownloadUi("browser-startup");
});
