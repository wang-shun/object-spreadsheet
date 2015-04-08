
if Meteor.isClient
  # That's actually a Person cell ID in JSON.  So the URL should be like:
  # /ptc/apps/ptc/parent/["5"]
  # Future: Hacks to get prettier URLs?
  Router.route "/:sheet/apps/ptc/parent/:clientUser", ->
    @render "PTC_Parent", data: {
      sheet: @params.sheet,
      # XXX: validate (not to mention authentication)
      clientUser: JSON.parse(@params.clientUser)}

  Template.PTC_Parent.created = ->
    # No proceduresAppName: procedures are currently defined by
    # load-sample-data based on the sheet name.  We can consider making this
    # consistent later.
    Relsheets.open(@data?.sheet)

  Template.PTC_Parent.helpers
    viewData: -> Relsheets.readSubtree('ParentView', [@clientUser])

  Template.PTC_Parent_enrollment.events
    # Apparently, Template.parentData does count each {{#each}} or {{#with}}
    # block, but it starts from the root of the template on which the event is
    # defined, not from the data context of the element handling the event,
    # leaving us no way to access intermediate data contexts in the template.
    # Thus, we introduce the PTC_Parent_enrollment sub-template to be able to
    # reference the enrollment.  (Alternatively, we could extract it from the
    # qCellId or modify readObj to copy ancestor keys into sub-objects.)

    # Future: We could modify the transaction procedures to take objects in
    # the view subtree, instead of the original domain objects, as parameters.
    # This would let us avoid duplicating the write access control checks in the
    # transaction procedures, though it makes it more tedious for users to call
    # transaction procedures programmatically.  For application-defined data
    # integrity constraints, it definitely seems preferable to define them
    # directly and infer the valid choices to show in the view from them (if
    # possible).  Further experience should inform the design here.
    "click .schedule": ->
      Relsheets.call("parentCreateMeeting", {
        clientUser: [Template.parentData(2).clientUser],
        enr: [Template.currentData().enrollment],
        slot: [@availableSlot]})
    "click .cancel": ->
      Relsheets.call("parentCancelMeeting", {
        clientUser: [Template.parentData(2).clientUser],
        meeting: [@meeting[0]]})
