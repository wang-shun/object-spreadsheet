if Meteor.isClient
  Template.registerHelper('not', (x) -> !x)

  # Future: Make this better.
  standardServerCallback = (error, result) ->
    if error?
      alert('The operation failed on the server: ' + error.message)

  standardServerCallbackThen = (callback) ->
    (error, result) ->
      standardServerCallback(error, result)
      callback?(error, result)

  exported {standardServerCallback, standardServerCallbackThen}
