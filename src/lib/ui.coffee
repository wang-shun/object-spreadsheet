if Meteor.isClient
  # Future: Make this better.
  standardServerCallback = (error, result) ->
    if error?
      alert('The operation failed on the server: ' + error.message)

  andThen = (cont) ->
    (error, result) ->
      if error?
        standardServerCallback(arguments...)
      else
        cont(result)

  exported {standardServerCallback, andThen}
