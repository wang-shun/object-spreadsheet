
if Meteor.isClient
  Router.route "/:sheet/apps/beta", ->
    @render "DearBeta", data: {sheet: @params.sheet}

  Template.DearBeta.created = ->
    Relsheets.open(@data?.sheet, 'beta')

  Template.DearBeta.helpers
    files: ->
      obj = Relsheets.read()
      obj.File

  Template.DearBeta.events
    "click .Request .up": ->
      Relsheets.call("requestUp", {at: [@Request.qFamilyId.cellId]})
    "click .Request .down": ->
      Relsheets.call("requestDown", {at: [@qCellId.cellId]})
    "click .Hint .up": ->
      Relsheets.call("hintUp", {at: [@Vote.qFamilyId.cellId]})
    "click .Hint .down": ->
      Relsheets.call("hintDown", {at: [@qCellId.cellId]})
    "click .Hint .del": ->
      Relsheets.call("hintDel", {at: [@qCellId.cellId]})
    "submit form": (event) ->
      Relsheets.call(
        "hintAdd",
        {at: [@Hint.qFamilyId.cellId], text: [event.target.text.value]},
        (error, result) -> if !error? then event.target.reset())
      false


if Meteor.isServer
  
  Relsheets.procedures "beta",
    requestUp:
      params: [['at', 'File:Node:Time']]
      body: '''new at.Request'''
    requestDown:
      params: [['at', 'File:Node:Time']]
      body: '''delete oneOf(at.Request)'''
    hintUp:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''new at.Vote'''
    hintDown:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''delete oneOf(at.Vote)'''
    hintAdd:
      params: [['at', 'File:Node:Time'], ['text', '_string']]
      body: '''let h = new at.Hint
               h.body := text'''
    hintDel:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''delete at'''
