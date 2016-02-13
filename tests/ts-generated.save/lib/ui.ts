if (Meteor.isClient) {
  Template.registerHelper("not", (x) => !x);

  // Future: Make this better.
  function standardServerCallback(error, result) {
    if (error != null) {
      alert("The operation failed on the server: " + error.message);
    }
  }

  function standardServerCallbackThen(callback) {
    return (error, result) => {
      standardServerCallback(error, result);
      if (typeof callback === "function") {
        callback(error, result);
      }
    };
  }

  exported({
    standardServerCallback: standardServerCallback,
    standardServerCallbackThen: standardServerCallbackThen
  });
}
