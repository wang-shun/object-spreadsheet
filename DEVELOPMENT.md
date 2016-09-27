# Development notes

This file covers some things you may need to know in order to work on Object Spreadsheets.  Many topics are described in greater detail in the files that implement them.

Matt and Shachar have additional information on many of these topics that has not been written up.  Feel free to ask us before you spend a significant amount of time researching something yourself.

## System requirements

While Object Spreadsheets builds and runs from a git checkout on Windows, some of our development tools off of the build-run path assume a unix-like environment.  `merge-typings` is in Python because that's what Matt knew best for the task; it could probably be ported to Node.js if we cared.

## Coding guidelines

See [CODING_GUIDELINES.md](CODING_GUIDELINES.md).

## git submodules

When we need to use a modified version of software that is provided in a git repository, we maintain our modified version in a separate repository in the [objsheets Bitbucket organization](https://bitbucket.org/objsheets/) and embed it in the main project as a git submodule.  Submodules have the advantage of keeping the submodule and main project history cleanly separated but can be a hassle to manage; the `git subtree` contrib tool may have significant advantages but FBOFW Matt doesn't want to depend on it.

Each tree in the main repository contains a pointer to a commit in the submodule.  The HEAD value of the submodule plays the role of the working tree content at the submodule's path in the main repository, except that it is _not_ automatically updated by any of the commands that normally update the working tree, but only by `git submodule update` (which automatically downloads the referenced commit from the submodule's central repository if necessary).  A common mistake is to forget to run `git submodule update`, leaving the old submodule commit as the working tree content (which appears as a "change not staged for commit" in `git status`), and later commit the old pointer back into the main repository.  (TODO (Matt): file an enhancement request for git to handle this better!)

Before pushing a change to a submodule pointer, you must push the target commit to (some branch of) the submodule's central repository to make it available to others.  If you plan to push changes to submodules, we urge you to use git 2.7.0 or newer and set `push.recurseSubmodules = check` in the `.git/config` file of your main repository (or even in `~/.gitconfig`) so that git will stop you from accidentally pushing a dangling pointer.  For the most part, the `master` branch of the main repository corresponds to the `objsheets` branch of a submodule (to avoid confusion with the upstream `master`), while other branches of the main repository that relate to the submodule correspond to submodule branches of the same names.

`git clone --recursive` automatically sets up all submodules.  After you pull a change that adds a submodule, use `git submodule update --init` to set it up.  When you pull a change that removes a submodule, the directory will be left behind and you can delete it (assuming you didn't make any changes to it that you want to keep).

## Meteor

Object Spreadsheets is an application in the [Meteor](https://www.meteor.com/) web framework.  We chose Meteor because it worked well for [Sunny](https://github.com/aleksandarmilicevic/sunny.js), a related previous project in our research group, and indeed we've found that it gives us a lot of help with the boring parts of a data-heavy web application.

See the [Meteor API documentation](https://docs.meteor.com/) and additional topics in the [Meteor guide](https://guide.meteor.com/).

Meteor automatically scans the entire project directory for different kinds of files as described in the [Application Structure article](https://guide.meteor.com/structure.html#special-directories), with the exception of a few directories, the documented one being `tests`.  So we use the `tests` directory for anything that Meteor doesn't need to touch and that we want to make sure doesn't trip Meteor up.  It's a misnomer. :/

## IDEs

We primarily use and support [Visual Studio Code](https://code.visualstudio.com/).  Visual Studio Code shows TypeScript errors for the currently open files as you type; lint warnings are shown in the same way if you install the [tslint extension](https://marketplace.visualstudio.com/items?itemName=eg2.tslint).  The build command (Ctrl-Shift-B) is set up to run both the TypeScript compiler and the linter on the whole project and display errors and warnings in the Problems pane.

In the past, we had some support for Eclipse using [Palantir's TypeScript plugin](https://github.com/palantir/eclipse-typescript), but this is broken as of 2016-09-20 because we have started to use TypeScript 2.0 features and the Palantir plugin uses TypeScript 1.8 and doesn't let us substitute our own version.

## Selected important files

* `src/common.ts`, `src/data.ts`: Definitions related to the data model that are used on both client and server.
* `src/server/model.ts`: Data-model class that implements nontrivial updates to the data or schema.  Trivial ones are written directly to the database by the client.
* `src/client/sheet.ts`, `src/client/actions.ts`: The bulk of the code for the spreadsheet UI.
* `src/language`: Support for the formula and procedure language, including the interpreter.
* `private/dump`: Dump files for example applications that are automatically loaded when you visit the sheet of the corresponding name for the first time.  (Not all of these are listed on the server's home page.)
* `apps`: Hard-coded application UIs and stored procedures for example applications.

## TypeScript

All of our code is in [TypeScript](http://www.typescriptlang.org/), a language based on JavaScript with optional static typing.  Typing catches a significant fraction of our silly mistakes up front and enables IDEs to cross-reference the code for navigation and (in theory) refactoring.  However, many type annotations are missing (`fixmeAny`) because we never added them after we converted the code from CoffeeScript in February 2016, and indeed, we're unsure if it's possible to statically type all the coding patterns we use (or our libraries force on us).  Thus, developers should be aware of the risk that "find all references" or refactoring misses something.

All of our code is in a TypeScript namespace (a.k.a. internal module) `Objsheets`.  Items marked `export` can be used in any file by unqualified names; items not marked `export` can only be used in the same file.  This is the same organization that the TypeScript compiler uses.  Both TypeScript and Meteor are heavily encouraging the use of ECMAScript 6 modules (called external modules by TypeScript), but such a structure would require us to qualify every reference to an item defined in a different file, which seems to Matt to be a big hassle for no practical benefit at the current scale of the codebase.

Our TypeScript code is compiled using the Meteor build plugin in our modified version of the `hansoft:typescript` Meteor package, which is in the `packages/hansoft_typescript` submodule.  This package also determines the versions of TypeScript and tslint used by all of our other development tools.  The `hansoft:typescript` build plugin compiles all source files in a single scope, just like `tsc -p .`.  The `barbatus:typescript` plugin is more sophisticated and will likely be officially endorsed by Meteor in the future, but it does not have an option to compile all source files in a single scope (it promotes the use of external modules, for which scope is not an issue), so for now we prefer to pay the cost of maintaining our version of `hansoft:typescript` rather than the cost of clutter in our code.

Our code is checked against type declaration files for external libraries, which are kept in `typings/`.  Some of these are modified from their original third-party sources.  Use the `typings` tool to add, update, or remove the original declaration files in `tests/typings.upstream/` and then run the `merge-typings` tool to merge those changes into `typings/`, preserving our modifications.

## Dependencies

Object Spreadsheets depends on several unmodified external libraries, which are automatically downloaded by the `objsheets-npm-deps` wrapper package.  It also uses a modified version of the [Handsontable](https://github.com/handsontable/handsontable) spreadsheet widget, which comes from sources in the `src` subdirectory of the `tests/handsontable` submodule and has compiled files checked in to `public/handsontable`.  Use `update-handsontable` to update the compiled files from the sources.  (Since the spreadsheet widget forms the core of our custom UI, it's unsurprising that we need some features that the original Handsontable currently doesn't support.  Many of them could conceivably be upstreamed, but we haven't pursued it.)

## Deployment

The settings file `multiuser.settings` can be used to configure the server so that each visitor gets their own instances of the example applications.
