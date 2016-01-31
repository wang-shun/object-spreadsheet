
if Meteor.isClient
  Router.route "/:sheet/apps/005q", ->
    @render "DoubleOhFiveQueue", data: {sheet: @params.sheet}

  Router.route "/:sheet/apps/005q/staff", ->
    @render "DoubleOhFiveQueueStaff", data: {sheet: @params.sheet}
    
  Router.route "/:sheet/apps/split-view/005q", ->
    @render "DoubleOhFiveQueue_Demo", data: {sheet: @params.sheet}

  Template.DoubleOhFiveQueue.created = ->
    Relsheets.open(@data?.sheet, '005q')

  Template.DoubleOhFiveQueueStaff.created = ->
    Relsheets.open(@data?.sheet, '005q')

  Template.DoubleOhFiveQueue.helpers
    root: -> Relsheets.read()
    sortBy: (objs, field) ->
      _.sortBy(objs, (x) -> x[field][0])
    people: (calls) ->
      count = calls?.length || 0
      "#{if count == 1 then "is" else "are"} " +
      "#{if count == 0 then "no" else count} " +
      "#{if count == 1 then "person" else "people"}"

  Template.DoubleOhFiveQueue.events
    "submit form": (event) ->
      formData =
        name: [event.target.name.value]
        issue: [event.target.issue.value]
        location: [event.target.location.value]
      Relsheets.call("enqueue", formData, (error, result) -> if !error? then event.target.reset())
      $('.help.button').addClass("disabled")
      false
      
    'keyup #name, #topic': ->
      helpButton = $('.help.button')
      if $('#name').val()
        helpButton.removeClass("disabled")
      else
        helpButton.addClass("disabled")

  Template.DoubleOhFiveQueueStaff.helpers
    root: -> Relsheets.read()
    
  Template.DoubleOhFiveQueueStaff.events
    "click .pick": ->
      Relsheets.call("pick", {@call, @user})
    "click .forfeit": ->
      Relsheets.call("forfeit", {@call, @user})
    "click .done": ->
      Relsheets.call("done", {@call})

    
if Meteor.isServer

  Relsheets.procedures '005q',
    enqueue:
      params: [['name', 'text'],
               ['issue', 'text'],
               ['location', 'text']]
      body: '''let q = new $Call
               q.time := d"now"
               q.name := name
               q.location := location
               q.issue := {s : $Skill | s.name = issue}'''
    pick:
      params: [['call', 'Call'],
               ['user', 'Staff']]
      body: '''call.assign := user'''
    forfeit:
      params: [['call', 'Call'],
               ['user', 'Staff']]
      body: '''call.assign := {}
               call.forfeit := user'''
    done:
      params: [['call', 'Call']]
      body: '''delete call'''
