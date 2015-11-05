if Meteor.isClient
  # Future: Make this better.
  standardServerCallback = (error, result) ->
    if error?
      alert('The operation failed on the server: ' + error.message)

  standardServerCallbackThen = (callback) ->
    (error, result) ->
      standardServerCallback(arguments...)
      callback?(arguments...)

  exported {standardServerCallback, standardServerCallbackThen}
