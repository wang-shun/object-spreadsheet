
if Meteor.isClient
  Router.route "/:sheet/apps/005q", ->
    @render "DoubleOhFiveQueue", data: {sheet: @params.sheet}

  Template.DoubleOhFiveQueue.created = ->
    Tablespace.default = Tablespace.get @data?.sheet
    $$.call 'compileProcedures', '005q'

  Template.DoubleOhFiveQueue.helpers
    root: -> Relsheets.read()
    sortBy: (objs, field) ->
      _.sortBy(objs, (x) -> x[field][0])

  Template.DoubleOhFiveQueue.events
    "submit form": (event) ->
      formData =
        time: [new Date().getTime()]   # should be done on server...
        name: [event.target.name.value]
        matter: [event.target.matter.value]
        location: [event.target.location.value]
      Relsheets.call("enqueue", formData, -> event.target.reset())
      false
    "click .pick": ->
      Relsheets.call("pick", {call: [@call.qCellId.cellId], user: [@user.qCellId.cellId]})
    "click .forfeit": ->
      Relsheets.call("forfeit", {call: [@call.qCellId.cellId]})
    "click .done": ->
      Relsheets.call("done", {call: [@call.qCellId.cellId]})


if Meteor.isServer

  Relsheets.procedures '005q',
    enqueue:
      params: [['time', '_int'],
               ['name', '_string'],
               ['matter', '_string'],
               ['location', '_string']]
      body: '''let q = new $Call
               q.time := time
               q.name := name
               q.location := location
               q.matter := {s : $Skill | s.name = matter}'''
    pick:
      params: [['call', 'Call'],
               ['user', 'Staff']]
      body: '''call.assign := user'''
    forfeit:
      params: [['call', 'Call']]
      body: '''call.assign := {}'''
    done:
      params: [['call', 'Call']]
      body: '''delete call'''
