// Lets the dashboard know the extension is installed (it hides Login until then).
document.documentElement.dataset.wtaExtension = chrome.runtime.getManifest().version;
