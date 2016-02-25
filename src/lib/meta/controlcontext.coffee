
class @Announce
  instances = {}
  @get: (id) ->
    if (v = instances[id])? then v
    else instances[id] = new @ id

class @OnDemand extends Announce
  listeners = {create: []}
  constructor: ->
    for cb in listeners.create
      try
        cb.apply @
      catch e
        console.log e.stack
  @onCreate: (op) -> listeners.create.push op; return


class @ControlContext extends OnDemand
  constructor: ->
    @scheduled = []
    @lock = 0
    super()
  @get: (id) ->
    if !id? then (Meteor.isServer && CallingContext.get()) || @.default else OnDemand.get.call(this, id)
  run: (func=->) ->
    #Fiber = Npm.require('fibers')     # <-- tried to use Fiber.yield() but got "Fiber is a zombie" error ~~~~
    CallingContext.set @, =>
      if @lock then @scheduled.push func; return  # HACK
      else
        try
          @lock = 1
          while @scheduled.length > 0
            @scheduled.pop().apply @
        finally
          @lock = 0
        func.apply @
  do: (task) -> @scheduled.push task; return

  # Convenience method;
  # calls a Meteor method, passing the current cc as first argument
  call: (method, args...) ->
    Meteor.call method, @, args...
