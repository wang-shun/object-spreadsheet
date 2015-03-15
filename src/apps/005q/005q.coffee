
if Meteor.isClient
  Router.route "/005q/apps", -> @render "DoubleOhFiveQueue", data: {sheet: '005q'}

  Template.DoubleOhFiveQueue.created = ->
    Tablespace.default = Tablespace.get @data?.sheet
    $$.call 'compileProcedures', @data?.sheet

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

  Meteor.methods
    define005qProcedures: (cc) ->
      cc.run ->
        # This may run multiple times; it should overwrite and not cause any problems.
        try
          for name, proc of procedures
            @model.cannedTransactions.set(
              name, parseCannedTransaction(proc.params, proc.body))
        catch e
          # Incompatible schema change?
          console.log("Failed to define 005q sample procedure #{name}:", e.stack)
