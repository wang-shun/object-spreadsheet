namespace Objsheets {

  Template.registerHelper("not", (x: fixmeAny) => !x);

  // Future: Make this better.
  export function standardServerCallback(error: fixmeAny, result: fixmeAny) {
    if (error != null) {
      alert("The operation failed: " + error.message);
    }
  }

  export function standardServerCallbackThen(callback: fixmeAny) {
    return (error: fixmeAny, result: fixmeAny) => {
      standardServerCallback(error, result);
      if (typeof callback === "function") {
        callback(error, result);
      }
    };
  }

}
