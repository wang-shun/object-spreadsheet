namespace Objsheets {

  Template.registerHelper("not", (x) => !x);

  // Future: Make this better.
  export function standardServerCallback(error, result) {
    if (error != null) {
      alert("The operation failed on the server: " + error.message);
    }
  }

  export function standardServerCallbackThen(callback) {
    return (error, result) => {
      standardServerCallback(error, result);
      if (typeof callback === "function") {
        callback(error, result);
      }
    };
  }

}
