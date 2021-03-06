// Workaround for Blaze._reportException logging the exception stack, which does
// not include the exception message in Firefox.
// https://github.com/meteor/meteor/issues/2232:


namespace Objsheets {

  let exceptionStackIncludesMessage = /hello/.test(new Error("hello").stack);

  if (!exceptionStackIncludesMessage) {
    // It might be better to hook e.stack on all Error objects if we had a good way to do that.
    let origReportException = Blaze._reportException;
    Blaze._reportException = (e, msg) => {
      e.stack = e.message + "\n" + e.stack;
      origReportException(e, msg);
    };
  }

}
