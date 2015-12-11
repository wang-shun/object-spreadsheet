Router.route "/demos", ->
  @render "Demos"

Template.Demos.helpers
  absUrl: (path) -> Meteor.absoluteUrl(path)
