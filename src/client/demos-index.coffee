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
  ),
  {name: 'index'})

Template.Index.helpers
  absUrl: (path) -> Meteor.absoluteUrl(path)
  indexMultiuser: () -> indexMultiuser

Template.Index_ConditionalExampleLink.helpers
  examplesNamePrefixWithDot: () ->
    examplesNamePrefix = Template.parentData().examplesNamePrefix
    if examplesNamePrefix then examplesNamePrefix + '.' else ''
  shouldEnableExampleLinks: () ->
    examplesNamePrefix = Template.parentData().examplesNamePrefix
    !indexMultiuser || examplesNamePrefix

Template.Index.events
  'input #examplesNamePrefix': (event, template) ->
    Router.go(indexPathForExamplesNamePrefix(event.target.value))
