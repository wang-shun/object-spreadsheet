Router.route "/:sheet/apps/beta", ->
  @render "DearBeta", data: {sheet: @params.sheet}
  return
Router.route "/:sheet/apps/split-view/beta", ->
  @render "DearBeta_Demo", data: {sheet: @params.sheet}
  return

Template['DearBeta'].created = ->
  RelsheetsClient.open(@data?.sheet, 'beta')
  return

Template['DearBeta'].helpers
  files: ->
    obj = RelsheetsClient.read()
    obj.File

Template['DearBeta'].events
  "click .Request .up": ->
    RelsheetsClient.call("requestUp", {at: [@Request.qFamilyId.cellId]})
    return
  "click .Request .down": ->
    RelsheetsClient.call("requestDown", {at: [@qCellId.cellId]})
    return
  "click .Hint .up": ->
    RelsheetsClient.call("hintUp", {at: [@Vote.qFamilyId.cellId]})
    return
  "click .Hint .down": ->
    RelsheetsClient.call("hintDown", {at: [@qCellId.cellId]})
    return
  "click .Hint .del": ->
    RelsheetsClient.call("hintDel", {at: [@qCellId.cellId]})
    return
  "submit form": (event) ->
    RelsheetsClient.call(
      "hintAdd",
      {at: [@Hint.qFamilyId.cellId], text: [event.target.text.value]},
      (error, result) -> (if !error? then event.target.reset()); return)
    false
