namespace Objsheets {

  Template.registerHelper("not", (x: fixmeAny) => !x);

  // Future: Make this better.
  export function standardServerCallback(error: Error, result: fixmeAny) {
    if (error != null) {
      alert("The operation failed on the server: " + error.message);
    }
  }

  export function standardServerCallbackThen(callback: (error: Error, result: fixmeAny) => void) {
    return (error: fixmeAny, result: fixmeAny) => {
      standardServerCallback(error, result);
      if (typeof callback === "function") {
        callback(error, result);
      }
    };
  }

}
