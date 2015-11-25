# The only thing different between this app subdirectory and ptc-study should be
# the procedure bodies (of course, the corresponding database dumps are also
# different), but it's easiest to fork the entire subdirectory.  Once we have
# the procedure editor and move the procedures to the database dumps, then we
# can use a single app name and subdirectory.

if Meteor.isClient
  Router.route "/:sheet/apps/ptc-study-solution", ->
    @render "PTC_study_solution_login", data: {sheet: @params.sheet}

  Template.PTC_study_solution_login.created = ->
    Relsheets.open(@data?.sheet)  # no procedures

  Template.PTC_study_solution_login.helpers
    root: ->
      try
        Relsheets.readObj(
          T(rootColumnId,
            [T(parseObjectTypeRef('FamilyPage'),
               [T(parseColumnRef('FamilyPage:studentName')[0])])]))
      catch e
        # Saw some cases of not ready.  XXX: Distinguish from real errors.
        return {}
    JSON_stringify: JSON.stringify

  Router.route "/:sheet/apps/ptc-study-solution/:familyPage", ->
    @render "PTC_study_solution_FamilyPage", data: {
      sheet: @params.sheet,
      familyPage: JSON.parse(@params.familyPage)}

  Template.PTC_study_solution_FamilyPage.created = ->
    Relsheets.open(@data?.sheet, 'ptc-study-solution')

  Template.PTC_study_solution_FamilyPage.helpers
    FamilyPage: -> Relsheets.readSubtree('FamilyPage', @familyPage)
    formatDate: (d) -> valueToTextIgnoreErrors('date', d)

  blur = (jbutton) ->
    jbutton.width(jbutton.width())
    jbutton.text("∙ ∙ ∙")

  Template.PTC_study_solution_FamilyPage.events
    "click .schedule": (ev) ->
      blur($(ev.target))
      Relsheets.call("parentScheduleMeeting", {block: this},
                     (error, result) -> $(ev.target).text('Schedule'))
    "click .cancel": (ev) ->
      blur($(ev.target))
      Relsheets.call("parentCancelMeeting", {block: this},
                     (error, result) -> $(ev.target).text('Cancel'))
