
class Announce
  instances = {}
  @get: (id) ->
    if (v = instances[id])? then v
    else instances[id] = new @ id

class OnDemand extends Announce
  listeners = {create: []}
  constructor: ->
    for cb in listeners.create
      try
        cb.apply @
      catch e
        console.log e.stack
  @onCreate: (op) -> listeners.create.push op


class ControlContext extends OnDemand
  constructor: ->
    @scheduled = []
    super()
  @get: (id) ->
    if !id? then (Meteor.isServer && CallingContext.get()) || @.default else super(id)
  run: (func=->) ->
    CallingContext.set @, =>
      while @scheduled.length > 0
        @scheduled.pop().apply @
      func.apply @
  do: (task) -> @scheduled.push task

  # Convenience method;
  # calls a Meteor method, passing the current cc as first argument
  call: (method, args...) ->
    Meteor.call method, @, args...


exported = (d) ->
  for k,v of d
    @[k] = v

exported {exported, Announce, OnDemand, ControlContext}
