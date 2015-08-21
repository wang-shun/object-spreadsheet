Package.describe({
  summary: "Datejs packaged for Meteor",
  version: "0.9.0",
  name: "datejs"
});

Package.onUse(function (api) {
  api.addFiles('date.js')
});
