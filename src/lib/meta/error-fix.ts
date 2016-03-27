// Workaround for Blaze._reportException logging the exception stack, which does
// not include the exception message in Firefox.
// https://github.com/meteor/meteor/issues/2232:


namespace Objsheets {

  let exceptionStackIncludesMessage = /hello/.test(new Error("hello").stack);

  if (!exceptionStackIncludesMessage) {
    // It might be better to hook e.stack on all Error objects if we had a good way to do that.
    function patchException(e: Error) {
      e.stack = e.message + "\n" + e.stack;
    }

    let origReportException = Blaze._reportException;
    Blaze._reportException = (e, msg) => {
      patchException(e);
      origReportException(e, msg);
    };

    let origBindEnvironment = Meteor.bindEnvironment;
    function newBindEnvironment<F extends Function>(func: F, onException: string | ((e: Error) => void), _this: any): F {
      // Code duplicated from Meteor.bindEnvironment.  I was tempted to use
      // Meteor.bindEnvironment.toString() and patch the source instead, but I
      // don't think we could get access to lexically enclosing variables that
      // way. ~ Matt 2016-03-26
      let onExceptionFunc: (e: Error) => void;
      if (!onException || typeof onException === "string") {
        let description = onException || "callback of async function";
        onExceptionFunc = function (error) {
          Meteor._debug(
            "Exception in " + description + ":",
            error && error.stack || error
          );
        };
      } else {
        onExceptionFunc = onException;
      }

      return origBindEnvironment(func, (e) => {
        patchException(e);
        onExceptionFunc(e);
      }, _this);
    }
    Meteor.bindEnvironment = newBindEnvironment;
  }

}
