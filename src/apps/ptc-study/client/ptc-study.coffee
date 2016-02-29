Router.route "/:sheet/apps/ptc-study", ->
  @render "PTC_study_login", data: {sheet: @params.sheet}
  return

Template['PTC_study_login'].created = ->
  RelsheetsClient.open(@data?.sheet)  # no procedures
  return

Template['PTC_study_login'].helpers
  root: ->
    try
      RelsheetsClient.readObj(
        T(rootColumnId,
          [T(parseObjectTypeRef('FamilyPage'),
              [T(parseColumnRef('FamilyPage:studentName')[0])])]))
    catch e
      # Saw some cases of not ready.  XXX: Distinguish from real errors.
      return {}
  JSON_stringify: JSON.stringify

Router.route "/:sheet/apps/ptc-study/:familyPage", ->
  @render "PTC_study_FamilyPage", data: {
    sheet: @params.sheet,
    familyPage: JSON.parse(@params.familyPage)}
  return

Template['PTC_study_FamilyPage'].created = ->
  RelsheetsClient.open(@data?.sheet, 'ptc-study')
  return

Template['PTC_study_FamilyPage'].helpers
  FamilyPage: -> RelsheetsClient.readSubtree('FamilyPage', @familyPage)
  formatDate: (d) -> valueToTextIgnoreErrors('date', d)

blur = (jbutton) ->
  jbutton.width(jbutton.width())
  jbutton.text("∙ ∙ ∙")
  return

Template['PTC_study_FamilyPage'].events
  "click .schedule": (ev) ->
    blur($(ev.target))
    RelsheetsClient.call("parentScheduleMeeting", {block: this},
                    (error, result) -> $(ev.target).text('Schedule'); return)
    return
  "click .cancel": (ev) ->
    blur($(ev.target))
    RelsheetsClient.call("parentCancelMeeting", {block: this},
                    (error, result) -> $(ev.target).text('Cancel'); return)
    return
