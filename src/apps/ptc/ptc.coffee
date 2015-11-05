
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
    Relsheets.open(@data?.sheet, 'ptc')

  Template.PTC_Parent.helpers
    viewData: -> Relsheets.readSubtree('ParentView', [@clientUser])

  Template.PTC_Parent_login.created = ->
    Relsheets.open(@data?.sheet)
    
  Template.PTC_Parent_login.helpers
    root: -> 
      Relsheets.readObj((new View("1").def())?.layout || new Tree(rootColumnId))

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
        slot: [@slot]},
        (error, result) -> $(ev.target).text('Schedule'))
    "click .cancel": (ev) ->
      blur($(ev.target))
      Relsheets.call("parentCancelMeeting", {
        clientUser: [@clientUser],
        meeting: @meeting},
        (error, result) -> $(ev.target).text('Cancel'))

      
if Meteor.isServer

  Relsheets.procedures 'ptc',
    teacherCreateSlot:
      params: [['clientUser', 'Person'],
               ['time', '_string']]
      body: '''
  let t = clientUser.Teacher
  check t != {}
  let s = new t.Slot
  s.time := time
  check $valid
  '''
    teacherDeleteSlot:
      params: [['clientUser', 'Person'],
               ['slot', 'Person:Teacher:Slot']]
      body: '''
  check slot.Person = clientUser
  delete slot
  check $valid
  '''
    parentCreateMeeting:
      params: [['clientUser', 'Person'],
               ['enr', 'Class:Section:Enrollment'],
               ['slot', 'Person:Teacher:Slot']]
      body: '''
  check clientUser in enr.student.parent
  let m = new $Meeting
  m.enrollment := enr
  m.slot := slot
  check $valid
  '''
    parentCancelMeeting:
      params: [['clientUser', 'Person'],
               ['meeting', 'Meeting']]
      body: '''
  check clientUser in meeting.enrollment.student.parent
  delete meeting
  check $valid
  '''

    # This is just a test of a make statement, not something that actually belongs
    # in the PTC application.
    enroll:
      params: [['student', 'Person:Student'],
               ['section', 'Class:Section']]
      body: '''
  make section.Enrollment[student]
  '''

  # Future: Add special support for "check $valid"?  But we might want similar
  # functionality for other checks, if the Derailer study is any evidence.
  # Cleanup: Introduce a formula to reduce duplication in enrollment authorization
  # checks?
      