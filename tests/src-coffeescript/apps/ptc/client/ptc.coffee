Router.route "/:sheet/apps/ptc/parent", ->
  @render "PTC_Parent_login", data: {sheet: @params.sheet}
  return
# That's actually a Person token.  So the URL should be like:
# /ptc/apps/ptc/parent/5
# which means that the Person id is ["5"].
# Future: Hacks to get prettier URLs?
Router.route "/:sheet/apps/ptc/parent/:clientUser", ->
  @render "PTC_Parent", data: {
    sheet: @params.sheet,
    # XXX: validate (not to mention authentication)
    clientUser: [@params.clientUser]}
  return
Router.route "/:sheet/apps/split-view/ptc", ->
  @render "PTC_Demo", data: {sheet: @params.sheet}
  return
ptcDemoShowingMasterData = new ReactiveVar(false)
Template['PTC_Demo'].helpers
  showingMasterData: -> ptcDemoShowingMasterData.get()
Template['PTC_Demo'].events
  'click .demo-ptc-switch-to-view-model': -> ptcDemoShowingMasterData.set(false); return
  'click .demo-ptc-switch-to-master-data': -> ptcDemoShowingMasterData.set(true); return

Template['PTC_Parent'].created = ->
  RelsheetsClient.open(@data?.sheet, 'ptc')
  return

Template['PTC_Parent'].helpers
  viewData: -> RelsheetsClient.readSubtree('ParentView', [@clientUser])

Template['PTC_Parent_login'].created = ->
  RelsheetsClient.open(@data?.sheet)
  return

Template['PTC_Parent_login'].helpers
  root: -> 
    RelsheetsClient.readObj((new View("1").def())?.layout || new Tree(rootColumnId))

blur = (jbutton) ->
  jbutton.width(jbutton.width())
  jbutton.text("∙ ∙ ∙")
  return

Template['PTC_Parent_enrollment'].events
  # Future: We could modify the transaction procedures to take objects in
  # the view subtree, instead of the original domain objects, as parameters.
  # This would let us avoid duplicating the write access control checks in the
  # transaction procedures, though it makes it more tedious for users to call
  # transaction procedures programmatically.  For application-defined data
  # integrity constraints, it definitely seems preferable to define them
  # directly and infer the valid choices to show in the view from them (if
  # possible).  Further experience should inform the design here.
  "click .schedule": (ev) ->
    blur($(ev.target))
    RelsheetsClient.call("parentCreateMeeting", {
      clientUser: [@clientUser],
      enr: [@enrollment],
      slot: [@slot]},
      (error, result) -> $(ev.target).text('Schedule'); return)
    return
  "click .cancel": (ev) ->
    blur($(ev.target))
    RelsheetsClient.call("parentCancelMeeting", {
      clientUser: [@clientUser],
      meeting: @meeting},
      (error, result) -> $(ev.target).text('Cancel'); return)
    return
