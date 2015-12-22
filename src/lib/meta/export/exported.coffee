
exported = (d) ->
  for k,v of d
    @[k] = v


exported {exported}
