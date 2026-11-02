// Let archived evidence.html render inside Jenkins with its inline CSS.
// Scripts stay blocked (no 'script-src'), so a malicious report still cannot run JavaScript.
System.setProperty(
    "hudson.model.DirectoryBrowserSupport.CSP",
    "sandbox allow-same-origin; default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline';"
)
