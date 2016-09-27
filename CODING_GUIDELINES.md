# Coding guidelines

Matt kindly requests that all code on the branches officially maintained by the Object Spreadsheets team (currently `master`) adhere to the following guidelines.  Either code should meet the guidelines before being pushed or any concerns should be raised in a pull request.  The guidelines cover the most common issues Matt has seen so far and do not take the place of common sense.  They are open to negotiation and will be revised with experience.

(For now, all of the guidelines are from me and I'm taking responsibility for the decision to impose them.  Of course, others may request guidelines as well, in which case this file will be revised accordingly. ~ Matt)

## Pass the linter

Our TypeScript code follows several of the tslint rules; see [tslint.json](tslint.json) for details and rationale.  To save time in the edit-build-run cycle, the Meteor build _does not_ check the lint rules.  Run `tests/dev-tools/check-code` (or press Ctrl-Shift-B in Visual Studio Code) to check your code before pushing it or sending it for review; no output means no problems were found.  In Visual Studio Code, the [tslint extension](https://marketplace.visualstudio.com/items?itemName=eg2.tslint) shows you lint warnings for the currently open files as you type, and it can fix some types of warnings automatically if you place the cursor on the affected code and click the lightbulb icon.

## Prioritize understandability

Our end goals for code style are understandability and maintainability; all other properties (conciseness, minimization of duplication, etc.) should be pursued only inasmuch as they aid understandability and maintability.

When a small piece of code is used in only one or two places, put it in a separate function or class only if that makes the caller(s) easier to understand.  One factor is whether you can give the helper a name good enough to remind everyone (not just yourself!) of the essential aspects of its behavior.

## Retain knowledge

If information will help people understand the code you are adding when they encounter it in the future, put it in a comment in addition to or instead of in the commit message.  If you did something tricky because the obvious approach didn't work, state what didn't work and why (if you know).  If we run into a problem with the tricky approach later, we'll want to assess whether it's easier to solve that problem or go back to the simple approach and solve the original problem.

## Manage complexity

Often it isn't worth writing code that behaves sensibly for 100% of the possible calls to the interfaces you define.  Document the major limitations of your code so that others know what is and is not expected to work and can endeavor to keep the former working.  Avoid introducing an interface that is gratuitously general compared to the cases you currently need and are implementing.  Finally, be sure you have consensus that functionality is really desired before introducing significant complexity to implement it.

## Type annotations

When you add a program element that requires a type annotation, please take a few seconds to see if a suitable type is already available.  If not, feel free to use `fixmeAny` or, if you're so inclined, investigate further changes that might make it possible to statically type your code.  Reserve `any` for cases in which you can articulate a rationale why the element is impractical to type statically (or typing it will do more harm than good), and state the rationale in a comment.  When the same rationale applies to many occurrences of `any`, define an alias `type any_xx = any;` in an appropriate library file and state the rationale there.  To maintain readability, `xx` should be a short abbreviation; readers can always "jump to definition" for more information.
