
if Meteor.isClient
  Router.route "/:sheet/apps/maid", ->
    @render "MilkMaid", data: {sheet: @params.sheet}

  Template.MilkMaid.created = ->
    Relsheets.open(@data?.sheet, 'milk')

  Template.MilkMaid.helpers
    milk: -> Relsheets.read()
    
  Template.MilkMaid.events
    "click button": ->
      Relsheets.call("supply", {@me})

      
if Meteor.isServer

  Relsheets.procedures 'milk',
    supply:
      params: [['me', 'Cycle']]
      body: '''me.lastTime := d"now" '''
