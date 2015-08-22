
if Meteor.isClient
  Router.route "/:sheet/apps/maid", ->
    @render "MilkMaid", data: {sheet: @params.sheet}

  Template.MilkMaid.created = ->
    Relsheets.open(@data?.sheet, 'milk')

  Template.MilkMaid.helpers
    milk: -> Relsheets.read()
    label: -> @['*']
    sameAs: (o) -> EJSON.equals(@qCellId, o[0]?.qCellId)
    stringify: (a) -> JSON.stringify(a)
    
  Template.MilkMaid.events
    "click button": ->
      Relsheets.call("supply", {@me})
    "click .marking": ->
      Relsheets.call("request", {level: @})

      
if Meteor.isServer

  Relsheets.procedures 'milk',
    supply:
      params: [['me', 'Cycle']]
      body: '''me.lastTime := d"now" 
               $Gauge.reading := {l: $Gauge.Level | l.`*` = "Full"}'''

    request:
      params: [['level', 'Gauge:Level']]
      body: '''$Gauge.reading := level'''
      