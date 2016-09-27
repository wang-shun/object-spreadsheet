// This Meteor package is used to incorporate content from npm packages into our
// app so we can upgrade the npm packages just by changing the version numbers
// here.
//
// Meteor encourages the use of npm packages via package.json in the app, but
// Matt is not willing to require users to run "npm install" as a separate
// command (https://github.com/meteor/meteor/issues/6848).  It's also unclear
// whether we'd be able to add files from npm packages to the "public"
// directory.  Symlinks would likely work, but they aren't supported on Windows
// (https://github.com/git-for-windows/git/wiki/Symbolic-Links), and Edward
// Doong wanted to run Object Spreadsheets on Windows.

Package.describe({
  name: 'objsheets-npm-deps',
  version: '0.0.1',
  summary: 'npm dependencies packaged for Object Spreadsheets',
});

Package.onUse(function(api) {
  // The datejs npm package does not include the concatenated file.
  // Fortunately, the Meteor build process is capable of gathering up all the
  // modules!
  api.use('modules');
  api.mainModule('datejs-loader.js');

  // These were previously loaded on all pages by src/client/sheet.html.
  // Maintaining that behavior for now.  If we want them only on the sheet, we
  // can add them as assets and load them from the Spreadsheet template, like
  // 005q does for semantic.min.css. ~ Matt 2016-09-16
  api.addFiles([
    '.npm/package/node_modules/codemirror/lib/codemirror.css',
    '.npm/package/node_modules/codemirror/lib/codemirror.js',
  ], 'client', {bare: true});

  // I tried unbundling semantic-ui (used by the 005q application UI).  There's
  // an npm package semantic-ui-css, but 005q is using version 0.12.1 and
  // doesn't seem to work with the latest version 2.2.4 (the UI was messed up),
  // and the semantic-ui-css package doesn't have a version 0.12.1 available.
  // So give up. ~ Matt 2016-09-16
});

Npm.depends({
  "codemirror": "5.18.2",
  "datejs": "1.0.0-rc3",
});
