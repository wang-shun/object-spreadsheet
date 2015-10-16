
if Meteor.isClient
  Router.route "/:sheet/apps/maid", ->
    @render "MilkMaid", data: {sheet: @params.sheet}

  Template.MilkMaid.created = ->
    Relsheets.open(@data?.sheet, 'milk')

  Template.MilkMaid.helpers
    milk: -> Relsheets.read()
    label: -> @['name']
    isNext: -> @isNext[0]
    sameAs: (o) -> EJSON.equals(@qCellId, o[0]?.qCellId)
    stringify: (a) -> JSON.stringify(a)
    
  Template.MilkMaid.events
    "click button": ->
      Relsheets.call("supply", {me: @})
    "click .marking": ->
      Relsheets.call("request", {level: @})

      
if Meteor.isServer

  Relsheets.procedures 'milk',
    supply:
      params: [['me', 'Cycle']]
      body: '''$Gauge.reading := {l: $Gauge.Level | l.name = "Full"}
               me.quota := me.quota - 2
               if (me.quota <= 0) {
                 me.lastTime := d"now" 
                 $Cycle.quota := 4      # reset all quotas
                 let m = new $Message
                 m.`to` := {c: $Cycle | c.isNext}
                 m.subject := "Heads Up: You Are Next"
               }'''

    request:
      params: [['level', 'Gauge:Level']]
      body: '''$Gauge.reading := level
               let m = new $Message
               m.`to` := {c: $Cycle | c.isNext}
               m.subject := "Milk Level Alert" '''

    # We can change the semantics of the button request here as desired.
    dashButtonRequest:
      params: []
      body: '''$Gauge.reading := {l: $Gauge.Level | l.name = "Empty"}
               let m = new $Message
               m.`to` := {c: $Cycle | c.isNext}
               m.subject := "Milk Level Alert" '''
