indexPathForExamplesNamePrefix = (examplesNamePrefix) ->
  # Based on the pathFor template helper, which doesn't appear to have an
  # equivalent accessible from code. :(
  Router.routes['index'].path(
    null, {query: {examplesNamePrefix: examplesNamePrefix}})

# XXX docs.meteor.com claims that Meteor.settings.public should always exist,
# but it didn't in my test.  docs.meteor.com is for the latest version of
# Meteor, so retest after we upgrade. ~ Matt 2015-12-15
indexMultiuser = Meteor.settings?.public?.indexMultiuser

Router.route(
  "/",
  (->
    examplesNamePrefix = @params.query.examplesNamePrefix
    # Only redirect if examplesNamePrefix was unset.  Don't go wild if the user just
    # clears the input field.
    if indexMultiuser && !examplesNamePrefix?
      Router.go(indexPathForExamplesNamePrefix(Random.id()))
    else
      examplesNamePrefix ?= ''
      @render "Index", {data: {examplesNamePrefix: examplesNamePrefix}}
    return
  ),
  {
    name: 'index',
    onAfterAction: -> document.title = "Object Spreadsheets"; return
  })

Template['Index'].helpers
  # Since we aren't restricting what domain names can point to our hosted demo
  # servers, it's easiest to just base this on the URL of the current page.  To
  # use Meteor.absoluteUrl, we'd have to set the ROOT_URL environment variable
  # on each server.
  #
  # XXX: Is there a library that does the following in a more robust way?
  absUrl: (path) -> location.protocol + '//' + location.host + path
  indexMultiuser: () -> indexMultiuser
  newSheetName: () -> Session.get('newSheetName')

Template['Index_ConditionalExampleLink'].helpers
  examplesNamePrefixWithDot: () ->
    examplesNamePrefix = Template.parentData().examplesNamePrefix
    if examplesNamePrefix then examplesNamePrefix + '.' else ''
  shouldEnableExampleLinks: () ->
    examplesNamePrefix = Template.parentData().examplesNamePrefix
    !indexMultiuser || examplesNamePrefix

Template['Index'].events
  'input #examplesNamePrefix': (event, template) ->
    Router.go(indexPathForExamplesNamePrefix(event.target.value)); return
  'input #newSheetName': (event, template) ->
    Session.set('newSheetName', event.target.value); return
  'click #newSheetGo': (event, template) ->
    Router.go("/" + Session.get('newSheetName')); return
  'keypress #newSheetName': (event, template) ->
    if event.which == 13
      Router.go("/" + Session.get('newSheetName'))
    return
