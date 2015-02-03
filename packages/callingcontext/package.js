Package.describe({
  summary: "Calling Context",
  version: "0.9.0",
  name: "callingcontext"
});

Package.onUse(function (api) {
  api.addFiles('callingcontext.js')
  api.export('CallingContext', 'server');
});
