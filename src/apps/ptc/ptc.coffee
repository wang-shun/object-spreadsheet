
if Meteor.isClient
  Router.route "/:sheet/apps/ptc/parent", ->
    @render "PTC_Parent_login", data: {sheet: @params.sheet}
  # That's actually a Person token.  So the URL should be like:
  # /ptc/apps/ptc/parent/5
  # which means that the Person id is ["5"].
  # Future: Hacks to get prettier URLs?
  Router.route "/:sheet/apps/ptc/parent/:clientUser", ->
    @render "PTC_Parent", data: {
      sheet: @params.sheet,
      # XXX: validate (not to mention authentication)
      clientUser: [@params.clientUser]}

  Template.PTC_Parent.created = ->
    # No proceduresAppName: procedures are currently defined by
    # load-sample-data based on the sheet name.  We can consider making this
    # consistent later.
    Relsheets.open(@data?.sheet)

  Template.PTC_Parent.helpers
    viewData: -> Relsheets.readSubtree('ParentView', [@clientUser])

  Template.PTC_Parent_login.created = ->
    Relsheets.open(@data?.sheet)
    
  Template.PTC_Parent_login.helpers
    root: -> 
      v = Relsheets.readObj((new View("1").def())?.layout || new Tree(rootColumnId))
      console.log(v)
      v

  blur = (jbutton) ->
    jbutton.width(jbutton.width())
    jbutton.text("∙ ∙ ∙")
      
  Template.PTC_Parent_enrollment.events
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
      Relsheets.call("parentCreateMeeting", {
        clientUser: [@clientUser],
        enr: [@enrollment],
        slot: [@slot]})
    "click .cancel": (ev) ->
      blur($(ev.target))
      Relsheets.call("parentCancelMeeting", {
        clientUser: [@clientUser],
        meeting: @meeting})
