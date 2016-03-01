Router.route "/:sheet/apps/maid", ->
  @render "MilkMaid", data: {sheet: @params.sheet}
  return

Router.route "/:sheet/apps/split-view/milk", ->
  @render "MilkMaid_Demo", data: {sheet: @params.sheet}
  return

Template['MilkMaid'].created = ->
  RelsheetsClient.open(@data?.sheet, 'milk')
  return

Template['MilkMaid'].helpers
  milk: -> RelsheetsClient.read()
  label: -> @['name']
  isNext: -> @isNext[0]
  sameAs: (o) -> EJSON.equals(@qCellId, o[0]?.qCellId)
  stringify: (a) -> JSON.stringify(a)
  
Template['MilkMaid'].events
  "click button": ->
    RelsheetsClient.call("supply", {me: @})
    return
  "click .marking": ->
    RelsheetsClient.call("request", {level: @})
    return
